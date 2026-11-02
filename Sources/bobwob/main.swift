import BobWobCore
import Foundation

let usage = """
    Usage :
      bobwob scan [--json] [--rule <id>]...   Analyse le disque sans rien modifier
      bobwob clean --rule <id>... [options]   Affiche le plan, sans rien modifier sans --yes
      bobwob rules                            Liste les règles disponibles

    Options de clean :
      --item <chemin|id>    Choisit un élément (obligatoire pour une règle à perte possible)
      --all-items           Choisit tous les éléments, sauf sur une règle à perte possible
      --allow-data-loss     Autorise les règles à perte possible
      --yes                 Exécute réellement le plan

    Sans --item ni --all-items, seuls les éléments précochés sont choisis.
    """

func formatBytes(_ bytes: Int64?) -> String {
    guard let bytes else { return "inconnu" }
    return String(format: "%.2f Go", Double(bytes) / 1_000_000_000)
}

func format(_ size: SizeEstimate) -> String {
    switch size {
    case .exact(let bytes): formatBytes(bytes)
    case .estimated(let bytes): "~" + formatBytes(bytes)
    case .unknown: "inconnu"
    }
}

func printSummary(_ report: ScanReport) {
    print("Volume : \(formatBytes(report.volume.availableBytes)) libres sur \(formatBytes(report.volume.totalBytes))")
    print(String(format: "Scan terminé en %.1f s\n", report.durationSeconds))

    let labels: [(RiskLevel, String)] = [(.safe, "SÛR"), (.recoverable, "RÉCUPÉRABLE"), (.dataLoss, "PERTE POSSIBLE")]
    for (risk, label) in labels {
        print("\(label) : \(format(report.cleanableSize(for: risk)))")
        for rule in report.rules where rule.metadata.risk == risk {
            switch rule.status {
            case .completed:
                let name = rule.metadata.name.padding(toLength: 34, withPad: " ", startingAt: 0)
                let information = rule.items.filter { !$0.isCleanable }
                if rule.items.isEmpty {
                    print("  \(name) rien à nettoyer")
                } else if information.count == rule.items.count {
                    let occupied = information.reduce(SizeEstimate.exact(0)) { $0 + $1.size }
                    print("  \(name) \(format(occupied)) occupés (information, non nettoyable)")
                } else {
                    let count = rule.items.count
                    print("  \(name) \(format(rule.cleanableSize)) (\(count) élément\(count > 1 ? "s" : ""))")
                }
                for warning in rule.warnings { print("    ! \(warning)") }
            case .absent:
                let name = rule.metadata.name.padding(toLength: 34, withPad: " ", startingAt: 0)
                print("  \(name) aucune donnée trouvée")
            case .unavailable, .failed:
                let name = rule.metadata.name.padding(toLength: 34, withPad: " ", startingAt: 0)
                print("  \(name) \(rule.statusMessage ?? "indisponible")")
            }
        }
        print()
    }
}

func runScan(arguments: [String]) async throws {
    var asJSON = false
    var selected: Set<String> = []
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
        switch argument {
        case "--json":
            asJSON = true
        case "--rule":
            guard let id = remaining.popFirst() else {
                throw CLIError.invalidUsage("--rule attend un identifiant")
            }
            selected.insert(id)
        default:
            throw CLIError.invalidUsage("Argument inconnu : \(argument)")
        }
    }

    let allRules = RuleRegistry.defaultRules()
    let unknown = selected.subtracting(allRules.map(\.metadata.id))
    guard unknown.isEmpty else {
        throw CLIError.invalidUsage("Règle inconnue : \(unknown.sorted().joined(separator: ", "))")
    }
    let rules = selected.isEmpty ? allRules : allRules.filter { selected.contains($0.metadata.id) }

    let report = await ScanCoordinator(rules: rules, context: ScanContext(), ledgerRules: allRules).report()
    if asJSON {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(report))
        print()
    } else {
        printSummary(report)
    }
}

