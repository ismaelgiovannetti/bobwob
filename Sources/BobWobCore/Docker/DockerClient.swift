import Foundation

public enum DockerError: Error, Equatable {
    case socketNotFound
    case unreachable
    case timedOut
    case invalidResponse
    case httpStatus(Int)
}

struct HTTPResponse: Equatable {
    let status: Int
    let body: Data

    static func parse(_ raw: Data) throws -> HTTPResponse {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = raw.range(of: separator) else { throw DockerError.invalidResponse }
        let lines = String(decoding: raw[raw.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { throw DockerError.invalidResponse }

        let isChunked = lines.dropFirst().contains {
            let header = $0.lowercased()
            return header.hasPrefix("transfer-encoding:") && header.contains("chunked")
        }
        let body = Data(raw[headerEnd.upperBound...])
        return HTTPResponse(status: status, body: isChunked ? try decodeChunks(body) : body)
    }

    private static func decodeChunks(_ data: Data) throws -> Data {
        let lineEnd = Data("\r\n".utf8)
        var decoded = Data()
        var cursor = data.startIndex
        while let sizeEnd = data.range(of: lineEnd, in: cursor..<data.endIndex) {
            let sizeLine = String(decoding: data[cursor..<sizeEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeLine.split(separator: ";").first ?? "", radix: 16) else {
                throw DockerError.invalidResponse
            }
            if size == 0 { return decoded }
            let chunkEnd = sizeEnd.upperBound + size
            guard chunkEnd <= data.endIndex else { throw DockerError.invalidResponse }
            decoded.append(data[sizeEnd.upperBound..<chunkEnd])
            cursor = min(chunkEnd + lineEnd.count, data.endIndex)
        }
        throw DockerError.invalidResponse
    }
}

public struct DockerClient: Sendable {
    let socketPath: String
    var timeout: Int = 15

    public func get(_ path: String) async throws -> Data {
        try await send(method: "GET", path: path)
    }

    @discardableResult
    public func send(method: String, path: String) async throws -> Data {
        guard FileManager.default.fileExists(atPath: socketPath) else { throw DockerError.socketNotFound }
        try Task.checkCancellation()
        let bodyHeader = method == "GET" ? "" : "Content-Length: 0\r\n"
        let request = Data("\(method) \(path) HTTP/1.1\r\nHost: docker\r\n\(bodyHeader)Connection: close\r\n\r\n".utf8)
        let raw = try await exchange(request)
        let response = try HTTPResponse.parse(raw)
        guard (200..<300).contains(response.status) else { throw DockerError.httpStatus(response.status) }
        return response.body
    }

    private func exchange(_ request: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try blockingExchange(request) })
            }
        }
    }

    private func blockingExchange(_ request: Data) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DockerError.unreachable }
        defer { close(descriptor) }

        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        try connect(descriptor)

        try request.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if errno != EINTR {
                    throw errno == EAGAIN ? DockerError.timedOut : DockerError.unreachable
                }
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count > 0 {
                response.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                return response
            } else if errno != EINTR {
                throw errno == EAGAIN ? DockerError.timedOut : DockerError.unreachable
            }
        }
    }

    private func connect(_ descriptor: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { throw DockerError.unreachable }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw DockerError.unreachable }
    }
}
