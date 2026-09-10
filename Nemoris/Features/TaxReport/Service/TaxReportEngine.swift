import Foundation

// MARK: - TaxReportEngine
//
// Calcul des éléments fiscaux annuels pour la déclaration française.
//
// **MVP — 3 sections** :
//   1. **Plus-values mobilières CTO (case 3VG / 3UA)** — calcul FIFO strict
//      des ventes de l'année, gain/perte par cession + total annuel
//   2. **Suivi PEA** — alertes "PEA < 5 ans (retrait taxable)", valorisation
//      actuelle, montant total versé estimé
//   3. **Revenus fonciers (case 4BA / micro-foncier 4BE)** — somme des
//      transactions catégorisées "Revenus fonciers" (filter sur catégorie
//      Revenus + libellé contenant "Loyer" comme heuristique fallback)
//
// **Limites assumées** :
//   - Pas de gestion des moins-values reportables (case 3VH) — l'utilisateur les
//     compense lui-même via les exports.
//   - Pas de gestion fiscale crypto (BIC/BNC vs case 3AN — complexe).
//   - Pas de calcul d'abattement PEA selon ancienneté de retrait.
//   - Pas de gestion CSG/CRDS (l'utilisateur a 17.2% par défaut, on l'affiche en info).
//
// Le but est de pré-remplir 90 % du travail — l'utilisateur vérifie et reporte
// les chiffres sur sa déclaration.

struct TaxReportYear {
    let year: Int
    let ctoGains: [CTOGainEntry]
    let peaSnapshots: [PEASnapshotEntry]
    let propertyIncome: PropertyIncomeSummary
    let generatedAt: Date

    /// Somme nette des PV CTO de l'année (gain - perte).
    var ctoNetGain: Double {
        ctoGains.reduce(0) { $0 + $1.gain }
    }

    /// Vrai si on a des données à remonter (sinon le rapport est inutile).
    var hasData: Bool {
        !ctoGains.isEmpty || !peaSnapshots.isEmpty || propertyIncome.totalAmount > 0
    }
}

/// Une ligne = une vente partielle/totale d'une position, matchée FIFO avec
/// un ou plusieurs achats antérieurs.
struct CTOGainEntry: Identifiable, Hashable {
    var id: String { "\(positionId)_\(soldAt.timeIntervalSince1970)" }
    let positionId: Int
    let assetName: String
    let ticker: String
    let accountName: String
    /// Quantité vendue (positive).
    let quantity: Double
    /// Prix unitaire à la vente (€).
    let unitSalePrice: Double
    /// PRU moyen FIFO des lots vendus (€/unité).
    let weightedBuyPrice: Double
    /// Date de la vente.
    let soldAt: Date
    /// Frais imputés à cette cession (vente uniquement — les frais d'achat sont
    /// déjà intégrés au PRU).
    let saleFees: Double

    /// Gain/perte brut(e) sur la cession = (sale_price - weighted_buy_price) * qty - sale_fees
    var gain: Double {
        (unitSalePrice - weightedBuyPrice) * quantity - saleFees
    }

    /// Montant de la cession = unitSalePrice × quantity.
    var saleAmount: Double { unitSalePrice * quantity }
}

/// Snapshot d'un compte PEA en fin d'année (informatif — pour décision retrait).
struct PEASnapshotEntry: Identifiable, Hashable {
    var id: Int { accountId }
    let accountId: Int
    let accountName: String
    let openedAt: Date
    let currentValue: Double
    let totalInvested: Double
    /// Années depuis l'ouverture du PEA. Détermine la fiscalité du retrait :
    /// <5 ans = clôture + imposition, ≥5 ans = retraits possibles, ≥8 ans = sorties
    /// en rente possibles.
    var ageYears: Int {
        Calendar.current.dateComponents([.year], from: openedAt, to: Date()).year ?? 0
    }

    /// Avertissement fiscal selon l'âge.
    var taxStatusLabel: LocalizedStringResource {
        if ageYears < 5 { return "Retrait avant 5 ans : clôture obligatoire + IR" }
        if ageYears < 8 { return "Retraits possibles (5-8 ans, sans clôture)" }
        return "8 ans+ : retraits/rentes exonérés (hors prélèvements sociaux)"
    }
}

/// Récap des revenus fonciers de l'année — somme des transactions catégorisées
/// "Loyer reçu" / "Revenus fonciers".
struct PropertyIncomeSummary {
    let year: Int
    let totalAmount: Double
    let entriesCount: Int

    /// Au-delà de 15 000 € → régime réel obligatoire ; sous → micro-foncier
    /// possible (abattement 30 %). On informe l'utilisateur.
    var suggestedRegime: String {
        totalAmount > 15000
            ? "Régime réel obligatoire (> 15 000 €)"
            : "Micro-foncier possible (abattement 30 %)"
    }
}

enum TaxReportEngine {

    /// Génère le rapport fiscal pour une année donnée.
    /// - Parameters:
    ///   - invRepo, txRepo: repositories, à valeur par défaut sur la base de
    ///     l'application. Les tests les injectent sur une base temporaire — le
    ///     calcul FIFO d'une plus-value ne se vérifie pas autrement.
    static func generate(year: Int,
                         invRepo: InvestmentRepository = InvestmentRepository(),
                         txRepo: TransactionRepository = TransactionRepository()) -> TaxReportYear {
        let cal = Calendar(identifier: .gregorian)
        guard let yearStart = cal.date(from: DateComponents(year: year, month: 1, day: 1)),
              let yearEnd   = cal.date(from: DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59, second: 59))
        else {
            return TaxReportYear(year: year, ctoGains: [], peaSnapshots: [], propertyIncome: .init(year: year, totalAmount: 0, entriesCount: 0), generatedAt: Date())
        }

