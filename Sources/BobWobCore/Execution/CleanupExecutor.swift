import AppKit
import Foundation

public struct ExecutionEnvironment: Sendable {
    public var runCommand: @Sendable (URL, [String]) async throws -> CommandResult
    public var sendDocker: @Sendable (DockerRequest) async throws -> Void
    public var moveToTrash: @Sendable (URL) throws -> Void
    public var isProcessRunning: @Sendable (String) async -> Bool
    public var isOwnerRunning: @Sendable (String) async -> Bool
    public var availableBytes: @Sendable () -> Int64?

    public static func live(home: URL) -> ExecutionEnvironment {
        @Sendable func isProcessRunning(_ name: String, arguments: [String]) async -> Bool {
            // If the check itself fails, the process counts as running: cleaning can wait.
            guard let result = try? await CommandRunner.run(
                URL(fileURLWithPath: "/usr/bin/pgrep"), arguments + [name], timeout: 10
            ) else { return true }
            return result.status != 1
        }

        return ExecutionEnvironment(
            runCommand: { try await CommandRunner.run($0, $1) },
            sendDocker: { request in
                let environment = ProcessInfo.processInfo.environment
                guard let path = DockerEndpoint.resolveSocketPath(home: home, environment: environment) else {
                    throw DockerError.socketNotFound
                }
                _ = try await DockerClient(socketPath: path).send(method: request.method, path: request.path)
            },
            moveToTrash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
            isProcessRunning: { await isProcessRunning($0, arguments: ["-x"]) },
            isOwnerRunning: { name in
                if !NSRunningApplication.runningApplications(withBundleIdentifier: name).isEmpty { return true }
                return await isProcessRunning(name, arguments: ["-i", "-x"])
            },
            availableBytes: { VolumeUsage.read(at: home).availableBytes }
        )
    }
}

public struct StepOutcome: Encodable, Sendable, Equatable {
    public enum Status: String, Encodable, Sendable {
        case wouldRun, succeeded, skipped, failed
    }

    public let ruleID: String
    public let summary: String
    public let status: Status
    public let message: String?
    public let expectedGain: SizeEstimate
}

public struct CleanupReport: Encodable, Sendable {
    public let isDryRun: Bool
    public let outcomes: [StepOutcome]
    public let availableBytesBefore: Int64?
    public let availableBytesAfter: Int64?

    public var measuredGain: Int64? {
        guard !isDryRun, let availableBytesBefore, let availableBytesAfter else { return nil }
        return max(0, availableBytesAfter - availableBytesBefore)
    }

    public func count(_ status: StepOutcome.Status) -> Int {
        outcomes.filter { $0.status == status }.count
    }
}

public struct CleanupExecutor: Sendable {
    private let home: URL
    private let confirmedDataLoss: Bool
    private let environment: ExecutionEnvironment
    private let journal: CleanupJournal

    public init(home: URL, confirmedDataLoss: Bool = false, environment: ExecutionEnvironment? = nil) {
        self.home = home
        self.confirmedDataLoss = confirmedDataLoss
        self.environment = environment ?? .live(home: home)
        self.journal = CleanupJournal(home: home)
    }

    /// A dry run applies every check and only stops short of acting.
    /// A failure on one step never stops the following ones.
    public func run(
        _ plans: [CleanupPlan],
        dryRun: Bool,
        onOutcome: @Sendable (StepOutcome) -> Void = { _ in }
    ) async -> CleanupReport {
        let before = environment.availableBytes()
        var outcomes: [StepOutcome] = []
        func record(_ outcome: StepOutcome) {
            outcomes.append(outcome)
            onOutcome(outcome)
        }

        for plan in plans {
            let refusal = await planRefusal(for: plan)
            for item in plan.unplannedItems {
                record(StepOutcome(
                    ruleID: plan.ruleID,
                    summary: item.title,
                    status: .skipped,
                    message: "Aucune action possible : outil introuvable",
                    expectedGain: item.size
                ))
            }
            for step in plan.steps {
                let outcome: StepOutcome
                if let refusal {
                    outcome = makeOutcome(plan, step, .skipped, refusal)
                } else if Task.isCancelled {
                    outcome = makeOutcome(plan, step, .skipped, "Nettoyage annulé")
                } else {
                    outcome = await perform(step, of: plan, dryRun: dryRun)
                }
                record(outcome)
            }
        }

        return CleanupReport(
            isDryRun: dryRun,
            outcomes: outcomes,
            availableBytesBefore: before,
            availableBytesAfter: dryRun ? before : environment.availableBytes()
        )
    }

