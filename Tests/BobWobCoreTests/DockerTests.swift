import CryptoKit
import Foundation
import Testing

@testable import BobWobCore

@Suite struct DockerTests {
    private let fixture = Data("""
        {
          "Images": [
            {"Id": "sha256:aaaaaaaaaaaaaaaa", "RepoTags": ["used:1"], "Size": 500, "SharedSize": 100, "Containers": 1},
            {"Id": "sha256:bbbbbbbbbbbbbbbb", "RepoTags": ["unused:1"], "Size": 500, "SharedSize": 100, "Containers": 0},
            {"Id": "sha256:cccccccccccccccc", "RepoTags": null, "Size": 50, "SharedSize": -1, "Containers": 0}
          ],
          "Containers": [
            {"Id": "run", "Names": ["/web"], "State": "running", "SizeRw": 10},
            {"Id": "stop", "Names": ["/old"], "State": "exited", "SizeRw": 20},
            {"Id": "nosize", "Names": ["/empty"], "State": "created"}
          ],
          "Volumes": [
            {"Name": "attached", "UsageData": {"Size": 900, "RefCount": 1}},
            {"Name": "orphan", "UsageData": {"Size": 300, "RefCount": 0}},
            {"Name": "unmeasured", "UsageData": {"Size": -1, "RefCount": 0}}
          ],
          "BuildCache": [
            {"Size": 70, "InUse": false},
            {"Size": 30, "InUse": true}
          ]
        }
        """.utf8)

    private func usage() throws -> DockerUsage {
        try JSONDecoder().decode(DockerUsage.self, from: fixture)
    }

    @Test func imagesInUseAreNeverOffered() throws {
        let items = DockerRule(kind: .images).items(from: try usage())
        #expect(items.map(\.title) == ["unused:1", "Sans tag cccccccccccc"])
        #expect(items[0].size == .estimated(400))
        #expect(items[1].size == .estimated(50))
    }

    @Test func runningContainersAreNeverOffered() throws {
        let items = DockerRule(kind: .containers).items(from: try usage())
        #expect(items.map(\.title) == ["old", "empty"])
        #expect(items[1].size == .unknown)
    }

    @Test func onlyDetachedVolumesAreOfferedAndNeverPreselected() throws {
        let items = DockerRule(kind: .volumes).items(from: try usage())
        #expect(items.map(\.id) == ["orphan", "unmeasured"])
        #expect(items[1].size == .unknown)
        #expect(items.allSatisfy { !$0.isPreselected })
    }

    @Test func buildCacheCountsOnlyUnusedEntries() throws {
        let items = DockerRule(kind: .buildCache).items(from: try usage())
        #expect(items.count == 1)
        #expect(items[0].size == .estimated(70))
    }

    @Test func volumePlanTargetsOnlySelectedVolume() async throws {
        let home = try TemporaryDirectory()
        let rule = DockerRule(kind: .volumes)
        let items = rule.items(from: try usage())
        let plan = try await rule.plan(for: [items[0]], in: makeContext(home: home.url))
        #expect(plan.actions == [.dockerAPI(DockerRequest(method: "DELETE", path: "/volumes/orphan"))])
    }

    @Test func stoppedDockerMakesRulesUnavailableNotEmpty() async throws {
        let home = try TemporaryDirectory()
        let report = await ScanCoordinator(
            rules: [DockerRule(kind: .images)],
            context: makeContext(home: home.url)
        ).report()
        #expect(report.rules[0].status == .unavailable)
    }

