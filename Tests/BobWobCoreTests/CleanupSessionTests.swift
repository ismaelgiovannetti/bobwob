import Foundation
import Testing

@testable import BobWobCore

private let noopEnvironment = ExecutionEnvironment(
    runCommand: { _, _ in CommandResult(status: 0, output: "") },
    sendDocker: { _ in },
    moveToTrash: { _ in },
    isProcessRunning: { _ in false },
    isOwnerRunning: { _ in false },
    availableBytes: { 0 }
)

private func rule(_ id: String, risk: RiskLevel, path: String) -> DirectoryRule {
    DirectoryRule(
        metadata: RuleMetadata(id: id, name: id, category: .system, risk: risk, recoveryNote: ""),
        resolveRoots: Roots.fixed(path)
    )
}

@MainActor
@Suite struct CleanupSessionTests {
    private func makeSession(home: URL, rules: [any CleanupRule]) -> CleanupSession {
        CleanupSession(
            rules: rules,
            makeContext: { ScanContext(home: home, docker: DockerUsageProvider { throw DockerError.socketNotFound }) },
            environment: noopEnvironment,
            refreshInterval: 0
        )
    }

    @Test func scanPreselectsOnlySafeItems() async throws {
        let home = try TemporaryDirectory()
        try home.write("safe/a")
        try home.write("risky/a")
        try home.write("loss/a")
        let session = makeSession(home: home.url, rules: [
            rule("safe", risk: .safe, path: "safe"),
            rule("risky", risk: .recoverable, path: "risky"),
            rule("loss", risk: .dataLoss, path: "loss"),
        ])

        session.startScan()
        await session.waitForScan()

        #expect(session.phase == .ready)
        #expect(session.selectedItems.map(\.ruleID) == ["safe"])
    }

    @Test func dataLossCanBeSelectedTogetherButStaysUnselectedByDefault() async throws {
        let home = try TemporaryDirectory()
        try home.write("loss/a")
        try home.write("risky/a")
        let session = makeSession(home: home.url, rules: [
            rule("loss", risk: .dataLoss, path: "loss"),
            rule("risky", risk: .recoverable, path: "risky"),
        ])
        session.startScan()
        await session.waitForScan()

        let loss = session.rules[0]
        #expect(session.selection.isEmpty)
        #expect(session.canSelectWholeRule(loss))
        #expect(session.cleanableItems(with: .dataLoss).map(\.ruleID) == ["loss"])

        session.setSelected(true, rule: loss)
        #expect(session.selectedItems.map(\.ruleID) == ["loss"])
    }

    @Test func selectAllIgnoresInformationalRule() async throws {
        let home = try TemporaryDirectory()
        try home.write("Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", bytes: 100_000)
        let session = makeSession(home: home.url, rules: [DockerDiskRule()])
        session.startScan()
        await session.waitForScan()

        #expect(session.cleanableItems(with: .dataLoss).isEmpty)
        #expect(!session.canSelectWholeRule(session.rules[0]))
    }

    @Test func informationalItemsCannotBeSelected() async throws {
        let home = try TemporaryDirectory()
        let item = ScanItem(id: "info", ruleID: "x", title: "x", size: .exact(1), isCleanable: false)
        let session = makeSession(home: home.url, rules: [])
        session.setSelected(true, item: item)
        #expect(session.selection.isEmpty)
    }

    @Test func dataLossStaysUntouchedWithoutConfirmationThenRefreshes() async throws {
        let home = try TemporaryDirectory()
        let file = try home.write("loss/a")
        let session = makeSession(home: home.url, rules: [rule("loss", risk: .dataLoss, path: "loss")])
        session.startScan()
        await session.waitForScan()
        session.setSelected(true, item: session.rules[0].items[0])

        let preview = try await session.makePreview()
        #expect(preview.includesDataLoss)
        #expect(preview.runnable.count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))

        session.startCleanup(preview, confirmedDataLoss: false)
        await session.waitForCleanup()
        await session.waitForScan()

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(session.lastReport?.count(.skipped) == 1)
        #expect(session.rules[0].items.count == 1)
    }

    @Test func cleanupRemovesSelectionAndRescans() async throws {
        let home = try TemporaryDirectory()
        let file = try home.write("safe/a")
        let session = makeSession(home: home.url, rules: [rule("safe", risk: .safe, path: "safe")])
        session.startScan()
        await session.waitForScan()

        let preview = try await session.makePreview()
        session.startCleanup(preview, confirmedDataLoss: false)
        await session.waitForCleanup()
        await session.waitForScan()

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(session.lastReport?.count(.succeeded) == 1)
        #expect(session.rules[0].status == .absent)
        #expect(session.selection.isEmpty)
    }

    @Test func previewListsDataLossFirst() async throws {
        let home = try TemporaryDirectory()
        try home.write("safe/a")
        try home.write("loss/a")
        let session = makeSession(home: home.url, rules: [
            rule("safe", risk: .safe, path: "safe"),
            rule("loss", risk: .dataLoss, path: "loss"),
        ])
        session.startScan()
        await session.waitForScan()
        session.setSelected(true, item: session.rules[1].items[0])

        let preview = try await session.makePreview()

        #expect(preview.plans.map(\.ruleID) == ["loss", "safe"])
    }

    @Test func previewOnlyPlansSelectedItems() async throws {
        let home = try TemporaryDirectory()
        try home.write("one/a")
        try home.write("two/a")
        let session = makeSession(home: home.url, rules: [
            rule("one", risk: .safe, path: "one"),
            rule("two", risk: .safe, path: "two"),
        ])
        session.startScan()
        await session.waitForScan()
        session.setSelected(false, rule: session.rules[1])

        let preview = try await session.makePreview()

        #expect(preview.plans.map(\.ruleID) == ["one"])
        #expect(preview.runnable.count == 1)
    }
}