func runClean(arguments: [String]) async throws -> Int32 {
    var ruleIDs: [String] = []
    var itemKeys: Set<String> = []
    var allItems = false
    var allowDataLoss = false
    var confirmed = false
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
        switch argument {
        case "--rule":
            guard let id = remaining.popFirst() else { throw CLIError.invalidUsage("--rule attend un identifiant") }
            ruleIDs.append(id)
        case "--item":
            guard let key = remaining.popFirst() else { throw CLIError.invalidUsage("--item attend un chemin ou un id") }
            itemKeys.insert(key)
        case "--all-items": allItems = true
        case "--allow-data-loss": allowDataLoss = true
        case "--yes": confirmed = true
        default: throw CLIError.invalidUsage("Argument inconnu : \(argument)")
        }
    }
    guard !ruleIDs.isEmpty else { throw CLIError.invalidUsage("clean exige au moins une règle avec --rule") }

    let allRules = RuleRegistry.defaultRules()
    let rules = allRules.filter { ruleIDs.contains($0.metadata.id) }
    let unknown = Set(ruleIDs).subtracting(rules.map(\.metadata.id))
    guard unknown.isEmpty else {
        throw CLIError.invalidUsage("Règle inconnue : \(unknown.sorted().joined(separator: ", "))")
    }

    let context = ScanContext()
    let scan = await ScanCoordinator(rules: rules, context: context, ledgerRules: allRules).report()

    var plans: [CleanupPlan] = []
    var matchedKeys: Set<String> = []
    for rule in rules {
        guard let ruleReport = scan.rules.first(where: { $0.metadata.id == rule.metadata.id }) else { continue }
        if ruleReport.status != .completed {
            print("\(rule.metadata.name) : \(ruleReport.statusMessage ?? "indisponible")")
        }
        let selection = ruleReport.items.filter { item in
            let keys = [item.id, item.path].compactMap { $0 }
            if keys.contains(where: itemKeys.contains) {
                matchedKeys.formUnion(keys.filter(itemKeys.contains))
                return true
            }
            guard itemKeys.isEmpty else { return false }
            return rule.metadata.risk != .dataLoss && (allItems || item.isPreselected)
        }
        plans.append(try await rule.plan(for: selection, in: context))
    }
    let unmatched = itemKeys.subtracting(matchedKeys)
    guard unmatched.isEmpty else {
        throw CLIError.invalidUsage("Élément introuvable : \(unmatched.sorted().joined(separator: ", "))")
    }

    let executor = CleanupExecutor(home: context.home, confirmedDataLoss: allowDataLoss)
    let report = await executor.run(plans, dryRun: !confirmed) { outcome in
        var line = "[\(outcome.status.rawValue)] \(outcome.summary) (\(format(outcome.expectedGain)))"
        if let message = outcome.message { line += " : \(message)" }
        print(line)
    }

    if report.outcomes.isEmpty {
        print("Rien à nettoyer avec cette sélection.")
    } else if report.isDryRun {
        print("\nAperçu seulement : rien n'a été modifié. Ajoute --yes pour exécuter.")
    } else {
        print("\nRéussis : \(report.count(.succeeded)), ignorés : \(report.count(.skipped)), échecs : \(report.count(.failed))")
        print("Espace libre mesuré : +\(formatBytes(report.measuredGain))")
    }
    return report.count(.failed) > 0 ? 1 : 0
}

enum CLIError: Error {
    case invalidUsage(String)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "scan":
        try await runScan(arguments: Array(arguments.dropFirst()))
    case "clean":
        let status = try await runClean(arguments: Array(arguments.dropFirst()))
        exit(status)
    case "rules":
        for rule in RuleRegistry.defaultRules() {
            print("\(rule.metadata.id)\t\(rule.metadata.risk.rawValue)\t\(rule.metadata.name)")
        }
    default:
        print(usage)
        exit(arguments.isEmpty ? 0 : 64)
    }
} catch CLIError.invalidUsage(let message) {
    FileHandle.standardError.write(Data((message + "\n\n" + usage + "\n").utf8))
    exit(64)
}
