import Foundation

enum PersonalFiles {
    static let bundleExtensions: Set<String> = [
        "app", "bundle", "framework", "photoslibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "fcpbundle", "xcodeproj", "xcworkspace", "logicx",
    ]

    private static let skippedDirectoryNames: Set<String> = [
        "node_modules", "venv", "site-packages", "Pods", "DerivedData",
    ]

    private static let skippedHomeDirectories: Set<String> = [
        "Library", "Downloads", "Applications", "miniconda3", "anaconda3",
    ]

    private static let syncedDirectoryPrefixes = ["OneDrive", "Google Drive", "GoogleDrive", "Dropbox", "iCloud", "Box"]

    static func isRepository(_ path: String) -> Bool {
        access(path + "/.git", F_OK) == 0
    }

    /// Hidden folders hold tool data, and deleting from a synced folder can propagate to the cloud.
    static func shouldDescend(into path: String, home: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if name.hasPrefix(".") || skippedDirectoryNames.contains(name) { return false }
        if bundleExtensions.contains(url.pathExtension.lowercased()) { return false }
        if syncedDirectoryPrefixes.contains(where: name.hasPrefix) { return false }
        if url.deletingLastPathComponent().path == home, skippedHomeDirectories.contains(name) { return false }
        return !isRepository(path)
    }

    static func isSyncedToCloud(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    static func makeItem(
        ruleID: String,
        url: URL,
        size: SizeEstimate,
        fileCount: Int?,
        inaccessibleCount: Int,
        activity: FileActivity
    ) -> ScanItem {
        ScanItem(
            id: "\(ruleID):\(url.path)",
            ruleID: ruleID,
            title: url.lastPathComponent,
            path: url.path,
            size: size,
            fileCount: fileCount,
            inaccessibleCount: inaccessibleCount,
            lastActivity: activity.date,
            lastActivityIsApproximate: activity.isApproximate,
            note: "L'espace n'est libéré qu'une fois la corbeille vidée",
            fingerprint: FileFingerprint.read(atPath: url.path)
        )
    }

    static func trashPlan(metadata: RuleMetadata, allowedRoots: [URL], items: [ScanItem]) -> CleanupPlan {
        let entries = items.map { item in
            (item: item, actions: item.path.map { [CleanupAction.moveToTrash(URL(fileURLWithPath: $0))] } ?? [])
        }
        return CleanupPlan(metadata: metadata, allowedRoots: allowedRoots, entries: entries)
    }
}

public struct DownloadsRule: CleanupRule {
    public let metadata = RuleMetadata(
        id: "personal.downloads",
        name: "Téléchargements anciens",
        category: .personalFiles,
        risk: .dataLoss,
        recoveryNote: "Déplacés vers la corbeille, récupérables tant qu'elle n'est pas vidée"
    )

    public init() {}

    private func folder(in context: ScanContext) -> URL {
        context.home.appending(path: "Downloads")
    }

    public func claimedRoots(in context: ScanContext) -> [URL] {
        [folder(in: context)]
    }

    public func detect(in context: ScanContext) async -> Availability {
        FileManager.default.isReadableFile(atPath: folder(in: context).path)
            ? .available
            : .unavailable(reason: "Dossier Téléchargements introuvable ou non accessible")
    }

    public func scan(in context: ScanContext) -> AsyncThrowingStream<ScanEvent, Error> {
        makeScanStream { continuation in
            let entries = try FileManager.default.contentsOfDirectory(
                at: folder(in: context),
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for url in entries {
                try Task.checkCancellation()
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { continue }
                if PersonalFiles.isRepository(url.path) || PersonalFiles.isSyncedToCloud(url) { continue }
                let activity = FileActivity.read(at: url)
                guard activity.isOlder(thanDays: context.options.downloadsMinimumAgeDays, relativeTo: context.now) else {
                    continue
                }
                let result = try DiskWalker.walk(root: url.path)
                if result.allocatedBytes == 0 { continue }
                continuation.yield(.item(PersonalFiles.makeItem(
                    ruleID: metadata.id,
                    url: url,
                    size: result.size,
                    fileCount: result.fileCount,
                    inaccessibleCount: result.inaccessibleCount,
                    activity: activity
                )))
            }
        }
    }

    public func plan(for selection: [ScanItem], in context: ScanContext) async throws -> CleanupPlan {
        PersonalFiles.trashPlan(metadata: metadata, allowedRoots: allowedRoots(in: context), items: cleanableSelection(selection))
    }
}

public struct LargeFilesRule: CleanupRule {
    public let metadata = RuleMetadata(
        id: "personal.largeFiles",
        name: "Gros fichiers peu utilisés",
        category: .personalFiles,
        risk: .dataLoss,
        recoveryNote: "Déplacés vers la corbeille, récupérables tant qu'elle n'est pas vidée"
    )

    public init() {}

    public func allowedRoots(in context: ScanContext) -> [URL] {
        [context.home]
    }

    public func detect(in context: ScanContext) async -> Availability {
        .available
    }

    public func scan(in context: ScanContext) -> AsyncThrowingStream<ScanEvent, Error> {
        makeScanStream { continuation in
            let home = context.home.standardizedFileURL.path
            var candidates: [(path: String, bytes: Int64)] = []
            let walk = try DiskWalker.walk(
                root: home,
                excluding: context.ledger.allPaths,
                shouldDescend: { PersonalFiles.shouldDescend(into: $0, home: home) },
                largeFileThreshold: context.options.largeFileMinimumBytes,
                onLargeFile: { candidates.append(($0, $1)) },
                onProgress: { continuation.yield(.progress(bytes: $0)) }
            )
            if walk.inaccessibleCount > 0 {
                continuation.yield(.warning("\(walk.inaccessibleCount) éléments n'ont pas pu être lus"))
            }
            for candidate in candidates {
                let url = URL(fileURLWithPath: candidate.path)
                if url.lastPathComponent.hasPrefix(".") || PersonalFiles.isSyncedToCloud(url) { continue }
                let activity = FileActivity.read(at: url)
                guard activity.isOlder(thanDays: context.options.largeFileMinimumAgeDays, relativeTo: context.now) else {
                    continue
                }
                continuation.yield(.item(PersonalFiles.makeItem(
                    ruleID: metadata.id,
                    url: url,
                    size: .exact(candidate.bytes),
                    fileCount: 1,
                    inaccessibleCount: 0,
                    activity: activity
                )))
            }
        }
    }

    public func plan(for selection: [ScanItem], in context: ScanContext) async throws -> CleanupPlan {
        PersonalFiles.trashPlan(metadata: metadata, allowedRoots: allowedRoots(in: context), items: cleanableSelection(selection))
    }
}
