import BobWobCore
import Foundation

let usage = """
    Usage :
      bobwob scan [--json] [--rule <id>]...   Analyse le disque sans rien modifier
      bobwob rules                            Liste les règles disponibles
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

    let report = await ScanCoordinator(rules: rules, context: ScanContext()).report()
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

enum CLIError: Error {
    case invalidUsage(String)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "scan":
        try await runScan(arguments: Array(arguments.dropFirst()))
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
