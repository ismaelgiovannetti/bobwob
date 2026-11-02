import Foundation
import Testing

@testable import BobWobCore

private func metadata(_ id: String, risk: RiskLevel = .safe) -> RuleMetadata {
    RuleMetadata(id: id, name: id, category: .system, risk: risk, recoveryNote: "")
}

@Suite struct RuleTests {
    @Test func specificRuleOwnsPathAndGenericRuleExcludesIt() async throws {
        let home = try TemporaryDirectory()
        try home.write("Library/Caches/pip/a", bytes: 1_000_000)
        try home.write("Library/Caches/Other/b", bytes: 100_000)
        let specific = DirectoryRule(metadata: metadata("specific"), resolveRoots: Roots.fixed("Library/Caches/pip"))
        let generic = DirectoryRule(
            metadata: metadata("generic"),
            resolveRoots: Roots.children(of: "Library/Caches") { _ in true }
        )
        let broad = DirectoryRule(metadata: metadata("broad"), resolveRoots: Roots.fixed("Library"))

        let report = await ScanCoordinator(
            rules: [specific, generic, broad],
            context: makeContext(home: home.url)
        ).report()

        let byID = Dictionary(uniqueKeysWithValues: report.rules.map { ($0.metadata.id, $0) })
        #expect(byID["specific"]?.items.count == 1)
        #expect(byID["generic"]?.items.map(\.title) == ["Other"])
        #expect((byID["broad"]?.items ?? []).isEmpty)
        #expect(report.cleanableSize(for: .safe).bytes ?? 0 < 1_500_000)
    }

    @Test func missingTargetIsUnavailable() async throws {
        let home = try TemporaryDirectory()
        let rule = DirectoryRule(metadata: metadata("absent"), resolveRoots: Roots.fixed(".absent"))
        let report = await ScanCoordinator(rules: [rule], context: makeContext(home: home.url)).report()
        #expect(report.rules[0].status == .unavailable)
    }

    @Test func safeItemsArePreselectedOthersAreNot() async throws {
        let home = try TemporaryDirectory()
        try home.write("safe/a")
        try home.write("risky/a")
        let safe = DirectoryRule(metadata: metadata("safe"), resolveRoots: Roots.fixed("safe"))
        let risky = DirectoryRule(metadata: metadata("risky", risk: .recoverable), resolveRoots: Roots.fixed("risky"))

        let report = await ScanCoordinator(rules: [safe, risky], context: makeContext(home: home.url)).report()

        #expect(report.rules[0].items[0].isPreselected)
        #expect(!report.rules[1].items[0].isPreselected)
    }

    @Test func planDeduplicatesOwnerCommandsAndIgnoresOtherRules() async throws {
        let home = try TemporaryDirectory()
        let executable = URL(fileURLWithPath: "/bin/echo")
        let rule = DirectoryRule(
            metadata: metadata("tool"),
            resolveRoots: Roots.fixed("a", "b"),
            purge: { _, _ in [.ownerCommand(executable: executable, arguments: ["clean"])] }
        )
        let items = ["a", "b"].map {
            ScanItem(id: $0, ruleID: "tool", title: $0, path: home.url.appending(path: $0).path, size: .exact(10))
        }
        let foreign = ScanItem(id: "c", ruleID: "other", title: "c", path: "/c", size: .exact(99))

        let plan = try await rule.plan(for: items + [foreign], in: makeContext(home: home.url))

        #expect(plan.actions == [.ownerCommand(executable: executable, arguments: ["clean"])])
        #expect(plan.expectedGain == .exact(20))
    }

    @Test func sizesCombineWithoutOverstatingPrecision() {
        #expect(SizeEstimate.exact(1) + .exact(2) == .exact(3))
        #expect(SizeEstimate.exact(1) + .estimated(2) == .estimated(3))
        #expect(SizeEstimate.exact(1) + .unknown == .estimated(1))
        #expect(SizeEstimate.unknown + .unknown == .unknown)
    }

    @Test func defaultRulesHaveUniqueIDs() {
        let ids = RuleRegistry.defaultRules().map(\.metadata.id)
        #expect(Set(ids).count == ids.count)
    }
}

