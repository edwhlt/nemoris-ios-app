import Foundation
import CoreGraphics

// MARK: - TransactionDensity
//
// User setting for the display density of Transaction rows.
// 3 levels to adapt to preferences (compact to see more items on screen,
// comfortable to reduce visual fatigue).
//
// **Applied values**:
//   - logo: MerchantLogo size (24pt / 100% / 130% of the 52pt baseline —
//     compact keeps a small icon rather than dropping it, cf. `logoSize`)
//   - verticalPadding: row `.vertical(_:)` padding
//   - rowMinHeight: minimum row height (= logo size, for centering)
//   - showLogo: always true — even compact keeps the merchant icon, just
//     shrunk (an icon remains the fastest visual anchor for scanning
//     a dense list, more useful than the space saved)
//   - showSecondaryInfo: compact hides the subtitle (user/category info) to
//     condense to a single line

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
        case .compact:     return "Plus d'items à l'écran. Logo réduit."
        case .normal:      return "Équilibre par défaut."
        case .comfortable: return "Espacé pour confort de lecture."
        }
    }

    /// Logo size in points. Compact keeps a small icon instead of dropping it.
    var logoSize: CGFloat {
        switch self {
        case .compact:     return 24  // small, still fits the 28pt row
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

    /// Minimum row height (used for vertical centering relative to the
    /// logo). In compact, SwiftUI is left to compute it.
    var rowMinHeight: CGFloat {
        switch self {
        case .compact:     return 28
        case .normal:      return 52
        case .comfortable: return 64
        }
    }

    var showLogo: Bool { true }

    /// In compact, the 2nd line (user info + running balance) is removed to
    /// get a strictly single-line dense row. The user can tap to see the
    /// details.
    var showSecondaryInfo: Bool { self != .compact }
}
