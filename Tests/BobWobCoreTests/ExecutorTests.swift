import Foundation
import Testing

@testable import BobWobCore

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func add(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private func stubEnvironment(
    recorder: Recorder = Recorder(),
    runningProcesses: Set<String> = [],
    runningOwners: Set<String> = [],
    commandStatus: Int32 = 0,
    dockerError: DockerError? = nil
) -> ExecutionEnvironment {
    ExecutionEnvironment(
        runCommand: { executable, arguments in
            recorder.add("command:\(executable.lastPathComponent) \(arguments.joined(separator: " "))")
            return CommandResult(status: commandStatus, output: "sortie de test")
        },
        sendDocker: { request in
            recorder.add("docker:\(request.method) \(request.path)")
            if let dockerError { throw dockerError }
        },
        moveToTrash: { url in
            recorder.add("trash:\(url.lastPathComponent)")
        },
        isProcessRunning: { runningProcesses.contains($0) },
        isOwnerRunning: { runningOwners.contains($0) },
        availableBytes: { 1000 }
    )
}

private func metadata(risk: RiskLevel = .safe, blocking: [String] = []) -> RuleMetadata {
    RuleMetadata(id: "test", name: "Test", category: .system, risk: risk, recoveryNote: "", blockingProcesses: blocking)
}

private func item(at url: URL, fingerprint: FileFingerprint? = nil) -> ScanItem {
    ScanItem(id: url.path, ruleID: "test", title: url.lastPathComponent, path: url.path, size: .exact(100), fingerprint: fingerprint)
}

private func removalPlan(
    _ url: URL,
    allowedRoots: [URL],
    metadata rule: RuleMetadata = metadata(),
    fingerprint: FileFingerprint? = nil
) -> CleanupPlan {
    CleanupPlan(
        metadata: rule,
        allowedRoots: allowedRoots,
        entries: [(item: item(at: url, fingerprint: fingerprint), actions: [.removeTree(url)])]
    )
}

@Suite struct PathGuardTests {
    @Test func refusesHomeStandardFoldersAndParents() throws {
        let home = try TemporaryDirectory()
        let pathGuard = try #require(PathGuard(home: home.url))
        let roots = [home.url]

        for relative in ["Library", "Library/Caches", "Documents", "Downloads", "Library/Application Support"] {
            let url = home.url.appending(path: relative)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            #expect(pathGuard.evaluate(url, allowedRoots: roots) == .refused("Dossier protégé"), "\(relative)")
        }
        let isHomeRefused = pathGuard.evaluate(home.url, allowedRoots: [home.url.deletingLastPathComponent()])
        #expect(isHomeRefused == .refused("Chemin hors du dossier utilisateur"))
    }

    @Test func refusesEverythingOutsideHome() throws {
        let home = try TemporaryDirectory()
        let outside = try TemporaryDirectory()
        let file = try outside.write("file")
        let pathGuard = try #require(PathGuard(home: home.url))

        for url in [URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/System"), URL(fileURLWithPath: "/Applications"), file] {
            #expect(pathGuard.evaluate(url, allowedRoots: [URL(fileURLWithPath: "/")]) == .refused("Chemin hors du dossier utilisateur"))
        }
    }

    @Test func refusesTraversalOutOfDeclaredRoot() throws {
        let home = try TemporaryDirectory()
        try home.write("cache/a")
        let secret = try home.write("secret/b")
        let pathGuard = try #require(PathGuard(home: home.url))
        let escaping = URL(fileURLWithPath: home.url.path + "/cache/../secret/b")

        #expect(pathGuard.evaluate(escaping, allowedRoots: [home.url.appending(path: "cache")])
            == .refused("Chemin hors des racines déclarées par la règle"))
        guard case .allowed(let resolved) = pathGuard.evaluate(secret, allowedRoots: [home.url.appending(path: "secret")]) else {
            Issue.record("Le chemin déclaré devrait être accepté")
            return
        }
        #expect(resolved.path.hasSuffix("/secret/b"))
    }

    @Test func similarPrefixIsNotInsideRoot() throws {
        let home = try TemporaryDirectory()
        let sibling = try home.write("cache-precious/a")
        let pathGuard = try #require(PathGuard(home: home.url))
        #expect(pathGuard.evaluate(sibling, allowedRoots: [home.url.appending(path: "cache")])
            == .refused("Chemin hors des racines déclarées par la règle"))
    }

    @Test func refusesSymbolicLinkAndParentLinkEscapingHome() throws {
        let home = try TemporaryDirectory()
        let outside = try TemporaryDirectory()
        try outside.write("precious/file")
        let root = home.url.appending(path: "cache")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
        let pathGuard = try #require(PathGuard(home: home.url))

        #expect(pathGuard.evaluate(link, allowedRoots: [root]) == .refused("Lien symbolique refusé"))
        #expect(pathGuard.evaluate(link.appending(path: "precious"), allowedRoots: [root])
            == .refused("Chemin hors du dossier utilisateur"))
    }

    @Test func refusesSensitiveSubtreesEvenWhenDeclared() throws {
        let home = try TemporaryDirectory()
        let key = try home.write(".ssh/id_ed25519")
        let cloud = try home.write("Library/CloudStorage/OneDrive/file")
        let journal = try home.write("Library/Logs/BobWob/cleanup.log")
        let pathGuard = try #require(PathGuard(home: home.url))

        for url in [key, cloud, journal] {
            #expect(pathGuard.evaluate(url, allowedRoots: [home.url]) == .refused("Dossier protégé"))
        }
    }

    @Test func missingPathIsReported() throws {
        let home = try TemporaryDirectory()
        let pathGuard = try #require(PathGuard(home: home.url))
        #expect(pathGuard.evaluate(home.url.appending(path: "absent"), allowedRoots: [home.url]) == .missing)
    }
}

