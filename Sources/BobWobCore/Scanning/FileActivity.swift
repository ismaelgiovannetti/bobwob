import CoreServices
import Foundation

public struct FileActivity: Sendable, Equatable {
    public let date: Date?
    public let isApproximate: Bool

    /// `kMDItemLastUsedDate` is often missing, so the latest known date wins and the result
    /// is flagged as approximate when no real usage date backs it.
    public static func resolve(lastUsed: Date?, added: Date?, modified: Date?) -> FileActivity {
        FileActivity(
            date: [lastUsed, added, modified].compactMap { $0 }.max(),
            isApproximate: lastUsed == nil
        )
    }

    public static func read(at url: URL) -> FileActivity {
        let values = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .contentModificationDateKey])
        var lastUsed: Date?
        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            lastUsed = MDItemCopyAttribute(item, "kMDItemLastUsedDate" as CFString) as? Date
        }
        return resolve(
            lastUsed: lastUsed,
            added: values?.addedToDirectoryDate,
            modified: values?.contentModificationDate
        )
    }

    public func isOlder(thanDays days: Int, relativeTo now: Date) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) >= Double(days) * 86_400
    }
}
