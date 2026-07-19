import Foundation

// MARK: - Patrimoine — Modèles du module Net Worth
//
// 3 entités métier indépendantes (real estate, loans, assets) + leurs enums
// associés. Persistées via la migration v37 (cf. DatabaseManager).
//
// Convention : tous les `id` sont des Int (SQLite AUTOINCREMENT). Toutes les
// dates en SQL stockées au format yyyy-MM-dd.

// MARK: - Kinds (énumérations associées)

/// Famille fonctionnelle d'un asset "Mobilier & Liquidités". Pas une contrainte
/// stricte côté SQL — un asset CASH avec un compte courant lié reste valide.
/// Sert surtout au tri et à l'icône par défaut dans l'UI.
enum AssetKind: String, CaseIterable {
    case cash       = "CASH"       // Espèces, trésorerie courante
    case savings    = "SAVINGS"    // Livret A, LDDS, LEP, PEL, CEL…
    case investment = "INVESTMENT" // PEA, CTO, Assurance Vie, crypto
    case other      = "OTHER"

    var label: String {
        switch self {
        case .cash:       return "Liquidités"
        case .savings:    return "Épargne"
        case .investment: return "Investissements"
        case .other:      return "Autre"
        }
    }

    var systemIcon: String {
        switch self {
        case .cash:       return "banknote.fill"
        case .savings:    return "building.columns.fill"
        case .investment: return "chart.line.uptrend.xyaxis"
        case .other:      return "circle.grid.2x2.fill"
        }
    }
}

/// Type de prêt — discrimine la formule de calcul du capital restant dû.
/// La logique vit dans `LoanCalculator` (étape 4 de l'implémentation).
enum LoanType: String, CaseIterable {
    case amortizing      = "AMORT"             // Mensualité fixe, amortissement progressif
    case inFine          = "IN_FINE"           // Capital remboursé en bloc à l'échéance
    case deferredTotal   = "DEFERRED_TOTAL"    // Différé total puis amortissement
    case deferredPartial = "DEFERRED_PARTIAL"  // Différé partiel (intérêts seuls) puis amortissement
    case revolving       = "REVOLVING"         // Crédit renouvelable, capital restant saisi manuellement

    var label: String {
        switch self {
        case .amortizing:      return "Amortissable"
        case .inFine:          return "In fine"
        case .deferredTotal:   return "Différé total"
        case .deferredPartial: return "Différé partiel"
        case .revolving:       return "Renouvelable"
        }
    }

    /// Affiché en aide à la création — explique en 1 phrase ce que ce type implique.
    var explanation: String {
        switch self {
        case .amortizing:
            return "Prêt classique. Mensualité fixe, le capital diminue chaque mois."
        case .inFine:
            return "Seuls les intérêts sont payés mensuellement. Le capital est remboursé en une fois à l'échéance."
        case .deferredTotal:
            return "Aucun paiement pendant la période de différé (les intérêts sont capitalisés), puis amortissement classique."
        case .deferredPartial:
            return "Seuls les intérêts sont payés pendant le différé, puis amortissement classique."
        case .revolving:
            return "Crédit renouvelable (réserve d'argent). Le capital restant dû est saisi manuellement."
        }
    }
}

// MARK: - Real estate (bien immobilier)

struct PatrimoineRealEstate: Identifiable, Hashable {
    let id: Int
    var name: String
    var purchasePrice: Double
    var purchaseDate: Date
    var currentValue: Double
    /// Date de la dernière estimation manuelle. Nil = jamais réestimé depuis l'achat.
    var estimatedAt: Date?
    var address: String?
    var notes: String?
    let createdAt: Date

    /// Plus-value brute estimée (sans frais notaire ni rénovation). C'est une
    /// estimation user, pas un calcul fiscal.
    var capitalGain: Double { currentValue - purchasePrice }

    var capitalGainPercent: Double {
        guard purchasePrice > 0 else { return 0 }
        return (currentValue - purchasePrice) / purchasePrice * 100
    }
}

// MARK: - Loan (prêt / dette)

struct PatrimoineLoan: Identifiable, Hashable {
    let id: Int
    var name: String
    var loanType: LoanType
    var principal: Double        // Capital emprunté initial
    var annualRate: Double       // Taux annuel nominal (ex 0.034 = 3.4%)
    var durationMonths: Int      // Durée totale en mois
    var deferralMonths: Int      // Mois de différé (0 si type ≠ DEFERRED_*)
    var startDate: Date
    /// Assurance emprunteur mensuelle (en EUR). Charge séparée de la mensualité
    /// d'amortissement — n'affecte PAS le capital restant dû ni le calcul des
    /// intérêts. Affichée dans le form + sommée dans le coût mensuel total.
    /// 0 si pas d'assurance ou si l'user ne la suit pas séparément.
    var insuranceMonthly: Double
    /// Lien optionnel vers un bien immobilier (typiquement le prêt finance ce bien).
    /// ON DELETE SET NULL côté SQL — la suppression du bien ne supprime pas le prêt.
    var linkedRealEstateId: Int?
    var notes: String?
    let createdAt: Date

    /// Coût d'assurance cumulé sur toute la durée du prêt (charges totales).
    /// Indicatif pour le form — visualise combien l'assurance "coûtera" au total.
    var totalInsuranceCost: Double { insuranceMonthly * Double(durationMonths) }
}

// MARK: - Asset (élément "Mobilier & Liquidités")

struct PatrimoineAsset: Identifiable, Hashable {
    let id: Int
    var name: String
    var assetKind: AssetKind

    // Linking soft — au plus 1 des 2 colonnes est non-nil (garanti par UNIQUE INDEX
    // partiels côté SQL : un compte ne peut être lié qu'à 1 asset Patrimoine).
    var linkedAccountId: Int?            // Lien vers accounts.id (livret, courant, épargne)
    var linkedInvestmentAccountId: Int?  // Lien vers investment_accounts.id (PEA, CTO, etc.)

    /// Valeur saisie manuellement par l'user. Utilisée UNIQUEMENT si aucun link n'est défini.
    var manualValue: Double

    /// Dernier snapshot de la valeur résolue (lu depuis le compte lié ou copié de
    /// manualValue). Conservé même si le lien est rompu — sert de fallback offline
    /// et de mémoire si l'user supprime son compte source.
    var lastKnownValue: Double

    var notes: String?
    let createdAt: Date

    /// Vrai si l'asset est rattaché à un compte source (Account ou InvestmentAccount).
    /// Quand `true` la valeur affichée est résolue dynamiquement ; l'édition manuelle
    /// du champ valeur est désactivée côté UI.
    var isLinked: Bool {
        linkedAccountId != nil || linkedInvestmentAccountId != nil
    }
}

// MARK: - Snapshot agrégé (utilisé par le hero patrimoine global)

/// Vue d'ensemble du patrimoine total à un instant T. Calculé en mémoire par le
/// ViewModel à partir des 3 collections (assets résolus + immo + prêts).
/// Pas persisté (pour l'instant — les snapshots historiques sont hors scope MVP).
struct PatrimoineSnapshot {
    let totalAssets: Double        // Σ assets résolus + Σ real estate currentValue
    let totalLiabilities: Double   // Σ loans capital restant dû
    let assetsCount: Int
    let realEstateCount: Int
    let loansCount: Int

    var netWorth: Double { totalAssets - totalLiabilities }

    static let empty = PatrimoineSnapshot(
        totalAssets: 0,
        totalLiabilities: 0,
        assetsCount: 0,
        realEstateCount: 0,
        loansCount: 0
    )
}
