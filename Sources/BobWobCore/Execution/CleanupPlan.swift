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

    public var summary: String {
        switch self {
        case .removeTree(let url): "Supprimer \(url.path)"
        case .moveToTrash(let url): "Déplacer vers la corbeille : \(url.path)"
        case .ownerCommand(let executable, let arguments):
            "Exécuter \(([executable.path] + arguments).joined(separator: " "))"
        case .dockerAPI(let request): "Docker : \(request.method) \(request.path)"
        }
    }
}

public struct CleanupStep: Sendable {
    public let action: CleanupAction
    public fileprivate(set) var items: [ScanItem]

    public var expectedGain: SizeEstimate {
        items.reduce(SizeEstimate.exact(0)) { $0 + $1.size }
    }
}

public struct CleanupPlan: Sendable {
    public let ruleID: String
    public let risk: RiskLevel
    public let blockingProcesses: [String]
    public let isNamedAfterOwner: Bool
    public let allowedRoots: [URL]
    public let steps: [CleanupStep]
    /// Selected items that no action can clean, such as a Conda cache without its executable.
    public let unplannedItems: [ScanItem]
    public let expectedGain: SizeEstimate

    public var actions: [CleanupAction] {
        steps.map(\.action)
    }

    init(metadata: RuleMetadata, allowedRoots: [URL], entries: [(item: ScanItem, actions: [CleanupAction])]) {
        var steps: [CleanupStep] = []
        var unplanned: [ScanItem] = []
        for entry in entries {
            guard !entry.actions.isEmpty else {
                unplanned.append(entry.item)
                continue
            }
            for (position, action) in entry.actions.enumerated() {
                // Only the first action carries the item, so that its size counts once.
                let items = position == 0 ? [entry.item] : []
                if let existing = steps.firstIndex(where: { $0.action == action }) {
                    steps[existing].items += items
                } else {
                    steps.append(CleanupStep(action: action, items: items))
                }
            }
        }
        self.ruleID = metadata.id
        self.risk = metadata.risk
        self.blockingProcesses = metadata.blockingProcesses
        self.isNamedAfterOwner = metadata.isNamedAfterOwner
        self.allowedRoots = allowedRoots
        self.steps = steps
        self.unplannedItems = unplanned
        self.expectedGain = entries.reduce(SizeEstimate.exact(0)) { $0 + $1.item.size }
    }
}
