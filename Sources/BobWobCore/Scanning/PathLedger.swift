import Foundation

/// Assigns each path to the first rule that claims it, so that a generic rule never counts
/// what a more specific rule already measures.
public struct PathLedger: Sendable {
    private var claims: [(path: String, ruleID: String)] = []

    public init() {}

    public mutating func claim(_ url: URL, by ruleID: String) {
        claims.append((url.standardizedFileURL.path, ruleID))
    }

    public func owner(of url: URL) -> String? {
        let path = url.standardizedFileURL.path
        return claims.first { $0.path == path }?.ruleID
    }

    public func isOwned(_ url: URL, by ruleID: String) -> Bool {
        let owner = owner(of: url)
        return owner == nil || owner == ruleID
    }

    public func excludedPaths(under root: URL, for ruleID: String) -> Set<String> {
        let prefix = root.standardizedFileURL.path + "/"
        return Set(claims.lazy.filter { $0.ruleID != ruleID && $0.path.hasPrefix(prefix) }.map(\.path))
    }

    public var allPaths: Set<String> {
        Set(claims.map(\.path))
    }
}
