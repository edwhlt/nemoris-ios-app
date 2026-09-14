import Foundation
import Testing
@testable import Nemoris

/// Computing annual tax figures.
///
/// This is the only engine in the app whose numbers get copied onto
/// an official tax return. A wrong capital gain isn't a display
/// glitch: it ends up in a box on the form.
///
/// The core is FIFO — each sale consumes the oldest purchases first.
/// It's the method the tax authorities require for a securities account, and
/// it gives a different result than the average cost basis.
@Suite("TaxReportEngine")
struct TaxReportEngineTests {

    private func fixture() throws -> (TestDatabase, InvestmentRepository, TransactionRepository) {
        let db = try TestDatabase()
        return (db, InvestmentRepository(store: db.store), TransactionRepository(store: db.store))
    }

    /// Creates an account, a position, and returns the position's id.
    private func position(_ repo: InvestmentRepository, type: String = "CTO",
                          nom: String = "Total") -> Int {
        let compteId = repo.addAccountAndGetId(name: "Mon \(type)", broker: "Courtier",
                                               currency: "EUR", accountType: type,
                                               openedAt: date("2020-01-01"))!
        return repo.addPositionAndGetId(accountId: compteId, assetType: "STOCK",
                                        assetName: nom, ticker: "TTE",
                                        purchaseDate: date("2020-01-01"))!
    }

    private func ordre(_ repo: InvestmentRepository, _ positionId: Int,
                       _ type: InvestmentOrderType, qty: Double, prix: Double,
                       frais: Double = 0, jour: String) {
        _ = repo.addOrder(InvestmentOrder(id: 0, positionId: positionId, orderType: type,
                                          quantity: qty, unitPrice: prix, fees: frais,
                                          executedAt: date(jour), notes: nil))
    }

    // MARK: - FIFO

