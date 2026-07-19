import Foundation

// MARK: - ProjectionEngine
//
// Moteur pur (sans état) qui projette le patrimoine net mois par mois sur N mois
// (60 par défaut = 5 ans). Réutilise `LoanCalculator` pour l'amortissement et
// `PatrimoineSnapshot` comme point de départ.
//
// **Inputs** :
//   - `snapshot` : situation patrimoine actuelle (totalAssets, totalLiabilities)
//   - `totalAssetsLiquid` : valeur courante des assets liquides (mobilier &
//     liquidités) — c'est CE qui croît avec le cash flow et le rendement
//   - `realEstateValue` : valeur courante de l'immobilier (gardée constante en
//     MVP, on n'extrapole pas la plus-value immobilière)
//   - `loans` : liste des prêts à projeter (chaque mois on appelle LoanCalculator
//     à la date projetée pour avoir le capital restant exact)
//   - `netMonthlyCashFlow` : Σ revenus récurrents − Σ dépenses récurrentes ramené
//     à un montant mensuel (cf. ProjectionInputs.cashFlowFromBudget)
//   - `scenario` : ajuste cashFlow, growth, et accélération de remboursement
//
// **Hypothèses MVP assumées** :
//   - L'immobilier ne bouge pas (pas de plus-value extrapolée — trop incertain)
//   - Les assets liquides croissent uniformément au taux du scenario (2-5%/an)
//   - L'accélération du remboursement (scenario `accelerated`) est modélisée
//     comme un % de réduction supplémentaire du capital restant chaque mois
//     (approximation — pas de simulation d'amortissement avec VR exact)
//   - Pas de nouveaux prêts/assets créés en cours de route
//   - Pas d'inflation (le netWorth projeté est en € constants)

/// Point d'évolution du patrimoine net à une date donnée.
struct ProjectionPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let netWorth: Double
    let totalAssets: Double       // liquide + immobilier
    let totalLiabilities: Double  // Σ capitaux restants
}

/// Scenario de projection — ajuste 3 leviers : cashFlowMultiplier, annualGrowthRate,
/// et debtAcceleration (réduction additionnelle du capital restant des prêts).
enum ProjectionScenario: String, CaseIterable, Identifiable {
    case conservative   // Statu quo. Flux courant, rendement prudent, pas d'accélération.
    case optimistic     // +20 % d'épargne, rendement plus ambitieux.
    case accelerated    // Flux courant + remboursement accéléré des prêts (~30 %).

    var id: String { rawValue }

    var label: String {
        switch self {
        case .conservative: return "Statu quo"
        case .optimistic:   return "Épargne renforcée"
        case .accelerated:  return "Remboursement accéléré"
        }
    }

    var systemIcon: String {
        switch self {
        case .conservative: return "line.diagonal"
        case .optimistic:   return "arrow.up.right.circle.fill"
        case .accelerated:  return "bolt.fill"
        }
    }

    var description: String {
        switch self {
        case .conservative:
            return "Vos flux et rendements actuels prolongés tels quels."
        case .optimistic:
            return "+20 % d'épargne mensuelle et un rendement annuel de 5 %."
        case .accelerated:
            return "Vos prêts sont remboursés ~30 % plus vite (versements complémentaires)."
        }
    }

    /// Coefficient appliqué au `netMonthlyCashFlow`. >1 augmente l'épargne.
    var cashFlowMultiplier: Double {
        switch self {
        case .conservative: return 1.0
        case .optimistic:   return 1.2
        case .accelerated:  return 1.0
        }
    }

    /// Rendement annuel des assets liquides (en décimal). 0.02 = 2 %/an.
    var annualGrowthRate: Double {
        switch self {
        case .conservative: return 0.02
        case .optimistic:   return 0.05
        case .accelerated:  return 0.03
        }
    }

    /// Coefficient appliqué au capital restant des prêts CHAQUE MOIS pour modéliser
    /// un remboursement anticipé. 0.0 = aucun. 0.003 ≈ -30 % d'horizon de prêt
    /// (ordre de grandeur, approximation).
    var debtAccelerationPerMonth: Double {
        switch self {
        case .accelerated: return 0.003
        default:           return 0.0
        }
    }
}

enum ProjectionEngine {

