import Foundation

@testable import BobWobCore

final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "bobwob-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.appending(path: "locked").path)
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func write(_ relativePath: String, bytes: Int = 8192) throws -> URL {
        let file = url.appending(path: relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: file)
        return file
    }
}

func offlineDocker() -> DockerUsageProvider {
    DockerUsageProvider { throw DockerError.socketNotFound }
}

func makeContext(home: URL, now: Date = Date(), options: ScanOptions = ScanOptions()) -> ScanContext {
    ScanContext(home: home, now: now, options: options, docker: offlineDocker())
}
