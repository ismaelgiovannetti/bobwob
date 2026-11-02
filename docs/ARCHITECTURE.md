# Architecture de BobWob

BobWob analyse l'espace disque occupé par les artefacts de développement et les fichiers personnels oubliés, puis propose un nettoyage explicite. Le scan ne modifie jamais rien. Chaque suppression passe par un plan que l'utilisateur peut relire.

## Principes

1. **Le scan est sans effet de bord.** Il ne supprime rien et ne lance aucune commande de purge.
2. **Les règles décrivent, l'exécuteur agit.** Une règle produit un plan sous forme de données. Seul `CleanupExecutor` peut toucher au disque.
3. **L'outil propriétaire passe en premier.** `npm cache clean` plutôt que `rm` lorsqu'un outil gère son propre cache.
4. **Aucun privilège en v1.** Pas de root, pas de helper, pas de mot de passe.
5. **Un chiffre n'est jamais présenté comme plus fiable qu'il ne l'est.** Chaque taille indique sa précision.

## Structure du dépôt

Le projet est un package SwiftPM, sans `.xcodeproj`. Un script assemble le bundle `.app`.

```text
Package.swift
Sources/
  BobWobCore/      Moteur sans dépendance à SwiftUI
    Rules/         Une règle par cible
    Scanning/      Parcours du disque, registre des chemins
    Execution/     Plans, garde-fous, journal
    Docker/        Client de l'API par socket Unix
  bobwob/          CLI : scan --json, plan, clean
  BobWobApp/       Interface SwiftUI
Tests/BobWobCoreTests/
scripts/           build-app.sh, build-dmg.sh
.github/workflows/release.yml
```

## Modèle de règles

```swift
public protocol CleanupRule: Sendable {
    var metadata: RuleMetadata { get }
    func detect(in context: ScanContext) async -> Availability
    func scan(in context: ScanContext) -> AsyncThrowingStream<ScanEvent, Error>
    func plan(for selection: [ScanItem], in context: ScanContext) async throws -> CleanupPlan
}

public struct RuleMetadata: Sendable {
    let id: String              // "npm.cache"
    let name: String
    let category: Category      // .packageManagers, .ide, .docker, .personalFiles…
    let risk: RiskLevel
    let recoveryNote: String    // "Retéléchargé au prochain npm install"
    let blockingProcesses: [String]
}

public enum RiskLevel: Sendable {
    case safe          // Régénéré automatiquement, précoché
    case recoverable   // Récupérable avec un coût, décoché
    case dataLoss      // Perte possible, sélection élément par élément
}

public enum SizeEstimate: Sendable {
    case exact(Int64)
    case estimated(Int64)   // Clones APFS, liens durs, récupération différée
    case unknown
}

public enum CleanupAction: Sendable {
    case removeTree(URL)
    case moveToTrash(URL)
    case ownerCommand(executable: URL, arguments: [String])
    case dockerAPI(DockerRequest)
}
```

Ajouter une cible revient à écrire un fichier de règle et à l'enregistrer dans `RuleRegistry`. Les règles restent en Swift : un format déclaratif ne saurait pas exprimer les commandes propriétaires, l'API Docker ou la revue des fichiers personnels.

## Scan asynchrone

```text
ScanCoordinator (actor)
  ├─ TaskGroup, 4 règles en parallèle au maximum
  │    └─ Règle → DiskWalker / client Docker / commande de lecture
  ├─ PathLedger             Attribue chaque chemin à une seule règle, avant le scan
  └─ AsyncStream<ScanEvent> Événements regroupés à 10 Hz au maximum
         └─ ScanStore (@MainActor @Observable) → SwiftUI
```

- **Annulation :** le bouton Stop annule le `TaskGroup`, et `DiskWalker` vérifie l'annulation à chaque lot d'entrées.
- **Taille :** `DiskWalker` compte la taille allouée, jamais la taille apparente, et compte une seule fois les liens durs. `Docker.raw` peut afficher 1 To tout en occupant 1 Go.
- **Double comptage :** la règle la plus spécifique passe en premier. `PathLedger` retire par exemple `~/Library/Caches/pip` de la règle générique sur les caches.
- **Espace non identifié :** l'interface compare l'espace consommé par le volume à la somme mesurée et affiche l'écart comme « non identifié », au lieu de le masquer.
- **Accès refusés :** un dossier illisible apparaît comme « non accessible », jamais comme 0 octet.