    /// Projette le patrimoine net mois par mois pendant `months` mois.
    /// Le premier point (index 0) correspond à **aujourd'hui** (snapshot tel quel).
    static func project(
        snapshot: PatrimoineSnapshot,
        totalAssetsLiquid: Double,
        realEstateValue: Double,
        loans: [PatrimoineLoan],
        netMonthlyCashFlow: Double,
        scenario: ProjectionScenario,
        months: Int = 60,
        startDate: Date = Date()
    ) -> [ProjectionPoint] {

        let monthlyGrowthFactor = pow(1 + scenario.annualGrowthRate, 1.0 / 12.0)
        let adjustedCashFlow = netMonthlyCashFlow * scenario.cashFlowMultiplier
        let debtAccelFactor = 1.0 - scenario.debtAccelerationPerMonth  // <1 = on retire X% supp / mois

        var points: [ProjectionPoint] = []
        let cal = Calendar(identifier: .gregorian)

        // Capital liquide qui évolue mois par mois.
        var currentLiquid = totalAssetsLiquid
        // Capital "supplémentaire" remboursé via l'accélération (cumulé). On le
        // soustrait du capital restant via le LoanCalculator pour avoir un effet
        // visible sur la courbe de dette.
        var cumulativeExtraDebtPaid: Double = 0

        for monthOffset in 0...months {
            let date = cal.date(byAdding: .month, value: monthOffset, to: startDate) ?? startDate

            // 1) Cash flow + croissance des assets liquides.
            // PAS de bornage à 0 : on laisse `currentLiquid` aller en territoire
            // négatif si le cashFlow l'exige. C'est plus honnête — ça matérialise
            // le découvert continu que l'user aurait si rien ne change. Pour la
            // croissance, on n'applique pas le facteur quand on est négatif
            // (un découvert ne "rend" pas — au contraire les agios coûtent, mais
            // on n'a pas la modélisation pour ça en MVP, on reste neutre).
            if monthOffset > 0 {
                currentLiquid += adjustedCashFlow
                if currentLiquid > 0 {
                    currentLiquid *= monthlyGrowthFactor
                }
            }

            // 2) Dette projetée à cette date — somme des capitaux restants
            //    selon LoanCalculator à `date`. On applique en plus un effet
            //    cumulatif d'accélération sur le total.
            let projectedLiabilitiesRaw = loans.reduce(0.0) { acc, loan in
                let state = LoanCalculator.compute(loan: loan, asOf: date)
                return acc + state.remainingCapital
            }
            // Accélération : on retire la part déjà "remboursée en plus" cumulée.
            // Compose multiplicativement chaque mois via debtAccelFactor.
            if monthOffset > 0 {
                // À chaque mois, on ajoute une "tranche supp" proportionnelle au
                // capital restant courant. Donc cumulativeExtraDebtPaid croît
                // mais est borné par la dette restante.
                let extraThisMonth = max(0, projectedLiabilitiesRaw - cumulativeExtraDebtPaid)
                                     * scenario.debtAccelerationPerMonth
                cumulativeExtraDebtPaid += extraThisMonth
            }
            let projectedLiabilities = max(0, projectedLiabilitiesRaw - cumulativeExtraDebtPaid)
            _ = debtAccelFactor  // gardé pour la lisibilité du raisonnement

            // 3) Compose le snapshot
            let totalAssets = currentLiquid + realEstateValue
            let netWorth = totalAssets - projectedLiabilities

            points.append(ProjectionPoint(
                date: date,
                netWorth: netWorth,
                totalAssets: totalAssets,
                totalLiabilities: projectedLiabilities
            ))
        }

        return points
    }
}

// MARK: - ProjectionInputs helper (récupération du cash flow depuis Budget)

enum ProjectionInputs {

    /// Calcule le cash flow mensuel net (Σ revenus − Σ dépenses) à partir des
    /// récurrents Budget actifs. Convertit chaque pattern en équivalent mensuel
    /// selon sa fréquence (weekly ×4.33, monthly ×1, quarterly ÷3, yearly ÷12).
    ///
    /// Renvoie 0 si Budget pas activé / pas de récurrents — la projection sera
    /// alors une simple courbe de la dette sans croissance des assets.
    static func netMonthlyCashFlowFromBudget() -> Double {
        // 1. Récurrents (loyer, salaire, abonnements) — déjà signés.
        let patterns = BudgetRepository.shared.fetchActivePatterns()
        let recurringNet = patterns.reduce(0.0) { acc, p in
            acc + monthlyEquivalent(amount: p.amountAvg, frequency: p.frequency)
        }
        // 2. Enveloppes — comptent comme des dépenses prévues. On les
        //    additionne EN NÉGATIF au cashFlow. Si une catégorie est
        //    couverte à la fois par un récurrent (montant fixe) ET une
        //    enveloppe (budget variable), on évite le double comptage en
        //    soustrayant uniquement le delta : env.amount - récurrent_de_cette_cat.
        //
        //    Stratégie pragmatique MVP : on ne soustrait que les enveloppes
        //    dont la catégorie n'a PAS de récurrent — les autres sont déjà
        //    couvertes par recurringNet. Précision suffisante pour la projection.
        let envelopes = BudgetRepository.shared.fetchEnvelopes().filter { $0.isActive }
        let recurringCategoryIds = Set(patterns.compactMap { $0.categoryId })
        let envelopesNet = envelopes
            .filter { env in
                guard let cid = env.categoryId else { return true }
                return !recurringCategoryIds.contains(cid)
            }
            .reduce(0.0) { acc, env in
                // env.amount toujours positif (= budget alloué). On soustrait
                // pour compter comme une dépense mensuelle estimée.
                acc - envelopeMonthlyEquivalent(amount: env.amount, period: env.period)
            }
        return recurringNet + envelopesNet
    }

    private static func envelopeMonthlyEquivalent(amount: Double, period: BudgetPeriod) -> Double {
        switch period {
        case .monthly: return amount
        case .yearly:  return amount / 12.0
        }
    }

    private static func monthlyEquivalent(amount: Double, frequency: RecurrenceFrequency) -> Double {
        switch frequency {
        case .daily:   return amount * 30.42  // 365.25 / 12
        case .weekly:  return amount * 4.33   // 52 / 12
        case .monthly: return amount
        case .yearly:  return amount / 12.0
        }
    }
}