    @Test("Une vente consomme le lot le plus ancien, pas le moins cher")
    func fifoOrdreDesLots() throws {
        let (db, inv, tx) = try fixture()
        defer { db.destroy() }
        let pos = position(inv)

        // A purchase of 10 at €100, then 10 at €50. A sale of 10 at €120.
        // FIFO consumes the first lot: cost basis €100, gain €20/share.
        // The AVERAGE cost basis would give €75 and a gain of €45 — so a
        // declared capital gain more than twice too high.
        ordre(inv, pos, .buy, qty: 10, prix: 100, jour: "2024-03-01")
        ordre(inv, pos, .buy, qty: 10, prix: 50, jour: "2024-06-01")
        ordre(inv, pos, .sell, qty: 10, prix: 120, jour: "2026-02-01")

        let rapport = TaxReportEngine.generate(year: 2026, invRepo: inv, txRepo: tx)
        #expect(rapport.ctoGains.count == 1)
        let g = rapport.ctoGains[0]
        #expect(abs(g.weightedBuyPrice - 100) < 0.01,
                "prix de revient FIFO : \(g.weightedBuyPrice)")
        #expect(abs(g.unitSalePrice - 120) < 0.01)
        #expect(abs(g.quantity - 10) < 0.01)
    }

    @Test("Une vente à cheval sur deux lots donne un prix de revient pondéré")
    func fifoDeuxLots() throws {
        let (db, inv, tx) = try fixture()
        defer { db.destroy() }
        let pos = position(inv)

        // 10 at 100 then 10 at 200. A sale of 15: 10 from the first lot + 5 from the second.
        // Weighted cost basis = (10×100 + 5×200) / 15 = 2000/15 = 133.33.
        ordre(inv, pos, .buy, qty: 10, prix: 100, jour: "2024-03-01")
        ordre(inv, pos, .buy, qty: 10, prix: 200, jour: "2024-06-01")
        ordre(inv, pos, .sell, qty: 15, prix: 250, jour: "2026-02-01")

        let g = TaxReportEngine.generate(year: 2026, invRepo: inv, txRepo: tx).ctoGains[0]
        #expect(abs(g.weightedBuyPrice - 2000.0 / 15.0) < 0.01,
                "prix de revient : \(g.weightedBuyPrice)")
        #expect(abs(g.quantity - 15) < 0.01)
    }

    @Test("Les frais d'achat entrent dans le prix de revient")
    func fraisDachatIntegres() throws {
        let (db, inv, tx) = try fixture()
        defer { db.destroy() }
        let pos = position(inv)

        // 10 shares at €100 with €50 in fees: unit cost basis €105.
        // Ignoring them would inflate the declared capital gain by €50.
        ordre(inv, pos, .buy, qty: 10, prix: 100, frais: 50, jour: "2024-03-01")
        ordre(inv, pos, .sell, qty: 10, prix: 130, jour: "2026-02-01")

        let g = TaxReportEngine.generate(year: 2026, invRepo: inv, txRepo: tx).ctoGains[0]
        #expect(abs(g.weightedBuyPrice - 105) < 0.01, "revient : \(g.weightedBuyPrice)")
    }

    @Test("Une vente partielle laisse le reste du lot disponible")
    func ventePartielle() throws {
        let (db, inv, tx) = try fixture()
        defer { db.destroy() }
        let pos = position(inv)

        // 20 at 100. A sale of 5, then of 5: both at a cost basis of 100.
        ordre(inv, pos, .buy, qty: 20, prix: 100, jour: "2024-03-01")
        ordre(inv, pos, .sell, qty: 5, prix: 150, jour: "2026-02-01")
        ordre(inv, pos, .sell, qty: 5, prix: 160, jour: "2026-05-01")

        let gains = TaxReportEngine.generate(year: 2026, invRepo: inv, txRepo: tx).ctoGains
        #expect(gains.count == 2, "obtenu \(gains.count) cessions")
        for g in gains {
            #expect(abs(g.weightedBuyPrice - 100) < 0.01, "revient : \(g.weightedBuyPrice)")
        }
    }

    // MARK: - Scope

    @Test("Seules les ventes de l'année déclarée sont retenues")
    func filtreAnnuel() throws {
        let (db, inv, tx) = try fixture()
        defer { db.destroy() }
        let pos = position(inv)

        ordre(inv, pos, .buy, qty: 30, prix: 100, jour: "2024-01-01")
        ordre(inv, pos, .sell, qty: 10, prix: 150, jour: "2025-06-01")
        ordre(inv, pos, .sell, qty: 10, prix: 150, jour: "2026-06-01")
        ordre(inv, pos, .sell, qty: 10, prix: 150, jour: "2027-06-01")

        let gains = TaxReportEngine.generate(year: 2026, invRepo: inv, txRepo: tx).ctoGains
        #expect(gains.count == 1, "obtenu \(gains.count) cessions pour 2026")

        // Earlier sales must still have consumed their lots:
        // ignoring them entirely would throw off the year's cost basis.
        #expect(abs(gains[0].weightedBuyPrice - 100) < 0.01)
    }

    @Test("Un PEA n'entre pas dans les plus-values imposables")
    func peaHorsPlusValues() throws {
        let (db, inv, tx) = try fixture()
        defer { db.destroy() }
        let pos = position(inv, type: "PEA")

        ordre(inv, pos, .buy, qty: 10, prix: 100, jour: "2024-03-01")
        ordre(inv, pos, .sell, qty: 10, prix: 200, jour: "2026-02-01")

        let rapport = TaxReportEngine.generate(year: 2026, invRepo: inv, txRepo: tx)
        #expect(rapport.ctoGains.isEmpty,
                "une cession en PEA n'est pas imposable tant qu'il n'y a pas de retrait")
        #expect(rapport.peaSnapshots.count == 1, "mais le PEA doit apparaître en suivi")
    }

    @Test("Les dividendes ne comptent pas comme des cessions")
    func dividendesIgnores() throws {
        let (db, inv, tx) = try fixture()
        defer { db.destroy() }
        let pos = position(inv)

        ordre(inv, pos, .buy, qty: 10, prix: 100, jour: "2024-03-01")
        ordre(inv, pos, .dividend, qty: 10, prix: 3, jour: "2026-04-01")

        let gains = TaxReportEngine.generate(year: 2026, invRepo: inv, txRepo: tx).ctoGains
        #expect(gains.isEmpty, "un dividende relève d'une autre case que la plus-value")
    }

    @Test("Une année sans opération produit un rapport vide et non une erreur")
    func anneeVide() throws {
        let (db, inv, tx) = try fixture()
        defer { db.destroy() }

        let rapport = TaxReportEngine.generate(year: 2026, invRepo: inv, txRepo: tx)
        #expect(rapport.ctoGains.isEmpty)
        #expect(rapport.peaSnapshots.isEmpty)
        #expect(rapport.propertyIncome.totalAmount == 0)
        #expect(rapport.year == 2026)
    }

    // MARK: - Real estate income

    @Test("Les loyers de l'année sont sommés, les dépenses écartées")
    func revenusFonciers() throws {
        let (db, inv, tx) = try fixture()
        defer { db.destroy() }
        _ = tx.addAccount(name: "Courant")
        let compte = tx.fetchAccounts()[0]
        let locataire = tx.addTiersAndGetId(name: "Loyer Dupont", regex: "LOYER")!

        for mois in ["2026-01-05", "2026-02-05", "2026-03-05"] {
            _ = tx.addTransaction(accountId: compte.id, tiersId: locataire, categoryId: nil,
                                  paymentTypeId: nil, information: "", amount: 750,
                                  date: date(mois))
        }
        // An expense carrying the same word must not be counted as income.
        _ = tx.addTransaction(accountId: compte.id, tiersId: locataire, categoryId: nil,
                              paymentTypeId: nil, information: "", amount: -200,
                              date: date("2026-04-05"))

        let revenus = TaxReportEngine.generate(year: 2026, invRepo: inv, txRepo: tx).propertyIncome
        #expect(revenus.entriesCount == 3, "entrées : \(revenus.entriesCount)")
        #expect(abs(revenus.totalAmount - 2_250) < 0.01, "total : \(revenus.totalAmount)")
    }

    @Test("Les loyers d'une autre année ne sont pas comptés")
    func loyersHorsAnnee() throws {
        let (db, inv, tx) = try fixture()
        defer { db.destroy() }
        _ = tx.addAccount(name: "Courant")
        let compte = tx.fetchAccounts()[0]
        let locataire = tx.addTiersAndGetId(name: "Loyer Dupont", regex: "LOYER")!

        _ = tx.addTransaction(accountId: compte.id, tiersId: locataire, categoryId: nil,
                              paymentTypeId: nil, information: "", amount: 750,
                              date: date("2025-12-15"))

        let revenus = TaxReportEngine.generate(year: 2026, invRepo: inv, txRepo: tx).propertyIncome
        #expect(revenus.entriesCount == 0, "un loyer de décembre 2025 relève de 2025")
    }
}
