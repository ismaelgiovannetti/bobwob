# BobWob

BobWob est une app macOS qui repère ce qui encombre le disque d'un développeur et le nettoie sans suppression silencieuse. Le scan ne modifie rien, et chaque nettoyage passe par un aperçu.

L'interface est en français. BobWob ne demande aucun mot de passe et n'a pas besoin de droits administrateur.

## Ce que BobWob analyse

| Niveau | Cibles | Précoché |
|---|---|---|
| **Sûr** | Caches npm, pip, Homebrew, VS Code et JetBrains, mises à jour d'apps en cache, journaux utilisateur | Oui |
| **Récupérable** | Paquets NuGet et Conda, navigateurs Playwright, images et cache de build Docker, autres caches d'apps | Non |
| **Perte possible** | Conteneurs Docker arrêtés, volumes Docker non rattachés, émulateurs Android, anciens téléchargements, gros fichiers peu utilisés | Non, sélection élément par élément |

BobWob affiche aussi la taille de `Docker.raw`, sans jamais le supprimer. Pour réinitialiser la VM, passe par Docker Desktop.

Il n'analyse pas encore Xcode, les simulateurs, Cargo, Go, CocoaPods, pnpm, les snapshots Time Machine ni les `node_modules` de tes projets.

## Installation

BobWob demande macOS 14 ou plus récent, sur Apple Silicon ou Intel.

1. Télécharge le fichier `.dmg` depuis la page [Releases](../../releases).
2. Ouvre-le et glisse BobWob dans Applications.
3. Lance BobWob. macOS va le bloquer, car l'app n'est pas notarisée par Apple.
4. Ouvre Réglages Système > Confidentialité et sécurité, puis clique sur **Ouvrir quand même**.

Sans notarisation, il n'y a ni garantie d'Apple sur le binaire, ni cask Homebrew officiel. Tu peux aussi compiler l'app toi-même depuis les sources.

### Autorisations

macOS peut demander l'accès à tes dossiers pendant le scan. Si le scan semble bloqué, cherche une fenêtre d'autorisation ouverte. Comme l'app est signée en ad hoc, ces demandes peuvent revenir à chaque nouvelle version.

## Ce qui protège tes fichiers

- **Aperçu :** chaque nettoyage affiche d'abord ce qui sera exécuté et ce qui sera ignoré.
- **Zones interdites :** BobWob refuse tout chemin hors de ton dossier utilisateur, tes dossiers standards, `.ssh`, les trousseaux, les dossiers synchronisés et les liens symboliques.
- **Fichiers personnels :** ils vont à la corbeille. L'espace n'est libéré qu'une fois celle-ci vidée.
- **Perte de données :** ces éléments demandent une confirmation explicite.
- **Changements récents :** un élément modifié depuis le scan est ignoré, tout comme le cache d'une app détectée comme ouverte.
- **Journal :** chaque action est écrite dans `~/Library/Logs/BobWob/cleanup.log` avant d'être lancée.

### Limites

- Les suppressions de caches sont directes et ne passent pas par la corbeille.
- La liste des caches système à exclure ne peut pas être complète. Relis les « Autres caches d'apps » avant de les cocher.
- Un dossier de cache qui ne porte pas le nom de son app ne permet pas toujours de détecter qu'elle est ouverte.
- La date de dernière utilisation d'un fichier est souvent absente. L'app l'indique alors comme une approximation.
- Les gains sont parfois des estimations, à cause des clones APFS, des liens durs et du disque de la VM Docker.

## Ligne de commande

Depuis les sources, compile d'abord la CLI :

```bash
swift build -c release --product bobwob
```

Analyse le disque, sans rien modifier :

```bash
.build/release/bobwob scan
```

Affiche ce que ferait un nettoyage :

```bash
.build/release/bobwob clean --rule homebrew.cache
```

Ajoute `--yes` pour l'exécuter. `bobwob scan --json` produit un rapport complet et `bobwob rules` liste les règles.

## Développement

Les Command Line Tools suffisent pour un build Apple Silicon local. Le binaire universel demande Xcode.

Lance les tests :

```bash
swift test
```

Crée `dist/BobWob.app` :

```bash
scripts/build-app.sh
```

Crée le DMG et sa somme SHA-256 :

```bash
scripts/build-dmg.sh
```

Chaque pull request et chaque push sur `main` lancent [ci.yml](.github/workflows/ci.yml), qui exécute les tests et compile le DMG universel. Pousser un tag `v1.2.3` lance [release.yml](.github/workflows/release.yml), qui publie ce DMG dans une release GitHub.

L'organisation du code et le modèle de règles sont décrits dans [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Licence

[MIT](LICENSE)
