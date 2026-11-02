import Foundation

public struct FileFingerprint: Codable, Sendable, Equatable {
    let inode: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    public static func read(atPath path: String) -> FileFingerprint? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileFingerprint(
            inode: info.st_ino,
            modifiedSeconds: info.st_mtimespec.tv_sec,
            modifiedNanoseconds: info.st_mtimespec.tv_nsec
        )
    }
}

public enum PathDecision: Equatable {
    case allowed(URL)
    case missing
    case refused(String)
}

/// The last check before anything touches the disk. It applies whatever a rule asks for.
public struct PathGuard: Sendable {
    private static let protectedPaths = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Library/Application Support",
        "Library/Caches", "Library/Containers", "Library/Group Containers", "Library/Logs",
        "Library/Mobile Documents", "Movies", "Music", "Pictures", "Public",
    ]

    private static let forbiddenSubtrees = [
        ".gnupg", ".ssh", "Library/CloudStorage", "Library/Keychains", "Library/Logs/BobWob", "Library/Mobile Documents",
    ]

    private let home: String

    public init?(home: URL) {
        guard let resolved = Self.resolved(home.path) else { return nil }
        self.home = resolved
    }

    public func evaluate(_ url: URL, allowedRoots: [URL]) -> PathDecision {
        guard url.path.hasPrefix("/"), let path = Self.canonicalPath(of: url) else {
            return .refused("Chemin impossible à résoudre")
        }
        guard path.hasPrefix(home + "/") else {
            return .refused("Chemin hors du dossier utilisateur")
        }
        for protected in Self.protectedPaths.map({ home + "/" + $0 }) where protected == path || protected.hasPrefix(path + "/") {
            return .refused("Dossier protégé")
        }
        for forbidden in Self.forbiddenSubtrees.map({ home + "/" + $0 }) where path == forbidden || path.hasPrefix(forbidden + "/") {
            return .refused("Dossier protégé")
        }
        let isDeclared = allowedRoots.compactMap(Self.canonicalPath).contains { root in
            path == root || path.hasPrefix(root + "/")
        }
        guard isDeclared else {
            return .refused("Chemin hors des racines déclarées par la règle")
        }

        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno == ENOENT ? .missing : .refused("Chemin inaccessible")
        }
        if info.st_mode & S_IFMT == S_IFLNK {
            return .refused("Lien symbolique refusé")
        }
        return .allowed(URL(fileURLWithPath: path))
    }

    /// Resolves the parent only, so that a final symbolic link stays visible and gets refused.
    private static func canonicalPath(of url: URL) -> String? {
        let parent = url.deletingLastPathComponent().path
        guard let resolvedParent = resolved(parent) else { return nil }
        return resolvedParent == "/" ? "/" + url.lastPathComponent : resolvedParent + "/" + url.lastPathComponent
    }

    private static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
