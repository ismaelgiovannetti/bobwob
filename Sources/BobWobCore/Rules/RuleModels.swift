import Foundation

public enum RiskLevel: String, Codable, Sendable, CaseIterable {
    case safe
    case recoverable
    case dataLoss
}

public enum RuleCategory: String, Codable, Sendable {
    case packageManagers
    case ide
    case docker
    case emulators
    case system
    case personalFiles
}

public enum SizeEstimate: Sendable, Equatable {
    case exact(Int64)
    case estimated(Int64)
    case unknown

    public var bytes: Int64? {
        switch self {
        case .exact(let value), .estimated(let value): value
        case .unknown: nil
        }
    }

    public var precision: String {
        switch self {
        case .exact: "exact"
        case .estimated: "estimated"
        case .unknown: "unknown"
        }
    }

    public static func + (lhs: SizeEstimate, rhs: SizeEstimate) -> SizeEstimate {
        switch (lhs, rhs) {
        case (.exact(let a), .exact(let b)): .exact(a + b)
        case (.unknown, .unknown): .unknown
        default: .estimated((lhs.bytes ?? 0) + (rhs.bytes ?? 0))
        }
    }
}

extension SizeEstimate: Codable {
    private enum CodingKeys: String, CodingKey {
        case precision, bytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(precision, forKey: .precision)
        try container.encodeIfPresent(bytes, forKey: .bytes)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bytes = try container.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        switch try container.decode(String.self, forKey: .precision) {
        case "exact": self = .exact(bytes)
        case "estimated": self = .estimated(bytes)
        default: self = .unknown
        }
    }
}

public struct RuleMetadata: Codable, Sendable {
    public let id: String
    public let name: String
    public let category: RuleCategory
    public let risk: RiskLevel
    public let recoveryNote: String
    public let blockingProcesses: [String]
    /// The target folder is named after its app, whose cache must stay untouched while it runs.
    public let isNamedAfterOwner: Bool

    public init(
        id: String,
        name: String,
        category: RuleCategory,
        risk: RiskLevel,
        recoveryNote: String,
        blockingProcesses: [String] = [],
        isNamedAfterOwner: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.risk = risk
        self.recoveryNote = recoveryNote
        self.blockingProcesses = blockingProcesses
        self.isNamedAfterOwner = isNamedAfterOwner
    }
}

public enum Availability: Sendable, Equatable {
    case available
    case unavailable(reason: String)
}

public struct ScanItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let ruleID: String
    public let title: String
    public let path: String?
    public let size: SizeEstimate
    public let fileCount: Int?
    public let inaccessibleCount: Int
    public let lastActivity: Date?
    public let lastActivityIsApproximate: Bool
    public let isCleanable: Bool
    public let isPreselected: Bool
    public let note: String?
    public let fingerprint: FileFingerprint?

    public init(
        id: String,
        ruleID: String,
        title: String,
        path: String? = nil,
        size: SizeEstimate,
        fileCount: Int? = nil,
        inaccessibleCount: Int = 0,
        lastActivity: Date? = nil,
        lastActivityIsApproximate: Bool = false,
        isCleanable: Bool = true,
        isPreselected: Bool = false,
        note: String? = nil,
        fingerprint: FileFingerprint? = nil
    ) {
        self.id = id
        self.ruleID = ruleID
        self.title = title
        self.path = path
        self.size = size
        self.fileCount = fileCount
        self.inaccessibleCount = inaccessibleCount
        self.lastActivity = lastActivity
        self.lastActivityIsApproximate = lastActivityIsApproximate
        self.isCleanable = isCleanable
        self.isPreselected = isPreselected
        self.note = note
        self.fingerprint = fingerprint
    }
}

public enum ScanEvent: Sendable {
    case progress(bytes: Int64)
    case item(ScanItem)
    case warning(String)
}

public struct ScanOptions: Sendable {
    public var largeFileMinimumBytes: Int64 = 500_000_000
    public var largeFileMinimumAgeDays = 180
    public var downloadsMinimumAgeDays = 90

    public init() {}
}

public struct ScanContext: Sendable {
    public let home: URL
    public let now: Date
    public let options: ScanOptions
    public let docker: DockerUsageProvider
    public internal(set) var ledger: PathLedger

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: Date = Date(),
        options: ScanOptions = ScanOptions(),
        docker: DockerUsageProvider? = nil
    ) {
        self.home = home
        self.now = now
        self.options = options
        self.docker = docker ?? DockerUsageProvider.live(home: home)
        self.ledger = PathLedger()
    }
}

public protocol CleanupRule: Sendable {
    var metadata: RuleMetadata { get }
    func claimedRoots(in context: ScanContext) -> [URL]
    func allowedRoots(in context: ScanContext) -> [URL]
    func detect(in context: ScanContext) async -> Availability
    func scan(in context: ScanContext) -> AsyncThrowingStream<ScanEvent, Error>
    func plan(for selection: [ScanItem], in context: ScanContext) async throws -> CleanupPlan
}

extension CleanupRule {
    public func claimedRoots(in context: ScanContext) -> [URL] { [] }
    public func allowedRoots(in context: ScanContext) -> [URL] { claimedRoots(in: context) }

    func makeScanStream(
        _ body: @escaping @Sendable (AsyncThrowingStream<ScanEvent, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cleanableSelection(_ selection: [ScanItem]) -> [ScanItem] {
        selection.filter { $0.ruleID == metadata.id && $0.isCleanable }
    }
}
