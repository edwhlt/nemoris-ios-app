import Foundation

// MARK: - InvestmentsRecap
//
// Mini-récap du patrimoine financier, pour le bandeau "Vue d'ensemble" du Dashboard.
// On ne stocke PAS l'historique mensuel ici — la sparkline reste en option (calcul
// coûteux on-the-fly côté Investments) ; ici on vise zéro overhead.
//
// ⚠️ Vivait dans `AnnualDashboardViewModel`, déplacé dans le module Investissements :
// c'est lui le propriétaire de la règle "un compte actif = valorisation OU cash > 0",
// et le Dashboard n'a pas à la redéfinir.
//
// ⚠️ Se construit **uniquement** depuis `InvestmentRepository.fetchAccounts()`, qui
// fait le calcul en UN SELECT avec CTE. Ne jamais passer par `InvestmentsViewModel`
// pour ça : son `load()` déclenche une requête par compte, l'historique de prix de
// chaque position et les sparklines.

struct InvestmentsRecap {
    let totalCurrentValue: Double
    let totalInvested: Double
    let activeAccountCount: Int

    var pnlAbsolute: Double { totalCurrentValue - totalInvested }
    var pnlPercent: Double {
        guard totalInvested > 0 else { return 0 }
        return (totalCurrentValue - totalInvested) / totalInvested * 100
    }
    var hasData: Bool { activeAccountCount > 0 }

    static let empty = InvestmentsRecap(totalCurrentValue: 0, totalInvested: 0, activeAccountCount: 0)

    /// Agrège les comptes d'investissement.
    ///
    /// Les comptes vides sont exclus : la live sync peut créer des comptes "fantômes"
    /// sans aucun ordre, qui gonfleraient le compteur sans rien apporter.
    ///
    /// `totalCurrentValue` **inclut le cash** (`cashBalance`) — c'est la valeur du
    /// compte au sens patrimonial. Le module Investissements, lui, expose le cash
    /// séparément via `portfolioTotalCash` ; les deux chiffres sont donc légitimement
    /// différents et cette asymétrie est intentionnelle.
    static func from(accounts: [InvestmentAccount]) -> InvestmentsRecap {
        let actives = accounts.filter { $0.currentValue > 0 || $0.cashBalance > 0 }
        guard !actives.isEmpty else { return .empty }
        return InvestmentsRecap(
            totalCurrentValue: actives.reduce(0.0) { $0 + $1.currentValue + $1.cashBalance },
            totalInvested: actives.reduce(0.0) { $0 + $1.investedAmount },
            activeAccountCount: actives.count
        )
    }
}
