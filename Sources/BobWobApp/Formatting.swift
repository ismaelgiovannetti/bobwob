import BobWobCore
import SwiftUI

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func size(_ size: SizeEstimate) -> String {
        switch size {
        case .exact(let value): bytes(value)
        case .estimated(let value): "≈ " + bytes(value)
        case .unknown: "Inconnu"
        }
    }

    static func sizeHelp(_ size: SizeEstimate) -> String {
        switch size {
        case .exact: "Espace occupé mesuré sur le disque"
        case .estimated: "Estimation : l'espace réellement libéré peut être différent"
        case .unknown: "Taille non disponible"
        }
    }
}

extension RiskLevel {
    var title: String {
        switch self {
        case .safe: "Sûr"
        case .recoverable: "Récupérable"
        case .dataLoss: "Perte possible"
        }
    }

    var explanation: String {
        switch self {
        case .safe: "Régénéré automatiquement"
        case .recoverable: "À retélécharger ou reconstruire"
        case .dataLoss: "À choisir élément par élément"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.shield"
        case .recoverable: "arrow.clockwise"
        case .dataLoss: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .safe: .green
        case .recoverable: .orange
        case .dataLoss: .red
        }
    }
}
