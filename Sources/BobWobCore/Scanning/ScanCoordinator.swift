import Foundation

public enum ScanUpdate: Sendable {
    case ruleStarted(id: String)
    case ruleEvent(id: String, event: ScanEvent)
    case ruleAbsent(id: String)
    case ruleUnavailable(id: String, reason: String)
    case ruleFailed(id: String, message: String)
    case ruleFinished(id: String)
}

public struct ScanCoordinator: Sendable {
    private let rules: [any CleanupRule]
    private let context: ScanContext
    private let maximumConcurrentRules: Int

    /// `ledgerRules` lets a partial scan keep the same path ownership as a full one.
    public init(
        rules: [any CleanupRule],
        context: ScanContext,
        ledgerRules: [any CleanupRule]? = nil,
        maximumConcurrentRules: Int = 4
    ) {
        var context = context
        for rule in ledgerRules ?? rules {
            for root in rule.claimedRoots(in: context) where context.ledger.owner(of: root) == nil {
                context.ledger.claim(root, by: rule.metadata.id)
            }
        }
        self.rules = rules
        self.context = context
        self.maximumConcurrentRules = maximumConcurrentRules
    }

    public func updates() -> AsyncStream<ScanUpdate> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Void.self) { group in
                    var pending = rules.makeIterator()
                    for _ in 0..<maximumConcurrentRules {
                        guard let rule = pending.next() else { break }
                        group.addTask { await run(rule, into: continuation) }
                    }
                    while await group.next() != nil {
                        guard !Task.isCancelled, let rule = pending.next() else { continue }
                        group.addTask { await run(rule, into: continuation) }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func report(volumeURL: URL? = nil) async -> ScanReport {
        let started = Date()
        var builder = ScanReport.Builder(rules: rules.map(\.metadata))
        for await update in updates() {
            builder.apply(update)
        }
        return builder.build(
            volume: VolumeUsage.read(at: volumeURL ?? context.home),
            duration: Date().timeIntervalSince(started)
        )
    }

    private func run(_ rule: any CleanupRule, into continuation: AsyncStream<ScanUpdate>.Continuation) async {
        let id = rule.metadata.id
        continuation.yield(.ruleStarted(id: id))
        switch await rule.detect(in: context) {
        case .available:
            break
        case .notPresent:
            continuation.yield(.ruleAbsent(id: id))
            return
        case .unavailable(let reason):
            continuation.yield(.ruleUnavailable(id: id, reason: reason))
            return
        }
        do {
            for try await event in rule.scan(in: context) {
                continuation.yield(.ruleEvent(id: id, event: event))
            }
            continuation.yield(.ruleFinished(id: id))
        } catch is CancellationError {
            continuation.yield(.ruleFailed(id: id, message: "Scan annulé"))
        } catch {
            continuation.yield(.ruleFailed(id: id, message: error.localizedDescription))
        }
    }
}

public struct VolumeUsage: Codable, Sendable {
    public let totalBytes: Int64?
    public let availableBytes: Int64?

    static func read(at url: URL) -> VolumeUsage {
        // A URL instance caches its resource values, which would freeze the free space.
        let fresh = URL(fileURLWithPath: url.path)
        let values = try? fresh.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        return VolumeUsage(
            totalBytes: values?.volumeTotalCapacity.map(Int64.init),
            availableBytes: values?.volumeAvailableCapacity.map(Int64.init)
        )
    }
}

extension VolumeUsage {
    /// Used space that no rule measured. Unknown after a failed rule, which would inflate it.
    public func unanalyzedBytes(rules: [RuleReport]) -> Int64? {
        guard let totalBytes, let availableBytes,
            !rules.contains(where: { $0.status == .failed })
        else { return nil }
        let measured = rules.flatMap(\.items).reduce(Int64(0)) { $0 + ($1.size.bytes ?? 0) }
        return max(0, totalBytes - availableBytes - measured)
    }
}

public struct RuleReport: Encodable, Sendable {
    public enum Status: String, Encodable, Sendable {
        case completed, absent, unavailable, failed
    }

    public let metadata: RuleMetadata
    public var status: Status
    public var statusMessage: String?
    public var items: [ScanItem]
    public var warnings: [String]

    public var cleanableSize: SizeEstimate {
        SizeEstimate.total(of: items.filter(\.isCleanable).map(\.size))
    }

    private enum CodingKeys: String, CodingKey {
        case metadata, status, statusMessage, items, warnings, cleanableSize
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(statusMessage, forKey: .statusMessage)
        try container.encode(items, forKey: .items)
        try container.encode(warnings, forKey: .warnings)
        try container.encode(cleanableSize, forKey: .cleanableSize)
    }
}

public struct ScanReport: Encodable, Sendable {
    public let volume: VolumeUsage
    public let durationSeconds: Double
    public let rules: [RuleReport]

    public func cleanableSize(for risk: RiskLevel) -> SizeEstimate {
        SizeEstimate.total(of: rules.filter { $0.metadata.risk == risk }.map(\.cleanableSize))
    }

    public struct Builder {
        private let order: [String]
        private var reports: [String: RuleReport]

        public init(rules: [RuleMetadata]) {
            order = rules.map(\.id)
            reports = Dictionary(uniqueKeysWithValues: rules.map {
                ($0.id, RuleReport(metadata: $0, status: .completed, statusMessage: nil, items: [], warnings: []))
            })
        }

        public mutating func apply(_ update: ScanUpdate) {
            switch update {
            case .ruleStarted, .ruleFinished, .ruleEvent(_, .progress):
                break
            case .ruleEvent(let id, .item(let item)):
                reports[id]?.items.append(item)
            case .ruleEvent(let id, .warning(let message)):
                reports[id]?.warnings.append(message)
            case .ruleAbsent(let id):
                reports[id]?.status = .absent
            case .ruleUnavailable(let id, let reason):
                reports[id]?.status = .unavailable
                reports[id]?.statusMessage = reason
            case .ruleFailed(let id, let message):
                reports[id]?.status = .failed
                reports[id]?.statusMessage = message
            }
        }

        public func build(volume: VolumeUsage, duration: Double) -> ScanReport {
            let rules = order.compactMap { id -> RuleReport? in
                guard var report = reports[id] else { return nil }
                report.items.sort { ($0.size.bytes ?? 0) > ($1.size.bytes ?? 0) }
                return report
            }
            return ScanReport(volume: volume, durationSeconds: duration, rules: rules)
        }
    }
}