@Suite struct CleanupExecutorTests {
    @Test func dryRunChangesNothingAndWritesNoJournal() async throws {
        let home = try TemporaryDirectory()
        let file = try home.write("cache/a")
        let root = file.deletingLastPathComponent()
        let recorder = Recorder()
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment(recorder: recorder))
        let command = CleanupPlan(
            metadata: metadata(),
            allowedRoots: [],
            entries: [(item: item(at: root), actions: [.ownerCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [])])]
        )

        let report = await executor.run([removalPlan(root, allowedRoots: [root]), command], dryRun: true)

        #expect(report.outcomes.map(\.status) == [.wouldRun, .wouldRun])
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(recorder.all.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: CleanupJournal(home: home.url).url.path))
        #expect(report.measuredGain == nil)
    }

    @Test func dryRunStillReportsRefusals() async throws {
        let home = try TemporaryDirectory()
        let documents = home.url.appending(path: "Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment())

        let report = await executor.run([removalPlan(documents, allowedRoots: [home.url])], dryRun: true)

        #expect(report.outcomes[0].status == .skipped)
        #expect(report.outcomes[0].message == "Dossier protégé")
    }

    @Test func removesAllowedTreeWithoutFollowingInnerLinks() async throws {
        let home = try TemporaryDirectory()
        let outside = try TemporaryDirectory()
        let precious = try outside.write("precious")
        try home.write("cache/a")
        let root = home.url.appending(path: "cache")
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: outside.url)
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment())

        let report = await executor.run([removalPlan(root, allowedRoots: [root])], dryRun: false)

        #expect(report.outcomes[0].status == .succeeded)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: precious.path))
    }

    @Test func modifiedItemIsSkipped() async throws {
        let home = try TemporaryDirectory()
        let file = try home.write("cache/a")
        let fingerprint = try #require(FileFingerprint.read(atPath: file.path))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: file.path
        )
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment())

        let plan = removalPlan(file, allowedRoots: [file.deletingLastPathComponent()], fingerprint: fingerprint)
        let report = await executor.run([plan], dryRun: false)

        #expect(report.outcomes[0].status == .skipped)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func replacedItemIsSkippedEvenWithSameDate() async throws {
        let home = try TemporaryDirectory()
        let file = try home.write("cache/a")
        let fingerprint = try #require(FileFingerprint.read(atPath: file.path))
        let date = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let keeper = try home.write("cache/keep")
        try FileManager.default.removeItem(at: file)
        try home.write("cache/a")
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment())

        let plan = removalPlan(file, allowedRoots: [file.deletingLastPathComponent()], fingerprint: fingerprint)
        let report = await executor.run([plan], dryRun: false)

        #expect(report.outcomes[0].status == .skipped)
        #expect(FileManager.default.fileExists(atPath: keeper.path))
    }

    @Test func runningProcessBlocksWholePlan() async throws {
        let home = try TemporaryDirectory()
        let file = try home.write("cache/a")
        let root = file.deletingLastPathComponent()
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment(runningProcesses: ["Code"]))

        let plan = removalPlan(root, allowedRoots: [root], metadata: metadata(blocking: ["Code"]))
        let report = await executor.run([plan], dryRun: false)

        #expect(report.outcomes[0].status == .skipped)
        #expect(report.outcomes[0].message == "À fermer d'abord : Code")
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func openAppProtectsItsOwnCachesOnly() async throws {
        let home = try TemporaryDirectory()
        let root = home.url.appending(path: "Library/Caches")
        let open = try home.write("Library/Caches/com.example.open/a").deletingLastPathComponent()
        let updater = try home.write("Library/Caches/com.example.open.ShipIt/a").deletingLastPathComponent()
        let closed = try home.write("Library/Caches/com.example.closed/a").deletingLastPathComponent()
        let rule = RuleMetadata(id: "test", name: "Test", category: .system, risk: .recoverable, recoveryNote: "", isNamedAfterOwner: true)
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment(runningOwners: ["com.example.open"]))

        let plans = [open, updater, closed].map { removalPlan($0, allowedRoots: [root], metadata: rule) }
        let report = await executor.run(plans, dryRun: false)

        #expect(report.outcomes.map(\.status) == [.skipped, .skipped, .succeeded])
        #expect(FileManager.default.fileExists(atPath: open.path))
        #expect(FileManager.default.fileExists(atPath: updater.path))
        #expect(!FileManager.default.fileExists(atPath: closed.path))
    }

    @Test func dataLossRequiresConfirmation() async throws {
        let home = try TemporaryDirectory()
        let file = try home.write("old.zip")
        let recorder = Recorder()
        let plan = CleanupPlan(
            metadata: metadata(risk: .dataLoss),
            allowedRoots: [home.url],
            entries: [(item: item(at: file), actions: [.moveToTrash(file)])]
        )

        let refused = await CleanupExecutor(home: home.url, environment: stubEnvironment(recorder: recorder))
            .run([plan], dryRun: false)
        #expect(refused.outcomes[0].status == .skipped)
        #expect(recorder.all.isEmpty)

        let accepted = await CleanupExecutor(home: home.url, confirmedDataLoss: true, environment: stubEnvironment(recorder: recorder))
            .run([plan], dryRun: false)
        #expect(accepted.outcomes[0].status == .succeeded)
        #expect(recorder.all == ["trash:old.zip"])
    }

    @Test func failureDoesNotStopFollowingSteps() async throws {
        let home = try TemporaryDirectory()
        let locked = try home.write("cache/locked/file").deletingLastPathComponent()
        let free = try home.write("cache/free/file").deletingLastPathComponent()
        let root = home.url.appending(path: "cache")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment())

        let report = await executor.run(
            [removalPlan(locked, allowedRoots: [root]), removalPlan(free, allowedRoots: [root])],
            dryRun: false
        )

        #expect(report.outcomes.map(\.status) == [.failed, .succeeded])
        #expect(!FileManager.default.fileExists(atPath: free.path))
    }

    @Test func commandFailureReportsExitCodeAndOutput() async throws {
        let home = try TemporaryDirectory()
        let plan = CleanupPlan(
            metadata: metadata(),
            allowedRoots: [],
            entries: [(item: item(at: home.url), actions: [.ownerCommand(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"])])]
        )
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment(commandStatus: 3))

        let report = await executor.run([plan], dryRun: false)

        #expect(report.outcomes[0].status == .failed)
        #expect(report.outcomes[0].message == "Code 3 : sortie de test")
    }

    @Test func missingExecutableFails() async throws {
        let home = try TemporaryDirectory()
        let plan = CleanupPlan(
            metadata: metadata(),
            allowedRoots: [],
            entries: [(item: item(at: home.url), actions: [.ownerCommand(executable: URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])])]
        )
        let report = await CleanupExecutor(home: home.url, environment: stubEnvironment()).run([plan], dryRun: true)
        #expect(report.outcomes[0].status == .failed)
    }

    @Test func dockerErrorsAreTranslated() async throws {
        let home = try TemporaryDirectory()
        let plan = CleanupPlan(
            metadata: metadata(),
            allowedRoots: [],
            entries: [(item: item(at: home.url), actions: [.dockerAPI(DockerRequest(method: "DELETE", path: "/volumes/x"))])]
        )

        let cases: [(DockerError, StepOutcome.Status)] = [(.httpStatus(404), .skipped), (.httpStatus(409), .failed), (.socketNotFound, .failed)]
        for (error, expected) in cases {
            let executor = CleanupExecutor(home: home.url, environment: stubEnvironment(dockerError: error))
            let report = await executor.run([plan], dryRun: false)
            #expect(report.outcomes[0].status == expected)
        }
    }

    @Test func journalRecordsIntentBeforeResult() async throws {
        let home = try TemporaryDirectory()
        let root = try home.write("cache/a").deletingLastPathComponent()
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment())

        _ = await executor.run([removalPlan(root, allowedRoots: [root])], dryRun: false)

        let lines = try String(contentsOf: CleanupJournal(home: home.url).url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains(#""phase":"start""#))
        #expect(lines[1].contains(#""status":"succeeded""#))
    }

    @Test func nothingRunsWhenJournalCannotBeWritten() async throws {
        let home = try TemporaryDirectory()
        let file = try home.write("cache/a")
        let root = file.deletingLastPathComponent()
        try home.write("Library", bytes: 1)
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment())

        let report = await executor.run([removalPlan(root, allowedRoots: [root])], dryRun: false)

        #expect(report.outcomes[0].status == .failed)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func cancellationSkipsRemainingSteps() async throws {
        let home = try TemporaryDirectory()
        let file = try home.write("cache/a")
        let root = file.deletingLastPathComponent()
        let executor = CleanupExecutor(home: home.url, environment: stubEnvironment())
        let plan = removalPlan(root, allowedRoots: [root])

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await executor.run([plan], dryRun: false)
        }
        let report = await task.value

        #expect(report.outcomes[0].status == .skipped)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func itemWithoutActionIsReported() async throws {
        let home = try TemporaryDirectory()
        let plan = CleanupPlan(metadata: metadata(), allowedRoots: [], entries: [(item: item(at: home.url), actions: [])])
        let report = await CleanupExecutor(home: home.url, environment: stubEnvironment()).run([plan], dryRun: false)
        #expect(report.outcomes[0].status == .skipped)
    }

    @Test func androidPlanCountsSizeOnceAcrossTwoActions() async throws {
        let home = try TemporaryDirectory()
        let device = home.url.appending(path: ".android/avd/Pixel.avd")
        let plan = CleanupPlan(
            metadata: metadata(),
            allowedRoots: [],
            entries: [(item: item(at: device), actions: [.removeTree(device), .removeTree(device.deletingPathExtension().appendingPathExtension("ini"))])]
        )
        #expect(plan.steps.count == 2)
        #expect(plan.steps.reduce(SizeEstimate.exact(0)) { $0 + $1.expectedGain } == .exact(100))
    }
}

