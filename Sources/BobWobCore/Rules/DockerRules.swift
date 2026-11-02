import Foundation

public struct DockerRule: CleanupRule {
    public enum Kind: Sendable {
        case images, buildCache, containers, volumes
    }

    public let kind: Kind
    public let metadata: RuleMetadata

    public init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .images:
            metadata = RuleMetadata(
                id: "docker.images",
                name: "Images Docker inutilisées",
                category: .docker,
                risk: .recoverable,
                recoveryNote: "À retélécharger ou reconstruire"
            )
        case .buildCache:
            metadata = RuleMetadata(
                id: "docker.buildCache",
                name: "Cache de build Docker",
                category: .docker,
                risk: .recoverable,
                recoveryNote: "Le prochain build sera plus long"
            )
        case .containers:
            metadata = RuleMetadata(
                id: "docker.containers",
                name: "Conteneurs Docker arrêtés",
                category: .docker,
                risk: .dataLoss,
                recoveryNote: "Les fichiers écrits dans le conteneur sont perdus"
            )
        case .volumes:
            metadata = RuleMetadata(
                id: "docker.volumes",
                name: "Volumes Docker non rattachés",
                category: .docker,
                risk: .dataLoss,
                recoveryNote: "Les données du volume sont définitivement perdues"
            )
        }
    }

    public func detect(in context: ScanContext) async -> Availability {
        do {
            _ = try await context.docker.usage()
            return .available
        } catch DockerError.socketNotFound {
            return .unavailable(reason: "Docker n'est pas démarré")
        } catch {
            return .unavailable(reason: "Socket Docker injoignable (\(error))")
        }
    }

    public func scan(in context: ScanContext) -> AsyncThrowingStream<ScanEvent, Error> {
        makeScanStream { continuation in
            for item in items(from: try await context.docker.usage()) {
                continuation.yield(.item(item))
            }
        }
    }

    func items(from usage: DockerUsage) -> [ScanItem] {
        switch kind {
        case .images:
            return (usage.images ?? []).filter { $0.containers == 0 }.map { image in
                item(
                    id: image.id,
                    title: image.repoTags?.first { $0 != "<none>:<none>" } ?? "Sans tag \(image.id.dockerShortID)",
                    size: .estimated(max(0, image.size - max(0, image.sharedSize)))
                )
            }
        case .buildCache:
            let unused = (usage.buildCache ?? []).filter { !$0.inUse }
            guard !unused.isEmpty else { return [] }
            return [item(
                id: "build-cache",
                title: "Cache de build inutilisé",
                size: .estimated(unused.reduce(0) { $0 + $1.size })
            )]
        case .containers:
            return (usage.containers ?? []).filter { $0.state != "running" && $0.state != "paused" }.map { container in
                let name = container.names?.first.map { String($0.drop { $0 == "/" }) }
                return item(
                    id: container.id,
                    title: name ?? container.id.dockerShortID,
                    size: container.sizeRw.map(SizeEstimate.estimated) ?? .unknown
                )
            }
        case .volumes:
            return (usage.volumes ?? []).filter { $0.usageData?.refCount == 0 }.map { volume in
                let size = volume.usageData?.size ?? -1
                return item(id: volume.name, title: volume.name, size: size >= 0 ? .estimated(size) : .unknown)
            }
        }
    }

    private func item(id: String, title: String, size: SizeEstimate) -> ScanItem {
        ScanItem(
            id: id,
            ruleID: metadata.id,
            title: title,
            size: size,
            note: "L'espace peut n'être récupéré qu'après un délai sur le disque de la VM"
        )
    }

    public func plan(for selection: [ScanItem], in context: ScanContext) async throws -> CleanupPlan {
        let items = cleanableSelection(selection)
        return CleanupPlan(metadata: metadata, items: items, actions: items.map { .dockerAPI(request(for: $0)) })
    }

    private func request(for item: ScanItem) -> DockerRequest {
        switch kind {
        case .images: DockerRequest(method: "DELETE", path: "/images/\(item.id)")
        case .buildCache: DockerRequest(method: "POST", path: "/build/prune")
        case .containers: DockerRequest(method: "DELETE", path: "/containers/\(item.id)")
        case .volumes: DockerRequest(method: "DELETE", path: "/volumes/\(item.id)")
        }
    }
}

/// Informational only: resetting the VM stays in Docker Desktop.
public struct DockerDiskRule: CleanupRule {
    public let metadata = RuleMetadata(
        id: "docker.disk",
        name: "Disque de la VM Docker",
        category: .docker,
        risk: .dataLoss,
        recoveryNote: "À réinitialiser depuis Docker Desktop"
    )

    private func diskImage(in context: ScanContext) -> URL {
        context.home.appending(path: "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
    }

    public func claimedRoots(in context: ScanContext) -> [URL] {
        [diskImage(in: context)]
    }

    public func detect(in context: ScanContext) async -> Availability {
        FileManager.default.fileExists(atPath: diskImage(in: context).path)
            ? .available
            : .unavailable(reason: "Docker Desktop n'a pas de disque ici")
    }

    public func scan(in context: ScanContext) -> AsyncThrowingStream<ScanEvent, Error> {
        makeScanStream { continuation in
            let url = diskImage(in: context)
            let result = try DiskWalker.walk(root: url.path)
            continuation.yield(.item(ScanItem(
                id: url.path,
                ruleID: metadata.id,
                title: "Docker.raw",
                path: url.path,
                size: result.size,
                isCleanable: false,
                note: "Taille réellement occupée. BobWob ne supprime pas ce fichier."
            )))
        }
    }

    public func plan(for selection: [ScanItem], in context: ScanContext) async throws -> CleanupPlan {
        CleanupPlan(metadata: metadata, items: [], actions: [])
    }
}

extension String {
    fileprivate var dockerShortID: String {
        let digest = split(separator: ":").last.map(String.init) ?? self
        return String(digest.prefix(12))
    }
}