À prototyper : `getattrlistbulk` et `ATTR_CMNEXT_PRIVATESIZE` pour estimer l'espace réellement libérable en présence de clones APFS.

## Exécution et garde-fous

`CleanupExecutor` applique ces contrôles avant chaque action :

1. **Chemins :** résolution du chemin réel, refus des liens symboliques et de tout chemin hors des racines déclarées par la règle.
2. **Liste noire :** refus de `/`, `~`, `~/Library`, `~/Documents`, `/System`, `/Applications` et de leurs parents, quelle que soit la règle.
3. **Fraîcheur :** un élément modifié depuis le scan (inode, date de modification) est ignoré et signalé.
4. **Processus actifs :** une cible est bloquée tant que l'un de ses `blockingProcesses` tourne.
5. **Commandes :** exécutable en chemin absolu résolu, arguments fixes, pas de shell.
6. **Journal :** chaque opération est écrite dans `~/Library/Logs/BobWob/`.

Une erreur sur un élément (fichier verrouillé, Docker arrêté) n'interrompt pas les suivants. Le rapport final distingue les réussites, les éléments ignorés et les échecs, avec l'espace libre mesuré avant et après.

## Docker

- **Socket :** résolu depuis le contexte Docker courant, jamais codé en dur.
- **Transport :** HTTP/1.1 sur socket Unix POSIX, sans dépendre de la CLI ni du `PATH`. `NWConnection` a été écarté, car il échouait de façon aléatoire sur ce socket.
- **Lecture :** `GET /system/df`.
- **Purge :** par type de ressource, avec une sélection individuelle pour les volumes, jamais précochés.
- **Docker arrêté :** seule la taille allouée du disque de la VM est affichée, et la règle indique que Docker doit être démarré.
- **Réinitialisation de la VM :** hors de l'app, avec un renvoi vers Docker Desktop.
- **Gain :** toujours `.estimated`, car `Docker.raw` peut ne pas diminuer immédiatement.

## Fichiers personnels

Ces règles sont toujours au niveau `dataLoss`. Rien n'est précoché et la sélection se fait fichier par fichier.

- **Sources :** `~/Downloads` et une recherche de gros fichiers dans le dossier utilisateur, avec un seuil et une ancienneté réglables (500 Mo et 180 jours par défaut).
- **Détection :** parcours du disque, et non Spotlight, dont l'index peut omettre des fichiers.
- **Ancienneté :** `kMDItemLastUsedDate` manque souvent. La date retenue est la plus récente entre le dernier usage connu, l'ajout au dossier et la modification. L'interface affiche « pas d'usage connu depuis… » et indique quand cette date est une simple approximation.
- **Suppression :** déplacement vers la corbeille, jamais de suppression directe. L'interface précise que l'espace n'est libéré qu'une fois la corbeille vidée.
- **Exclusions :**
  - Dossiers synchronisés (`~/Library/CloudStorage`, OneDrive, iCloud Drive), car une suppression locale peut se propager au cloud.
  - Fichiers qui ne sont pas stockés localement.
  - Dépôts Git, bibliothèques Photos et contenu des bundles, un bundle comptant comme un seul élément.
  - `~/Library` et les dossiers déjà couverts par une autre règle.

## Distribution sans compte Apple

Le DMG est signé en ad hoc (`codesign --sign -`), sans notarisation.

- **Premier lancement :** macOS bloque l'app téléchargée. Le README doit expliquer le passage par Réglages > Confidentialité et sécurité > Ouvrir quand même.
- **Accès complet au disque :** une autorisation accordée peut être perdue à chaque nouvelle version, car l'identité ad hoc change avec le binaire.
- **Installation :** pas de cask Homebrew officiel. Un tap personnel reste possible.
- **Helper privilégié :** écarté, car il exige une signature vérifiable.
- **CI :** `release.yml` s'exécute sur un tag, compile un binaire universel, le signe en ad hoc, crée le DMG et l'ajoute à la release GitHub.
