import Foundation
import Observation

public struct CleanupPreview: Sendable {
    public let plans: [CleanupPlan]
    public let report: CleanupReport

    public var runnable: [StepOutcome] {
        report.outcomes.filter { $0.status == .wouldRun }
    }

    public var blocked: [StepOutcome] {
        report.outcomes.filter { $0.status != .wouldRun }
    }

    public var expectedGain: SizeEstimate {
        SizeEstimate.total(of: runnable.map(\.expectedGain))
    }

    public var includesDataLoss: Bool {
        plans.contains { $0.risk == .dataLoss && !$0.steps.isEmpty }
    }

    public var includesTrash: Bool {
        plans.contains { plan in
            plan.actions.contains { if case .moveToTrash = $0 { true } else { false } }
        }
    }
}

@MainActor
@Observable
public final class CleanupSession {
    public enum Phase: Equatable, Sendable {
        case idle, scanning, ready, cleaning
    }

    public private(set) var phase = Phase.idle
    public private(set) var rules: [RuleReport] = []
    public private(set) var volume: VolumeUsage?
    public private(set) var scanningRuleIDs: Set<String> = []
    public private(set) var completedSteps = 0
    public private(set) var totalSteps = 0
    public private(set) var lastReport: CleanupReport?
    public var selection: Set<String> = []

    private let cleanupRules: [any CleanupRule]
    private let makeContext: @Sendable () -> ScanContext
    private let environment: ExecutionEnvironment?
    private let refreshInterval: TimeInterval
    private var context: ScanContext?
    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?

    public init(
        rules: [any CleanupRule] = RuleRegistry.defaultRules(),
        makeContext: @escaping @Sendable () -> ScanContext = { ScanContext() },
        environment: ExecutionEnvironment? = nil,
        refreshInterval: TimeInterval = 0.1
    ) {
        self.cleanupRules = rules
        self.makeContext = makeContext
        self.environment = environment
        self.refreshInterval = refreshInterval
    }

    // MARK: Scan

    public func startScan() {
        guard phase != .scanning, phase != .cleaning else { return }
        phase = .scanning
        selection = []
        scanningRuleIDs = []

        let context = makeContext()
        self.context = context
        volume = VolumeUsage.read(at: context.home)
        let coordinator = ScanCoordinator(rules: cleanupRules, context: context)
        var builder = ScanReport.Builder(rules: cleanupRules.map(\.metadata))
        rules = builder.build(volume: VolumeUsage(totalBytes: nil, availableBytes: nil), duration: 0).rules

        scanTask = Task { [refreshInterval] in
            var lastRefresh = Date.distantPast
            for await update in coordinator.updates() {
                builder.apply(update)
                switch update {
                case .ruleStarted(let id):
                    scanningRuleIDs.insert(id)
                case .ruleFinished(let id), .ruleAbsent(let id), .ruleFailed(let id, _), .ruleUnavailable(let id, _):
                    scanningRuleIDs.remove(id)
                case .ruleEvent(_, .item(let item)) where item.isCleanable && item.isPreselected:
                    selection.insert(item.id)
                case .ruleEvent:
                    break
                }
                // A scan can report thousands of events: the interface follows at a capped rate.
                if Date().timeIntervalSince(lastRefresh) >= refreshInterval {
                    rules = builder.build(volume: VolumeUsage(totalBytes: nil, availableBytes: nil), duration: 0).rules
                    lastRefresh = Date()
                }
            }
            rules = builder.build(volume: VolumeUsage(totalBytes: nil, availableBytes: nil), duration: 0).rules
            scanningRuleIDs = []
            phase = .ready
        }
    }

    public func stop() {
        scanTask?.cancel()
        cleanTask?.cancel()
    }

    public func waitForScan() async {
        await scanTask?.value
    }

    public func waitForCleanup() async {
        await cleanTask?.value
    }

    public var unanalyzedBytes: Int64? {
        guard phase == .ready else { return nil }
        return volume?.unanalyzedBytes(rules: rules)
    }

    // MARK: Selection

    public var selectedItems: [ScanItem] {
        rules.flatMap(\.items).filter { $0.isCleanable && selection.contains($0.id) }
    }

    public var selectedSize: SizeEstimate {
        SizeEstimate.total(of: selectedItems.map(\.size))
    }

    public func cleanableItems(of rule: RuleReport) -> [ScanItem] {
        rule.items.filter(\.isCleanable)
    }

    public func setSelected(_ isSelected: Bool, item: ScanItem) {
        guard item.isCleanable else { return }
        if isSelected {
            selection.insert(item.id)
        } else {
            selection.remove(item.id)
        }
    }

    public func canSelectWholeRule(_ rule: RuleReport) -> Bool {
        !cleanableItems(of: rule).isEmpty
    }

    public func cleanableItems(with risk: RiskLevel) -> [ScanItem] {
        rules.filter { $0.metadata.risk == risk }.flatMap { cleanableItems(of: $0) }
    }

    public func setSelected(_ isSelected: Bool, rule: RuleReport) {
        guard canSelectWholeRule(rule) else { return }
        for item in cleanableItems(of: rule) {
            setSelected(isSelected, item: item)
        }
    }

    // MARK: Cleanup

    public func makePreview() async throws -> CleanupPreview {
        let context = context ?? makeContext()
        var plans: [CleanupPlan] = []
        let selected = selectedItems
        // What can lose data comes first, so that it never sits at the bottom of a long list.
        let riskOrder: [RiskLevel] = [.dataLoss, .recoverable, .safe]
        let orderedRules = riskOrder.flatMap { risk in cleanupRules.filter { $0.metadata.risk == risk } }
        for rule in orderedRules {
            let items = selected.filter { $0.ruleID == rule.metadata.id }
            guard !items.isEmpty else { continue }
            plans.append(try await rule.plan(for: items, in: context))
        }
        let executor = CleanupExecutor(home: context.home, confirmedDataLoss: true, environment: environment)
        return CleanupPreview(plans: plans, report: await executor.run(plans, dryRun: true))
    }

    /// Data-loss plans only run with this explicit confirmation, and the scan restarts afterwards
    /// so that what stays on screen matches the disk.
    public func startCleanup(_ preview: CleanupPreview, confirmedDataLoss: Bool) {
        guard phase == .ready else { return }
        let context = context ?? makeContext()
        phase = .cleaning
        completedSteps = 0
        totalSteps = preview.report.outcomes.count
        lastReport = nil
        let executor = CleanupExecutor(home: context.home, confirmedDataLoss: confirmedDataLoss, environment: environment)

        cleanTask = Task {
            let report = await executor.run(preview.plans, dryRun: false) { [weak self] _ in
                Task { @MainActor in self?.completedSteps += 1 }
            }
            lastReport = report
            phase = .ready
            startScan()
        }
    }

    public func dismissReport() {
        lastReport = nil
    }
}