    @Test func diskRuleIsNeverCleanable() async throws {
        let home = try TemporaryDirectory()
        try home.write("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 100_000)
        let report = await ScanCoordinator(rules: [DockerDiskRule()], context: makeContext(home: home.url)).report()

        #expect(report.rules[0].items.count == 1)
        #expect(!report.rules[0].items[0].isCleanable)
        #expect(report.rules[0].cleanableSize == .exact(0))
    }

    @Test func providerFetchesOnlyOnce() async throws {
        let counter = Counter()
        let value = try usage()
        let provider = DockerUsageProvider {
            await counter.increment()
            return value
        }
        _ = try await provider.usage()
        _ = try await provider.usage()
        #expect(await counter.value == 1)
    }

    @Test func resolvesSocketFromCurrentContext() throws {
        let home = try TemporaryDirectory()
        try home.write(".docker/config.json", bytes: 0)
        try Data(#"{"currentContext":"desktop-linux"}"#.utf8).write(to: home.url.appending(path: ".docker/config.json"))
        let digest = SHA256.hash(data: Data("desktop-linux".utf8)).map { String(format: "%02x", $0) }.joined()
        let meta = try home.write(".docker/contexts/meta/\(digest)/meta.json", bytes: 0)
        try Data(#"{"Endpoints":{"docker":{"Host":"unix:///custom/docker.sock"}}}"#.utf8).write(to: meta)

        #expect(DockerEndpoint.resolveSocketPath(home: home.url, environment: [:]) == "/custom/docker.sock")
    }

    @Test func environmentOverridesContextAndTCPIsUnsupported() throws {
        let home = try TemporaryDirectory()
        #expect(DockerEndpoint.resolveSocketPath(home: home.url, environment: ["DOCKER_HOST": "unix:///a.sock"]) == "/a.sock")
        #expect(DockerEndpoint.resolveSocketPath(home: home.url, environment: ["DOCKER_HOST": "tcp://1.2.3.4:2375"]) == nil)
        #expect(DockerEndpoint.resolveSocketPath(home: home.url, environment: [:]) == "/var/run/docker.sock")
    }

    @Test func parsesPlainAndChunkedResponses() throws {
        let plain = try HTTPResponse.parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8))
        #expect(plain == HTTPResponse(status: 200, body: Data("ok".utf8)))

        let chunked = try HTTPResponse.parse(Data(
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8
        ))
        #expect(chunked.body == Data("hello world".utf8))

        #expect(throws: DockerError.invalidResponse) { try HTTPResponse.parse(Data("garbage".utf8)) }
    }

    @Test func clientReadsLargeChunkedResponsesReliably() async throws {
        let payload = String(repeating: "x", count: 200_000)
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(payload.utf8.count, radix: 16) + "\r\n" + payload + "\r\n0\r\n\r\n"
        let server = try FakeDockerServer(response: Data(response.utf8))
        defer { server.stop() }
        let client = DockerClient(socketPath: server.path)

        for _ in 0..<100 {
            let body = try await client.get("/system/df")
            #expect(body.count == 200_000)
        }
    }

    @Test func httpErrorsAreReported() async throws {
        let server = try FakeDockerServer(response: Data("HTTP/1.1 500 Oops\r\nContent-Length: 0\r\n\r\n".utf8))
        defer { server.stop() }
        let client = DockerClient(socketPath: server.path)
        await #expect(throws: DockerError.httpStatus(500)) { _ = try await client.get("/system/df") }
    }

    @Test func silentServerTimesOut() async throws {
        let server = try FakeDockerServer(response: nil)
        defer { server.stop() }
        let client = DockerClient(socketPath: server.path, timeout: 1)
        await #expect(throws: DockerError.timedOut) { _ = try await client.get("/system/df") }
    }

    @Test func missingSocketFailsCleanly() async {
        let client = DockerClient(socketPath: "/nonexistent/docker.sock")
        await #expect(throws: DockerError.socketNotFound) { _ = try await client.get("/system/df") }
    }
}

private actor Counter {
    var value = 0

    func increment() {
        value += 1
    }
}

private final class FakeDockerServer: @unchecked Sendable {
    let path = "/tmp/bobwob-\(UUID().uuidString.prefix(8)).sock"
    private let listener: Int32

    init(response: Data?) throws {
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 16) == 0 else { throw DockerError.unreachable }

        let descriptor = listener
        DispatchQueue.global().async {
            while true {
                let client = accept(descriptor, nil, nil)
                guard client >= 0 else { return }
                DispatchQueue.global().async {
                    var request = [UInt8](repeating: 0, count: 4096)
                    _ = read(client, &request, request.count)
                    guard let response else {
                        sleep(3)
                        close(client)
                        return
                    }
                    response.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            let written = write(client, buffer.baseAddress! + offset, buffer.count - offset)
                            if written <= 0 { break }
                            offset += written
                        }
                    }
                    close(client)
                }
            }
        }
    }

    func stop() {
        close(listener)
        unlink(path)
    }
}
