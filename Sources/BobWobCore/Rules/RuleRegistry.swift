import Foundation

public enum RuleRegistry {
    // System services keep their caches and logs here, often without a com.apple prefix.
    private static let systemCacheNames: Set<String> = [
        "Animoji", "CloudKit", "FamilyCircle", "GameKit", "GeoServices", "INSTALLATION", "JetPackCache",
        "PassKit", "askpermissiond", "conda-anaconda-tos", "familycircled",
    ]

    private static let systemLogNames: Set<String> = [
        "CoreSimulator", "DeviceLink", "DiagnosticReports", "DiscRecording.log", "PhotosSearch.aapbz",
        "PhotosUpgrade.aapbz", "X11", "fsck_hfs.log",
    ]

    /// Specific rules come first: the first rule to claim a path owns it.
    public static func defaultRules() -> [any CleanupRule] {
        [
            npm, nuget, pip, conda, homebrew, playwright,
            vsCodeCaches, jetBrainsCaches, appUpdaters,
            DockerRule(kind: .images), DockerRule(kind: .buildCache),
            DockerRule(kind: .containers), DockerRule(kind: .volumes), DockerDiskRule(),
            androidVirtualDevices, utmVirtualMachines,
            otherAppCaches, userLogs,
            DownloadsRule(), LargeFilesRule(),
        ]
    }

    private static func ownerCommand(_ tool: String, _ arguments: [String]) -> @Sendable (URL, ScanContext) -> [CleanupAction] {
        { root, context in
            guard let executable = ToolLocator.find(tool, home: context.home) else { return [.removeTree(root)] }
            return [.ownerCommand(executable: executable, arguments: arguments)]
        }
    }

    private static let npm = DirectoryRule(
        metadata: RuleMetadata(
            id: "npm.cache",
            name: "Cache npm",
            category: .packageManagers,
            risk: .safe,
            recoveryNote: "Retéléchargé au prochain npm install"
        ),
        resolveRoots: Roots.fixed(".npm/_cacache"),
        purge: ownerCommand("npm", ["cache", "clean", "--force"])
    )

    private static let nuget = DirectoryRule(
        metadata: RuleMetadata(
            id: "nuget.packages",
            name: "Paquets NuGet",
            category: .packageManagers,
            risk: .recoverable,
            recoveryNote: "Retéléchargés à la prochaine restauration .NET"
        ),
        resolveRoots: Roots.fixed(".nuget/packages"),
        purge: ownerCommand("dotnet", ["nuget", "locals", "all", "--clear"])
    )

    private static let pip = DirectoryRule(
        metadata: RuleMetadata(
            id: "pip.cache",
            name: "Cache pip",
            category: .packageManagers,
            risk: .safe,
            recoveryNote: "Retéléchargé au prochain pip install"
        ),
        resolveRoots: Roots.fixed("Library/Caches/pip"),
        purge: ownerCommand("pip3", ["cache", "purge"])
    )

    private static let conda = DirectoryRule(
        metadata: RuleMetadata(
            id: "conda.packages",
            name: "Paquets Conda",
            category: .packageManagers,
            risk: .recoverable,
            recoveryNote: "Les environnements restent en place, les paquets sont retéléchargés si besoin"
        ),
        resolveRoots: Roots.fixed("miniconda3/pkgs", "anaconda3/pkgs"),
        purge: { root, _ in
            // Each installation has its own conda and its own package cache.
            let executable = root.deletingLastPathComponent().appending(path: "bin/conda")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else { return [] }
            return [.ownerCommand(executable: executable, arguments: ["clean", "--all", "--yes"])]
        }
    )

    // `brew cleanup` also removes old installed versions, which goes beyond this cache.
    private static let homebrew = DirectoryRule(
        metadata: RuleMetadata(
            id: "homebrew.cache",
            name: "Téléchargements Homebrew",
            category: .packageManagers,
            risk: .safe,
            recoveryNote: "Retéléchargés à la prochaine installation"
        ),
        resolveRoots: Roots.fixed("Library/Caches/Homebrew"),
        purge: { root, _ in [.removeTree(root)] }
    )