    private func planRefusal(for plan: CleanupPlan) async -> String? {
        if plan.risk == .dataLoss, !confirmedDataLoss {
            return "Perte de données possible : confirmation explicite requise"
        }
        for process in plan.blockingProcesses where await environment.isProcessRunning(process) {
            return "À fermer d'abord : \(process)"
        }
        return nil
    }

    private func perform(_ step: CleanupStep, of plan: CleanupPlan, dryRun: Bool) async -> StepOutcome {
        let target: URL?
        switch step.action {
        case .removeTree(let url), .moveToTrash(let url):
            guard let pathGuard = PathGuard(home: home) else {
                return makeOutcome(plan, step, .failed, "Dossier utilisateur introuvable")
            }
            switch pathGuard.evaluate(url, allowedRoots: plan.allowedRoots) {
            case .allowed(let resolved):
                target = resolved
            case .missing:
                return makeOutcome(plan, step, .skipped, "Déjà absent")
            case .refused(let reason):
                return makeOutcome(plan, step, .skipped, reason)
            }
            if isStale(step, at: url) {
                return makeOutcome(plan, step, .skipped, "Modifié depuis le scan : relance le scan")
            }
            if plan.isNamedAfterOwner, await environment.isOwnerRunning(ownerName(of: url)) {
                return makeOutcome(plan, step, .skipped, "App ouverte : à fermer d'abord")
            }
        case .ownerCommand(let executable, _):
            target = nil
            guard executable.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
                return makeOutcome(plan, step, .failed, "Outil introuvable : \(executable.path)")
            }
        case .dockerAPI:
            target = nil
        }

        if dryRun {
            return makeOutcome(plan, step, .wouldRun, nil)
        }

        // Without a journal entry written first, nothing runs.
        do {
            try journal.append(.init(
                time: Date(), phase: "start", ruleID: plan.ruleID, action: step.action.summary, status: nil, message: nil
            ))
        } catch {
            return makeOutcome(plan, step, .failed, "Journal impossible à écrire : \(error.localizedDescription)")
        }

        let outcome = await execute(step, of: plan, target: target)
        try? journal.append(.init(
            time: Date(),
            phase: "result",
            ruleID: plan.ruleID,
            action: step.action.summary,
            status: outcome.status.rawValue,
            message: outcome.message
        ))
        return outcome
    }

    private func execute(_ step: CleanupStep, of plan: CleanupPlan, target: URL?) async -> StepOutcome {
        do {
            switch step.action {
            case .removeTree:
                if let target { try FileManager.default.removeItem(at: target) }
            case .moveToTrash:
                if let target { try environment.moveToTrash(target) }
            case .ownerCommand(let executable, let arguments):
                let result = try await environment.runCommand(executable, arguments)
                guard result.status == 0 else {
                    let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
                    return makeOutcome(plan, step, .failed, "Code \(result.status) : \(detail)")
                }
            case .dockerAPI(let request):
                try await environment.sendDocker(request)
            }
            return makeOutcome(plan, step, .succeeded, nil)
        } catch DockerError.httpStatus(404) {
            return makeOutcome(plan, step, .skipped, "Déjà absent")
        } catch DockerError.httpStatus(409) {
            return makeOutcome(plan, step, .failed, "Ressource Docker en cours d'utilisation")
        } catch DockerError.socketNotFound {
            return makeOutcome(plan, step, .failed, "Docker n'est pas démarré")
        } catch {
            return makeOutcome(plan, step, .failed, error.localizedDescription)
        }
    }

    private func ownerName(of url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".ShipIt", "-updater"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    private func isStale(_ step: CleanupStep, at url: URL) -> Bool {
        step.items.contains { item in
            guard item.path == url.path, let fingerprint = item.fingerprint else { return false }
            return FileFingerprint.read(atPath: url.path) != fingerprint
        }
    }

    private func makeOutcome(
        _ plan: CleanupPlan,
        _ step: CleanupStep,
        _ status: StepOutcome.Status,
        _ message: String?
    ) -> StepOutcome {
        StepOutcome(
            ruleID: plan.ruleID,
            summary: step.action.summary,
            status: status,
            message: message,
            expectedGain: step.expectedGain
        )
    }
}
