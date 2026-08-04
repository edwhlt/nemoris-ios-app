import Foundation

// MARK: - LoanCalculator
//
// Logique pure et sans état pour calculer le capital restant dû d'un prêt à une
// date donnée, selon son type. Aucune dépendance SQLite — input = `PatrimoineLoan`
// + date d'évaluation, output = `LoanState`. Testable unitairement.
//
// **Formules** (taux mensuel i = annualRate / 12, P = principal, n = durationMonths)
//
//   • AMORT (amortissable à mensualité fixe)
//     M = P · i / (1 − (1+i)^(−n))
//     Capital restant après k mois :
//         CR(k) = P · (1+i)^k − M · ((1+i)^k − 1) / i   (i ≠ 0)
//         CR(k) = P · (1 − k/n)                          (i = 0, prêt 0%)
//
//   • IN_FINE (intérêts seuls jusqu'à l'échéance)
//     M = P · i
//     CR(k) = P si k < n, sinon 0
//
//   • DEFERRED_TOTAL (différé total puis amortissement)
//     Pendant le différé (k < d) : capital capitalisé, pas de paiement
//         CR(k) = P · (1+i)^k
//         M_diff = 0
//     Après le différé (k ≥ d) : amortissement classique sur (n − d) mois
//         P' = P · (1+i)^d
//         M  = P' · i / (1 − (1+i)^(−(n−d)))
//         CR(k) = P' · (1+i)^(k−d) − M · ((1+i)^(k−d) − 1) / i
//
//   • DEFERRED_PARTIAL (intérêts seuls pendant le différé puis amortissement)
//     Pendant le différé (k < d) : seuls les intérêts sont payés
//         CR(k) = P
//         M_diff = P · i
//     Après le différé (k ≥ d) : amortissement classique sur (n − d) mois avec P
//         M  = P · i / (1 − (1+i)^(−(n−d)))
//         CR(k) = P · (1+i)^(k−d) − M · ((1+i)^(k−d) − 1) / i
//
//   • REVOLVING (crédit renouvelable, capital saisi manuellement)
//     CR = principal (l'user met à jour le champ Capital quand il rembourse)
//     M = 0 (pas de mensualité fixe — varie selon utilisation)

/// État calculé d'un prêt à une date donnée. Tous les montants en EUR (cohérent
/// avec le reste de l'app — pas de multidevise en MVP).
struct LoanState: Equatable {
    /// Capital restant dû à la date d'évaluation. Borné à `[0, principal]`.
    let remainingCapital: Double
    /// Mensualité courante (intérêts seuls pendant un différé partiel, mensualité
    /// d'amortissement après, 0 pour un différé total ou un revolving).
    let monthlyPayment: Double
    /// Montant total des intérêts payés depuis le début. Indicatif (peut être 0 si
    /// REVOLVING ou si on est encore dans un différé total).
    let interestsPaid: Double
    /// Montant total du capital remboursé depuis le début (= principal − remainingCapital
    /// pour les types qui amortissent ; 0 pour REVOLVING/IN_FINE en cours).
    let capitalPaid: Double
    /// Nombre de mois écoulés depuis `startDate` (cappé à `durationMonths`).
    let monthsElapsed: Int
    /// `true` si la date d'évaluation est antérieure à `startDate` (prêt pas encore débuté).
    let isPending: Bool
    /// `true` si la durée totale du prêt est dépassée (prêt remboursé en théorie).
    let isCompleted: Bool

    /// Pourcentage du capital remboursé (0…1). Utilisé pour la barre de progression UI.
    var progressRatio: Double {
        guard remainingCapital + capitalPaid > 0 else { return 0 }
        return capitalPaid / (remainingCapital + capitalPaid)
    }
}

enum LoanCalculator {