    private static let playwright = DirectoryRule(
        metadata: RuleMetadata(
            id: "playwright.browsers",
            name: "Navigateurs Playwright",
            category: .packageManagers,
            risk: .recoverable,
            recoveryNote: "À réinstaller avec playwright install"
        ),
        resolveRoots: Roots.fixed("Library/Caches/ms-playwright", "Library/Caches/ms-playwright-go")
    )

    private static let vsCodeCaches = DirectoryRule(
        metadata: RuleMetadata(
            id: "vscode.caches",
            name: "Caches VS Code",
            category: .ide,
            risk: .safe,
            recoveryNote: "Recréés par VS Code",
            blockingProcesses: ["Code", "Electron"]
        ),
        resolveRoots: Roots.fixed(
            "Library/Application Support/Code/Cache",
            "Library/Application Support/Code/CachedData",
            "Library/Application Support/Code/CachedExtensionVSIXs",
            "Library/Application Support/Code/Code Cache",
            "Library/Application Support/Code/GPUCache"
        )
    )

    private static let jetBrainsCaches = DirectoryRule(
        metadata: RuleMetadata(
            id: "jetbrains.caches",
            name: "Caches JetBrains",
            category: .ide,
            risk: .safe,
            recoveryNote: "Recréés à la réouverture, avec une réindexation",
            blockingProcesses: ["datagrip", "idea", "webstorm", "pycharm"]
        ),
        resolveRoots: Roots.fixed("Library/Caches/JetBrains")
    )

    private static let appUpdaters = DirectoryRule(
        metadata: RuleMetadata(
            id: "apps.updaters",
            name: "Mises à jour d'apps en cache",
            category: .system,
            risk: .safe,
            recoveryNote: "Retéléchargées à la prochaine mise à jour",
            isNamedAfterOwner: true
        ),
        resolveRoots: Roots.children(of: "Library/Caches") { $0.hasSuffix(".ShipIt") || $0.hasSuffix("-updater") }
    )

    private static let androidVirtualDevices = DirectoryRule(
        metadata: RuleMetadata(
            id: "android.avd",
            name: "Émulateurs Android",
            category: .emulators,
            risk: .dataLoss,
            recoveryNote: "Les données de l'émulateur sont perdues",
            blockingProcesses: ["qemu-system-aarch64", "qemu-system-x86_64"]
        ),
        resolveRoots: Roots.children(of: ".android/avd") { $0.hasSuffix(".avd") },
        purge: { root, _ in
            let descriptor = root.deletingPathExtension().appendingPathExtension("ini")
            return [.removeTree(root), .removeTree(descriptor)]
        },
        additionalAllowedRoots: Roots.fixed(".android/avd")
    )

    // A virtual machine holds real data: it goes to the Trash, unlike the caches above.
    private static let utmVirtualMachines = DirectoryRule(
        metadata: RuleMetadata(
            id: "utm.virtualMachines",
            name: "Machines virtuelles UTM",
            category: .emulators,
            risk: .dataLoss,
            recoveryNote: "Déplacées vers la corbeille, récupérables tant qu'elle n'est pas vidée",
            blockingProcesses: ["UTM"]
        ),
        resolveRoots: Roots.children(of: "Library/Containers/com.utmapp.UTM/Data/Documents") { $0.hasSuffix(".utm") },
        purge: { root, _ in [.moveToTrash(root)] }
    )

    private static let otherAppCaches = DirectoryRule(
        metadata: RuleMetadata(
            id: "apps.caches",
            name: "Autres caches d'apps",
            category: .system,
            risk: .recoverable,
            recoveryNote: "Recréés par chaque app, qui devra parfois retélécharger son contenu",
            isNamedAfterOwner: true
        ),
        resolveRoots: Roots.children(of: "Library/Caches") {
            !$0.hasPrefix(".") && !$0.hasPrefix("com.apple.") && !systemCacheNames.contains($0)
        }
    )

    private static let userLogs = DirectoryRule(
        metadata: RuleMetadata(
            id: "system.logs",
            name: "Journaux utilisateur",
            category: .system,
            risk: .safe,
            recoveryNote: "Recréés au besoin, l'historique de diagnostic est perdu"
        ),
        resolveRoots: Roots.children(of: "Library/Logs") {
            !$0.hasPrefix(".") && !$0.hasPrefix("com.apple.") && $0 != "BobWob" && !systemLogNames.contains($0)
        }
    )
}