        let ctoGains = computeCTOGains(year: year, yearStart: yearStart, yearEnd: yearEnd, invRepo: invRepo)
        let peaSnapshots = computePEASnapshots(invRepo: invRepo)
        let propertyIncome = computePropertyIncome(year: year, yearStart: yearStart, yearEnd: yearEnd, txRepo: txRepo)

        return TaxReportYear(
            year: year,
            ctoGains: ctoGains,
            peaSnapshots: peaSnapshots,
            propertyIncome: propertyIncome,
            generatedAt: Date()
        )
    }

    // MARK: - 1. Plus-values CTO FIFO

    /// Pour chaque compte CTO, on prend les positions, leurs orders triés
    /// chronologiquement, et on applique FIFO : chaque SELL consomme les BUY
    /// les plus anciens jusqu'à épuiser sa quantité.
    private static func computeCTOGains(year: Int, yearStart: Date, yearEnd: Date,
                                        invRepo: InvestmentRepository) -> [CTOGainEntry] {
        let accounts = invRepo.fetchAccounts().filter { $0.accountType == "CTO" }
        var result: [CTOGainEntry] = []

        for account in accounts {
            let positions = invRepo.fetchPositions(accountId: account.id)
            for position in positions {
                let orders = invRepo.fetchOrders(positionId: position.id)
                    .sorted { $0.executedAt < $1.executedAt }

                // Lots d'achat en attente de consommation FIFO.
                // Chaque lot : (quantité restante, prix unitaire moyen incluant fees répartis)
                var buyLots: [(qty: Double, unitCost: Double)] = []

                for order in orders {
                    if order.orderType == .buy {
                        // Coût unitaire = prix + fees répartis sur la qty
                        let unitCost = order.unitPrice + (order.fees / max(order.quantity, 0.000001))
                        buyLots.append((qty: order.quantity, unitCost: unitCost))
                    } else if order.orderType == .sell {
                        // Consomme FIFO
                        var remainingToSell = order.quantity
                        var totalCostBasis: Double = 0
                        while remainingToSell > 0 && !buyLots.isEmpty {
                            let lot = buyLots[0]
                            let taken = min(lot.qty, remainingToSell)
                            totalCostBasis += taken * lot.unitCost
                            remainingToSell -= taken
                            if taken >= lot.qty {
                                buyLots.removeFirst()
                            } else {
                                buyLots[0] = (qty: lot.qty - taken, unitCost: lot.unitCost)
                            }
                        }
                        let consumed = order.quantity - remainingToSell
                        // On ne crée l'entry que si la vente tombe dans l'année cible
                        if order.executedAt >= yearStart, order.executedAt <= yearEnd, consumed > 0 {
                            let weightedBuyPrice = totalCostBasis / consumed
                            result.append(CTOGainEntry(
                                positionId: position.id,
                                assetName: position.assetName,
                                ticker: position.ticker,
                                accountName: account.name,
                                quantity: consumed,
                                unitSalePrice: order.unitPrice,
                                weightedBuyPrice: weightedBuyPrice,
                                soldAt: order.executedAt,
                                saleFees: order.fees
                            ))
                        }
                    }
                    // DIV / autres : ignorés pour la PV (les dividendes ont leur
                    // propre case 2DC qui n'est pas couverte en MVP).
                }
            }
        }
        return result.sorted { $0.soldAt < $1.soldAt }
    }

    // MARK: - 2. Snapshot PEA

    private static func computePEASnapshots(invRepo: InvestmentRepository) -> [PEASnapshotEntry] {
        let peas = invRepo.fetchAccounts().filter { $0.accountType == "PEA" }
        return peas.map { acc in
            PEASnapshotEntry(
                accountId: acc.id,
                accountName: acc.name,
                openedAt: acc.openedAt,
                currentValue: acc.currentValue + acc.cashBalance,
                totalInvested: acc.investedAmount
            )
        }
    }

    // MARK: - 3. Revenus fonciers

    /// Heuristique : on prend les transactions de revenus (amount > 0) de
    /// l'année dont le libellé OU la catégorie OU le tiers contient "loyer"
    /// (case-insensitive). Bonne approximation pour la plupart des bailleurs.
    private static func computePropertyIncome(year: Int, yearStart: Date, yearEnd: Date,
                                              txRepo: TransactionRepository) -> PropertyIncomeSummary {
        let txs = txRepo.fetchTransactionsAllAccounts(
            from: yearStart, to: yearEnd, limit: 10000, offset: 0
        )
        let keyword = "loyer"
        let rentals = txs.filter { tx in
            guard tx.amount > 0 else { return false }
            let lowerName = tx.tiersName.lowercased()
            let lowerInfo = tx.information.lowercased()
            let lowerCat = tx.categoryName.lowercased()
            return lowerName.contains(keyword)
                || lowerInfo.contains(keyword)
                || lowerCat.contains(keyword)
        }
        let total = rentals.reduce(0.0) { $0 + $1.amount }
        return PropertyIncomeSummary(
            year: year,
            totalAmount: total,
            entriesCount: rentals.count
        )
    }
}
