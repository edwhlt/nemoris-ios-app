import Foundation

// MARK: - DashboardCardID
//
// Registre des cartes du Dashboard. C'est une **énumération de données pure** (aucun
// import SwiftUI) : elle décrit ce qu'est une carte, pas comment elle se dessine.
// Le rendu se fait par un `switch` unique dans `DashboardCardHost`, comme le fait
// déjà `MainTabView.tabView(for:)` pour les modules.
//
// **Pourquoi pas un protocole + registre type-erasé** : stocker des closures qui
// retournent des `View` obligerait à isoler le registre sur `@MainActor` (une vue
// n'est pas `Sendable`), et on perdrait la conformance `Sendable` gratuite dont on a
// besoin pour que `dependencies` traverse la frontière du `Task.detached` du builder.
//
// **Ajouter une carte** = un `case` ici + une ligne dans le `switch` de
// `DashboardCardHost` + une vue de contenu. Rien d'autre : l'ordre par défaut, la
// persistance et l'écran de personnalisation suivent automatiquement.

enum DashboardCardSize: String, Codable, Sendable, CaseIterable {
    case compact
    case wide

    var label: String {
        switch self {
        case .compact: return "Compacte"
        case .wide:    return "Large"
        }
    }

    var systemImage: String {
        switch self {
        case .compact: return "rectangle.split.2x1"
        case .wide:    return "rectangle"
        }
    }
}

enum DashboardCardID: String, CaseIterable, Identifiable, Sendable, Codable {
    // ⚠️ L'ORDRE DE DÉCLARATION EST L'ORDRE PAR DÉFAUT DE LA GRILLE.
    // `DashboardLayoutStore.sanitize` ajoute toute carte inconnue en fin de liste,
    // donc une carte ajoutée plus tard n'ira PAS se glisser au milieu de la mise en
    // page déjà personnalisée par l'utilisateur.
    case insightsCoach
    case budgetEnvelopes
    case netWorth
    case monthlyFlow
    case topCategories
    case tags
    case investments

    var id: String { rawValue }

    var title: String {
        switch self {
        case .insightsCoach:   return "Coach financier"
        case .budgetEnvelopes: return "Enveloppes"
        case .netWorth:        return "Patrimoine net"
        case .monthlyFlow:     return "Flux mensuel"
        case .topCategories:   return "Top dépenses"
        case .tags:            return "Tags"
        case .investments:     return "Investissements"
        }
    }

    var systemImage: String {
        switch self {
        case .insightsCoach:   return "lightbulb.fill"
        case .budgetEnvelopes: return "chart.bar.fill"
        case .netWorth:        return "house.lodge.fill"
        case .monthlyFlow:     return "chart.bar.xaxis"
        case .topCategories:   return "list.number"
        case .tags:            return "tag.fill"
        case .investments:     return "chart.line.uptrend.xyaxis"
        }
    }

    /// Module dont la carte dépend. Si l'utilisateur l'a désactivé dans les Réglages,
    /// la carte disparaît de la grille (mais sa préférence est conservée : la
    /// réactivation restitue sa position et sa taille).
    ///
    /// Volontairement **pas** de gating paywall en plus : dans cette app, c'est le
    /// toggle module des Réglages qui porte l'entitlement, et les vues sensibles ont
    /// déjà leur propre `paywallOverlay`. Ajouter une seconde barrière ici masquerait
    /// des chiffres que l'utilisateur voit déjà dans le bandeau « Vue d'ensemble ».
    var requiredModule: MainTabItem? {
        switch self {
        case .budgetEnvelopes: return .budget
        case .netWorth:        return .patrimoine
        case .investments:     return .investments
        default:               return nil
        }
    }

    /// Un graphe à 12 barres ou une liste d'insights sur une demi-largeur d'iPhone
    /// (~170 pt) est illisible : ces cartes n'existent qu'en large.
    var supportedSizes: [DashboardCardSize] {
        switch self {
        case .insightsCoach, .monthlyFlow: return [.wide]
        default:                           return [.compact, .wide]
        }
    }

    var defaultSize: DashboardCardSize {
        switch self {
        case .budgetEnvelopes, .netWorth, .investments: return .compact
        default:                                        return .wide
        }
    }

    /// Une carte de niche part masquée : sinon chaque nouvelle version ajouterait du
    /// bruit chez tout le monde. `investments` est déjà résumé dans le bandeau fixe.
    var isVisibleByDefault: Bool {
        self != .investments
    }

    /// Les agrégats nécessaires au rendu de cette carte. C'est ce qui rend une carte
    /// masquée réellement gratuite : ses agrégats ne sont pas calculés.
    var dependencies: Set<DashboardAggregate> {
        switch self {
        case .insightsCoach:   return [.insights]
        case .budgetEnvelopes: return [.budgetEnvelopes]
        case .netWorth:        return [.patrimoine]
        case .monthlyFlow:     return [.yearSeries]
        case .topCategories:   return [.categoryBreakdown]
        case .tags:            return [.tagBreakdown]
        case .investments:     return [.investments]
        }
    }
}

// MARK: - DashboardCardPreference

/// Préférence utilisateur pour une carte. Encodée en JSON dans `UserDefaults`.
struct DashboardCardPreference: Codable, Hashable, Sendable, Identifiable {
    var card: DashboardCardID
    var isVisible: Bool
    var size: DashboardCardSize

    var id: DashboardCardID { card }

    init(card: DashboardCardID, isVisible: Bool, size: DashboardCardSize) {
        self.card = card
        self.isVisible = isVisible
        self.size = size
    }

    /// Réglage par défaut d'une carte, tel que défini par le registre.
    init(defaultsFor card: DashboardCardID) {
        self.init(card: card, isVisible: card.isVisibleByDefault, size: card.defaultSize)
    }
}
