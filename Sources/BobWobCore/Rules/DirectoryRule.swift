import Foundation

/// Measures fixed locations, with one item per root.
public struct DirectoryRule: CleanupRule {
    public let metadata: RuleMetadata
    private let resolveRoots: @Sendable (URL) -> [URL]
    private let purge: @Sendable (URL, ScanContext) -> [CleanupAction]
    private let additionalAllowedRoots: @Sendable (URL) -> [URL]

    public init(
        metadata: RuleMetadata,
        resolveRoots: @escaping @Sendable (URL) -> [URL],
        purge: @escaping @Sendable (URL, ScanContext) -> [CleanupAction] = { root, _ in [.removeTree(root)] },
        additionalAllowedRoots: @escaping @Sendable (URL) -> [URL] = { _ in [] }
    ) {
        self.metadata = metadata
        self.resolveRoots = resolveRoots
        self.purge = purge
        self.additionalAllowedRoots = additionalAllowedRoots
    }

    public func claimedRoots(in context: ScanContext) -> [URL] {
        resolveRoots(context.home)
    }

    public func allowedRoots(in context: ScanContext) -> [URL] {
        resolveRoots(context.home) + additionalAllowedRoots(context.home)
    }

    public func detect(in context: ScanContext) async -> Availability {
        let found = resolveRoots(context.home).contains { FileManager.default.fileExists(atPath: $0.path) }
        return found ? .available : .unavailable(reason: "Aucune donnée trouvée")
    }

    public func scan(in context: ScanContext) -> AsyncThrowingStream<ScanEvent, Error> {
        makeScanStream { continuation in
            for root in resolveRoots(context.home) where context.ledger.isOwned(root, by: metadata.id) {
                try Task.checkCancellation()
                guard FileManager.default.fileExists(atPath: root.path) else { continue }
                let result = try DiskWalker.walk(
                    root: root.path,
                    excluding: context.ledger.excludedPaths(under: root, for: metadata.id),
                    onProgress: { continuation.yield(.progress(bytes: $0)) }
                )
                if result.allocatedBytes == 0, result.inaccessibleCount == 0 { continue }
                continuation.yield(.item(ScanItem(
                    id: "\(metadata.id):\(root.path)",
                    ruleID: metadata.id,
                    title: root.lastPathComponent,
                    path: root.path,
                    size: result.size,
                    fileCount: result.fileCount,
                    inaccessibleCount: result.inaccessibleCount,
                    isPreselected: metadata.risk == .safe,
                    note: result.inaccessibleCount > 0 ? "Certains fichiers ne sont pas accessibles" : nil,
                    fingerprint: FileFingerprint.read(atPath: root.path)
                )))
            }
        }
    }

    public func plan(for selection: [ScanItem], in context: ScanContext) async throws -> CleanupPlan {
        let entries = cleanableSelection(selection).map { item in
            (item: item, actions: item.path.map { purge(URL(fileURLWithPath: $0), context) } ?? [])
        }
        return CleanupPlan(metadata: metadata, allowedRoots: allowedRoots(in: context), entries: entries)
    }
}

public enum ToolLocator {
    /// An app launched from the Finder does not inherit the shell's PATH.
    public static func find(_ name: String, home: URL) -> URL? {
        let directories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/local/share/dotnet",
            home.appending(path: ".dotnet").path,
            home.appending(path: "miniconda3/bin").path,
            home.appending(path: "anaconda3/bin").path,
            "/usr/bin",
        ]
        return directories
            .map { URL(fileURLWithPath: $0).appending(path: name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

enum Roots {
    static func fixed(_ relativePaths: String...) -> @Sendable (URL) -> [URL] {
        let paths = relativePaths
        return { home in paths.map { home.appending(path: $0) } }
    }

    static func children(
        of relativePath: String,
        where isIncluded: @escaping @Sendable (String) -> Bool
    ) -> @Sendable (URL) -> [URL] {
        { home in
            let parent = home.appending(path: relativePath)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
            return names.sorted().filter(isIncluded).map { parent.appending(path: $0) }
        }
    }
}