    /// Calcule l'état du prêt `loan` à la date `asOf` (défaut : maintenant).
    static func compute(loan: PatrimoineLoan, asOf reference: Date = Date()) -> LoanState {
        let calendar = Calendar(identifier: .gregorian)
        // Mois écoulés depuis le début (entier — on ignore la fraction de mois).
        let comps = calendar.dateComponents([.month], from: loan.startDate, to: reference)
        let rawMonths = comps.month ?? 0
        let isPending = rawMonths < 0
        let n = loan.durationMonths
        let d = max(0, loan.deferralMonths)
        let totalDuration = (loan.loanType == .deferredTotal || loan.loanType == .deferredPartial)
            ? n + 0  // n inclut déjà le différé dans nos conventions
            : n
        let monthsElapsed = max(0, min(rawMonths, totalDuration))
        let isCompleted = rawMonths >= totalDuration

        // REVOLVING : pas de math. Capital = principal saisi (l'user le tient à jour).
        if loan.loanType == .revolving {
            return LoanState(
                remainingCapital: loan.principal,
                monthlyPayment: 0,
                interestsPaid: 0,
                capitalPaid: 0,
                monthsElapsed: monthsElapsed,
                isPending: isPending,
                isCompleted: false  // un revolving n'est jamais "fini" par construction
            )
        }

        // Si pas encore débuté → capital plein, pas d'amortissement.
        if isPending {
            let initialMonthly = initialMonthlyPayment(loan: loan)
            return LoanState(
                remainingCapital: loan.principal,
                monthlyPayment: initialMonthly,
                interestsPaid: 0,
                capitalPaid: 0,
                monthsElapsed: 0,
                isPending: true,
                isCompleted: false
            )
        }

        // Si fini → tout remboursé (sauf IN_FINE qui rembourse en bloc à n).
        if isCompleted {
            return LoanState(
                remainingCapital: 0,
                monthlyPayment: 0,
                interestsPaid: totalInterestsAtCompletion(loan: loan),
                capitalPaid: loan.principal,
                monthsElapsed: totalDuration,
                isPending: false,
                isCompleted: true
            )
        }

        let i = loan.annualRate / 12.0
        let k = monthsElapsed
        let P = loan.principal

        switch loan.loanType {

        case .revolving:
            // Déjà traité en début de fonction, le compilateur exige la branche.
            return LoanState(remainingCapital: P, monthlyPayment: 0, interestsPaid: 0,
                             capitalPaid: 0, monthsElapsed: 0, isPending: false, isCompleted: false)

        case .amortizing:
            return amortizingState(P: P, i: i, n: n, k: k)

        case .inFine:
            // Capital constant jusqu'à l'échéance, intérêts seuls payés tous les mois.
            let monthly = P * i
            let interests = monthly * Double(k)
            return LoanState(
                remainingCapital: P,
                monthlyPayment: monthly,
                interestsPaid: interests,
                capitalPaid: 0,
                monthsElapsed: k,
                isPending: false,
                isCompleted: false
            )

        case .deferredTotal:
            // Pendant le différé : capitalisation des intérêts, M = 0.
            // Après : amortissement classique sur (n − d) mois avec un nouveau principal P'.
            if k < d {
                let capitalized = P * pow(1 + i, Double(k))
                return LoanState(
                    remainingCapital: capitalized,
                    monthlyPayment: 0,
                    interestsPaid: capitalized - P,  // intérêts capitalisés mais pas payés
                    capitalPaid: 0,
                    monthsElapsed: k,
                    isPending: false,
                    isCompleted: false
                )
            }
            let pPrime = P * pow(1 + i, Double(d))
            let nPrime = n - d
            return amortizingState(P: pPrime, i: i, n: nPrime, k: k - d, prePaidInterests: pPrime - P)

        case .deferredPartial:
            // Pendant le différé : capital constant, mensualité = intérêts seuls.
            // Après : amortissement classique sur (n − d) mois avec P (inchangé).
            if k < d {
                let monthly = P * i
                return LoanState(
                    remainingCapital: P,
                    monthlyPayment: monthly,
                    interestsPaid: monthly * Double(k),
                    capitalPaid: 0,
                    monthsElapsed: k,
                    isPending: false,
                    isCompleted: false
                )
            }
            let nPrime = n - d
            return amortizingState(
                P: P,
                i: i,
                n: nPrime,
                k: k - d,
                prePaidInterests: P * i * Double(d)
            )
        }
    }

    // MARK: - Helpers privés