@Suite struct CommandRunnerTests {
    @Test func capturesStatusAndOutput() async throws {
        let result = try await CommandRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo salut; echo erreur >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.output.contains("salut"))
        #expect(result.output.contains("erreur"))
    }

    @Test func argumentsAreNotInterpretedByAShell() async throws {
        let result = try await CommandRunner.run(URL(fileURLWithPath: "/bin/echo"), ["$(whoami); ls"])
        #expect(result.output == "$(whoami); ls\n")
    }

    @Test func timeoutTerminatesProcess() async throws {
        let result = try await CommandRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.2)
        #expect(result.status != 0)
    }
}

@Test func liveTrashMovesFile() throws {
    let home = try TemporaryDirectory()
    let file = try home.write("to-trash.txt", bytes: 16)
    var trashed: NSURL?
    try FileManager.default.trashItem(at: file, resultingItemURL: &trashed)
    defer { if let trashed { try? FileManager.default.removeItem(at: trashed as URL) } }
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(trashed != nil)
}

@Test func systemCachesAndLogsAreNeverOffered() async throws {
    let home = try TemporaryDirectory()
    for name in ["CloudKit", "PassKit", "GeoServices", "com.apple.nsurlsessiond", "conda-anaconda-tos", "Firefox"] {
        try home.write("Library/Caches/\(name)/a", bytes: 100_000)
    }
    for name in ["DiagnosticReports", "com.apple.AMPLibraryAgent", "JetBrains"] {
        try home.write("Library/Logs/\(name)/a", bytes: 100_000)
    }
    let all = RuleRegistry.defaultRules()
    let rules = all.filter { ["apps.caches", "system.logs"].contains($0.metadata.id) }

    let report = await ScanCoordinator(rules: rules, context: makeContext(home: home.url), ledgerRules: all).report()

    #expect(report.rules[0].items.map(\.title) == ["Firefox"])
    #expect(report.rules[1].items.map(\.title) == ["JetBrains"])
}

@Test func partialScanKeepsFullLedgerOwnership() async throws {
    let home = try TemporaryDirectory()
    try home.write("Library/Caches/pip/a", bytes: 100_000)
    try home.write("Library/Caches/Other/b", bytes: 100_000)
    let all = RuleRegistry.defaultRules()
    let generic = try #require(all.first { $0.metadata.id == "apps.caches" })

    let report = await ScanCoordinator(rules: [generic], context: makeContext(home: home.url), ledgerRules: all).report()

    #expect(report.rules[0].items.map(\.title) == ["Other"])
}
