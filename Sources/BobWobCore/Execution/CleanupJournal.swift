import Foundation

public struct CleanupJournal: Sendable {
    public let url: URL

    public init(home: URL) {
        url = home.appending(path: "Library/Logs/BobWob/cleanup.log")
    }

    struct Entry: Encodable {
        let time: Date
        let phase: String
        let ruleID: String
        let action: String
        let status: String?
        let message: String?
    }

    func append(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: encoder.encode(entry) + Data("\n".utf8))
    }
}
