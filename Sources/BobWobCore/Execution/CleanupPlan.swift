import Foundation

public struct DockerRequest: Hashable, Sendable {
    public let method: String
    public let path: String

    public init(method: String, path: String) {
        self.method = method
        self.path = path
    }
}

public enum CleanupAction: Hashable, Sendable {
    case removeTree(URL)
    case moveToTrash(URL)
    case ownerCommand(executable: URL, arguments: [String])
    case dockerAPI(DockerRequest)
}

public struct CleanupPlan: Sendable {
    public let ruleID: String
    public let risk: RiskLevel
    public let blockingProcesses: [String]
    public let actions: [CleanupAction]
    public let expectedGain: SizeEstimate

    init(metadata: RuleMetadata, items: [ScanItem], actions: [CleanupAction]) {
        var unique: [CleanupAction] = []
        var seen = Set<CleanupAction>()
        for action in actions where seen.insert(action).inserted {
            unique.append(action)
        }
        self.ruleID = metadata.id
        self.risk = metadata.risk
        self.blockingProcesses = metadata.blockingProcesses
        self.actions = unique
        self.expectedGain = items.reduce(SizeEstimate.exact(0)) { $0 + $1.size }
    }
}