    /// Calcule un état d'amortissement classique à mensualité fixe au mois k (sur n mois).
    /// `prePaidInterests` ajoute des intérêts déjà payés ou capitalisés (différé).
    private static func amortizingState(P: Double, i: Double, n: Int, k: Int,
                                        prePaidInterests: Double = 0) -> LoanState {
        guard P > 0, n > 0 else {
            return LoanState(remainingCapital: 0, monthlyPayment: 0, interestsPaid: prePaidInterests,
                             capitalPaid: 0, monthsElapsed: k, isPending: false, isCompleted: true)
        }

        // Cas spécial : taux nul → mensualité = P/n, capital décroît linéairement.
        if i == 0 {
            let monthly = P / Double(n)
            let capitalPaid = monthly * Double(k)
            let remaining = max(0, P - capitalPaid)
            return LoanState(
                remainingCapital: remaining,
                monthlyPayment: monthly,
                interestsPaid: prePaidInterests,
                capitalPaid: capitalPaid,
                monthsElapsed: k,
                isPending: false,
                isCompleted: remaining == 0
            )
        }

        let factor = pow(1 + i, Double(n))
        let monthly = P * i * factor / (factor - 1)

        let growth = pow(1 + i, Double(k))
        // CR(k) = P · (1+i)^k − M · ((1+i)^k − 1) / i
        var remaining = P * growth - monthly * (growth - 1) / i
        if remaining < 0.005 { remaining = 0 }
        if remaining > P { remaining = P }

        let capitalPaid = max(0, P - remaining)
        let totalPaid = monthly * Double(k)
        let interestsThisPhase = max(0, totalPaid - capitalPaid)

        return LoanState(
            remainingCapital: remaining,
            monthlyPayment: monthly,
            interestsPaid: prePaidInterests + interestsThisPhase,
            capitalPaid: capitalPaid,
            monthsElapsed: k,
            isPending: false,
            isCompleted: remaining == 0
        )
    }

    /// Mensualité au démarrage du prêt (mois 1) — utile pour afficher un montant
    /// indicatif dans le form quand on n'a pas encore d'historique.
    /// (Le `deferralMonths` n'est lu nulle part ici : pour DEFERRED_TOTAL la
    /// mensualité initiale est 0 par construction, et pour DEFERRED_PARTIAL on
    /// renvoie les intérêts seuls sur P inchangé — pas besoin du nb de mois.)
    private static func initialMonthlyPayment(loan: PatrimoineLoan) -> Double {
        let i = loan.annualRate / 12.0
        let n = loan.durationMonths
        let P = loan.principal
        switch loan.loanType {
        case .revolving:
            return 0
        case .amortizing:
            return classicMonthly(P: P, i: i, n: n)
        case .inFine:
            return P * i
        case .deferredTotal:
            // Mois 1 : pas de paiement (on est dans le différé).
            return 0
        case .deferredPartial:
            return P * i  // intérêts seuls
        }
    }

    private static func classicMonthly(P: Double, i: Double, n: Int) -> Double {
        guard P > 0, n > 0 else { return 0 }
        if i == 0 { return P / Double(n) }
        let factor = pow(1 + i, Double(n))
        return P * i * factor / (factor - 1)
    }

    /// Intérêts totaux payés sur toute la durée — utilisé quand le prêt est terminé
    /// pour afficher un total cohérent au lieu de 0.
    private static func totalInterestsAtCompletion(loan: PatrimoineLoan) -> Double {
        let i = loan.annualRate / 12.0
        let n = loan.durationMonths
        let d = max(0, loan.deferralMonths)
        let P = loan.principal
        switch loan.loanType {
        case .revolving:
            return 0
        case .amortizing:
            let M = classicMonthly(P: P, i: i, n: n)
            return max(0, M * Double(n) - P)
        case .inFine:
            return P * i * Double(n)
        case .deferredTotal:
            let pPrime = P * pow(1 + i, Double(d))
            let M = classicMonthly(P: pPrime, i: i, n: n - d)
            // Intérêts = intérêts capitalisés pendant le différé + intérêts payés ensuite
            return (pPrime - P) + max(0, M * Double(n - d) - pPrime)
        case .deferredPartial:
            let M = classicMonthly(P: P, i: i, n: n - d)
            return P * i * Double(d) + max(0, M * Double(n - d) - P)
        }
    }
}
