import Foundation
import CoreGraphics

// MARK: - TransactionDensity
//
// Réglage utilisateur de la densité d'affichage des rows Transactions.
// 3 paliers pour s'adapter aux préférences (compact pour voir plus d'items à
// l'écran, confortable pour réduire la fatigue visuelle).
//
// **Valeurs appliquées** :
//   - logo : taille du MerchantLogo (50% / 100% / 130% de la baseline 52pt)
//   - verticalPadding : padding `.vertical(_:)` du row
//   - rowMinHeight : hauteur minimale du row (= taille du logo, pour le centrage)
//   - showLogo : compact masque le logo pour gagner ~36pt
//   - showSecondaryInfo : compact masque le sous-titre (info user/cat) pour
//     condenser à 1 ligne

enum TransactionDensity: String, CaseIterable, Identifiable {
    case compact
    case normal
    case comfortable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact:     return "Compact"
        case .normal:      return "Normal"
        case .comfortable: return "Confortable"
        }
    }

    var systemIcon: String {
        switch self {
        case .compact:     return "list.bullet"
        case .normal:      return "rectangle.grid.1x2"
        case .comfortable: return "square.grid.2x2"
        }
    }

    var description: String {
        switch self {
        case .compact:     return "Plus d'items à l'écran. Logo masqué."
        case .normal:      return "Équilibre par défaut."
        case .comfortable: return "Espacé pour confort de lecture."
        }
    }

    /// Taille du logo en points. 0 quand le logo n'est pas affiché.
    var logoSize: CGFloat {
        switch self {
        case .compact:     return 0   // pas de logo
        case .normal:      return 52  // baseline
        case .comfortable: return 64
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact:     return 1
        case .normal:      return 3
        case .comfortable: return 6
        }
    }

    /// Hauteur minimale du row (utilisée pour le centrage vertical par
    /// rapport au logo). En compact on laisse SwiftUI calculer.
    var rowMinHeight: CGFloat {
        switch self {
        case .compact:     return 28
        case .normal:      return 52
        case .comfortable: return 64
        }
    }

    var showLogo: Bool { self != .compact }

    /// En compact on supprime la 2e ligne (info user + balance courante) pour
    /// avoir un row strictement à 1 ligne dense. l'utilisateur peut tap pour voir
    /// les détails.
    var showSecondaryInfo: Bool { self != .compact }
}
