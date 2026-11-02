import Foundation

public struct DockerUsage: Decodable, Sendable, Equatable {
    public struct Image: Decodable, Sendable, Equatable {
        let id: String
        let repoTags: [String]?
        let size: Int64
        let sharedSize: Int64
        let containers: Int

        private enum CodingKeys: String, CodingKey {
            case id = "Id", repoTags = "RepoTags", size = "Size", sharedSize = "SharedSize", containers = "Containers"
        }
    }

    public struct Container: Decodable, Sendable, Equatable {
        let id: String
        let names: [String]?
        let state: String
        let sizeRw: Int64?

        private enum CodingKeys: String, CodingKey {
            case id = "Id", names = "Names", state = "State", sizeRw = "SizeRw"
        }
    }

    public struct Volume: Decodable, Sendable, Equatable {
        public struct Usage: Decodable, Sendable, Equatable {
            let size: Int64
            let refCount: Int

            private enum CodingKeys: String, CodingKey {
                case size = "Size", refCount = "RefCount"
            }
        }

        let name: String
        let usageData: Usage?

        private enum CodingKeys: String, CodingKey {
            case name = "Name", usageData = "UsageData"
        }
    }

    public struct BuildCacheEntry: Decodable, Sendable, Equatable {
        let size: Int64
        let inUse: Bool

        private enum CodingKeys: String, CodingKey {
            case size = "Size", inUse = "InUse"
        }
    }

    let images: [Image]?
    let containers: [Container]?
    let volumes: [Volume]?
    let buildCache: [BuildCacheEntry]?

    private enum CodingKeys: String, CodingKey {
        case images = "Images", containers = "Containers", volumes = "Volumes", buildCache = "BuildCache"
    }
}

/// Lets every Docker rule share one `/system/df` call.
public actor DockerUsageProvider {
    private let fetch: @Sendable () async throws -> DockerUsage
    private var pending: Task<DockerUsage, Error>?

    public init(fetch: @escaping @Sendable () async throws -> DockerUsage) {
        self.fetch = fetch
    }

    public static func live(home: URL) -> DockerUsageProvider {
        DockerUsageProvider {
            let environment = ProcessInfo.processInfo.environment
            guard let path = DockerEndpoint.resolveSocketPath(home: home, environment: environment) else {
                throw DockerError.socketNotFound
            }
            let data = try await DockerClient(socketPath: path).get("/system/df")
            return try JSONDecoder().decode(DockerUsage.self, from: data)
        }
    }

    public func usage() async throws -> DockerUsage {
        if let pending { return try await pending.value }
        let task = Task { try await fetch() }
        pending = task
        return try await task.value
    }
}