@Suite struct PersonalFileTests {
    private let day: TimeInterval = 86_400

    @Test func latestDateWinsAndMissingUsageIsApproximate() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 9_000)

        let withoutUsage = FileActivity.resolve(lastUsed: nil, added: old, modified: recent)
        #expect(withoutUsage == FileActivity(date: recent, isApproximate: true))

        let withUsage = FileActivity.resolve(lastUsed: recent, added: old, modified: old)
        #expect(withUsage == FileActivity(date: recent, isApproximate: false))
    }

    @Test func fileWithoutAnyDateIsNeverConsideredOld() {
        let activity = FileActivity.resolve(lastUsed: nil, added: nil, modified: nil)
        #expect(!activity.isOlder(thanDays: 1, relativeTo: Date()))
    }

    @Test func refusesSyncedHiddenBundleRepositoryAndHomeToolFolders() throws {
        let home = try TemporaryDirectory()
        let root = home.url.path
        try home.write("project/.git/HEAD")

        #expect(!PersonalFiles.shouldDescend(into: "\(root)/.cache", home: root))
        #expect(!PersonalFiles.shouldDescend(into: "\(root)/Library", home: root))
        #expect(!PersonalFiles.shouldDescend(into: "\(root)/Downloads", home: root))
        #expect(!PersonalFiles.shouldDescend(into: "\(root)/OneDrive - Perso", home: root))
        #expect(!PersonalFiles.shouldDescend(into: "\(root)/Movies/Trip.photoslibrary", home: root))
        #expect(!PersonalFiles.shouldDescend(into: "\(root)/project", home: root))
        #expect(PersonalFiles.shouldDescend(into: "\(root)/Movies", home: root))
        #expect(PersonalFiles.shouldDescend(into: "\(root)/Movies/Library", home: root))
    }

    @Test func largeFilesAreFoundButSyncedOnesAreSkipped() async throws {
        let home = try TemporaryDirectory()
        let big = try home.write("Movies/big.mov", bytes: 2_000_000)
        try home.write("OneDrive/synced.mov", bytes: 2_000_000)
        try home.write("Movies/small.mov", bytes: 1000)
        var options = ScanOptions()
        options.largeFileMinimumBytes = 1_000_000
        options.largeFileMinimumAgeDays = 30
        let future = Date().addingTimeInterval(60 * day)

        let report = await ScanCoordinator(
            rules: [LargeFilesRule()],
            context: makeContext(home: home.url, now: future, options: options)
        ).report()

        let items = report.rules[0].items
        #expect(items.map(\.path) == [big.standardizedFileURL.path])
        #expect(items[0].isPreselected == false)

        let plan = try await LargeFilesRule().plan(for: items, in: makeContext(home: home.url))
        #expect(plan.actions == [.moveToTrash(URL(fileURLWithPath: items[0].path!))])
        #expect(plan.risk == .dataLoss)
    }

    @Test func recentFilesAreLeftOut() async throws {
        let home = try TemporaryDirectory()
        try home.write("Downloads/recent.zip", bytes: 2_000_000)
        let report = await ScanCoordinator(rules: [DownloadsRule()], context: makeContext(home: home.url)).report()
        #expect(report.rules[0].items.isEmpty)
    }

    @Test func oldDownloadsGoToTrashOneByOneUnselected() async throws {
        let home = try TemporaryDirectory()
        try home.write("Downloads/old.zip", bytes: 2_000_000)
        try home.write("Downloads/.hidden", bytes: 2_000_000)
        try home.write("Downloads/repo/.git/HEAD", bytes: 2_000_000)
        let future = Date().addingTimeInterval(365 * day)

        let context = makeContext(home: home.url, now: future)
        let report = await ScanCoordinator(rules: [DownloadsRule()], context: context).report()

        let items = report.rules[0].items
        #expect(items.map(\.title) == ["old.zip"])
        #expect(items[0].isPreselected == false)
        let plan = try await DownloadsRule().plan(for: items, in: context)
        #expect(plan.actions == [.moveToTrash(URL(fileURLWithPath: items[0].path!))])
    }
}
