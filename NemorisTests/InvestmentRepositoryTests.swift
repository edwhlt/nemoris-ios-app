import Foundation
import Testing
@testable import Nemoris

/// The investment repository.
///
/// The point to protect is a design choice: since migration v30,
/// a position's quantity, cost basis, and purchase date are no longer
/// STORED but DERIVED from its orders, on read. Writing these fields therefore
/// has no effect — a caller unaware of this would believe they've fixed
/// a position when nothing changed.
@Suite("Dépôt des investissements")
struct InvestmentRepositoryTests {

    private func fixture() throws -> (TestDatabase, InvestmentRepository, Int) {
        let db = try TestDatabase()
        let repo = InvestmentRepository(store: db.store)
        let compte = repo.addAccountAndGetId(name: "PEA", broker: "Courtier",
                                             currency: "EUR", accountType: "PEA",
                                             openedAt: date("2024-01-01"))!
        return (db, repo, compte)
    }

    private func ordre(_ position: Int, _ type: InvestmentOrderType, quantite: Double,
                       prix: Double, frais: Double = 0, jour: String = "2025-01-15",
                       identifiantExterne: String? = nil) -> InvestmentOrder {
        InvestmentOrder(id: 0, positionId: position, orderType: type, quantity: quantite,
                        unitPrice: prix, fees: frais, executedAt: date(jour),
                        notes: nil, externalId: identifiantExterne)
    }

    // MARK: - Derived quantity and cost basis

    @Test("Une position sans ordre a une quantité nulle")
    func positionSansOrdre() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        _ = repo.addPositionAndGetId(accountId: compte, assetType: "STOCK",
                                     assetName: "Titre", ticker: "T",
                                     purchaseDate: date("2025-01-01"))

        let position = try #require(repo.fetchPositions(accountId: compte).first)
        // This was the CSV import bug: creating a position with no order
        // gave a "0.0000 @ €0.00" line in the portfolio.
        #expect(position.quantity == 0)
        #expect(position.averageBuyPrice == 0)
    }

    @Test("Le prix de revient est la moyenne PONDÉRÉE des achats")
    func prixDeRevientPondere() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let position = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2025-01-01")))

        // 10 at €100 then 30 at €60: a simple average would give €80,
        // the weighted average €70. It's the latter that reflects the actual cost.
        #expect(repo.addOrder(ordre(position, .buy, quantite: 10, prix: 100)))
        #expect(repo.addOrder(ordre(position, .buy, quantite: 30, prix: 60)))

        let relu = try #require(repo.fetchPositions(accountId: compte).first)
        #expect(relu.quantity == 40)
        #expect(abs(relu.averageBuyPrice - 70) < 0.005, "obtenu : \(relu.averageBuyPrice)")
    }

    @Test("Les frais de courtage entrent dans le prix de revient")
    func fraisInclus() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let position = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2025-01-01")))

        // 10 × €100 + €5 in fees = €1,005 for 10 shares.
        #expect(repo.addOrder(ordre(position, .buy, quantite: 10, prix: 100, frais: 5)))

        let relu = try #require(repo.fetchPositions(accountId: compte).first)
        #expect(abs(relu.averageBuyPrice - 100.5) < 0.005,
                "les frais font partie du coût d'acquisition : \(relu.averageBuyPrice)")
    }

    @Test("Une vente réduit la quantité sans toucher au prix de revient")
    func venteReduitLaQuantite() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let position = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2025-01-01")))
        #expect(repo.addOrder(ordre(position, .buy, quantite: 100, prix: 50)))
        #expect(repo.addOrder(ordre(position, .sell, quantite: 40, prix: 80)))

        let relu = try #require(repo.fetchPositions(accountId: compte).first)
        #expect(relu.quantity == 60)
        // Selling doesn't change what was paid for what remains.
        #expect(abs(relu.averageBuyPrice - 50) < 0.005, "obtenu : \(relu.averageBuyPrice)")
    }

    @Test("Un dividende ne touche ni la quantité ni le prix de revient")
    func dividendeNeutre() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let position = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2025-01-01")))
        #expect(repo.addOrder(ordre(position, .buy, quantite: 10, prix: 100)))
        #expect(repo.addOrder(ordre(position, .dividend, quantite: 1, prix: 34.53)))

        let relu = try #require(repo.fetchPositions(accountId: compte).first)
        #expect(relu.quantity == 10, "un coupon n'ajoute pas de titre")
        #expect(abs(relu.averageBuyPrice - 100) < 0.005)
    }

    @Test("Une position entièrement vendue tombe à zéro, jamais en négatif")
    func quantiteJamaisNegative() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let position = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2025-01-01")))
        #expect(repo.addOrder(ordre(position, .buy, quantite: 10, prix: 50)))
        // Inconsistent input: selling more than what's held.
        #expect(repo.addOrder(ordre(position, .sell, quantite: 25, prix: 60)))

        let relu = try #require(repo.fetchPositions(accountId: compte).first)
        // A negative quantity would display a phantom position with negative value.
        #expect(relu.quantity == 0, "obtenu : \(relu.quantity)")
    }

    @Test("La date d'achat est celle du PREMIER achat")
    func dateDuPremierAchat() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let position = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2020-01-01")))
        #expect(repo.addOrder(ordre(position, .buy, quantite: 5, prix: 10, jour: "2025-06-01")))
        #expect(repo.addOrder(ordre(position, .buy, quantite: 5, prix: 12, jour: "2025-02-01")))

        let relu = try #require(repo.fetchPositions(accountId: compte).first)
        let composants = Calendar.current.dateComponents([.year, .month], from: relu.purchaseDate)
        // This is the entry point marked on the position's chart.
        #expect(composants.year == 2025 && composants.month == 2,
                "obtenu : \(relu.purchaseDate)")
    }

    // MARK: - What writing can no longer do

    @Test("Écrire quantité et prix de revient sur une position n'a aucun effet")
    func champsDerivesNonEcrivables() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2025-01-01")))
        #expect(repo.addOrder(ordre(id, .buy, quantite: 10, prix: 100)))

        // A caller trying to "fix" the position this way would believe they
        // succeeded: the values are silently ignored.
        _ = repo.updatePosition(InvestmentPosition(
            id: id, accountId: compte, assetType: "STOCK", assetName: "Renommé",
            ticker: "T", isin: "", quantity: 9_999, averageBuyPrice: 1,
            currentValue: 1_500, purchaseDate: date("2030-01-01")))

        let relu = try #require(repo.fetchPositions(accountId: compte).first)
        #expect(relu.assetName == "Renommé", "les champs éditables, eux, changent")
        #expect(relu.currentValue == 1_500)
        #expect(relu.quantity == 10, "la quantité reste dérivée des ordres")
        #expect(abs(relu.averageBuyPrice - 100) < 0.005)
    }

    // MARK: - Orders

    @Test("Un identifiant externe empêche le doublon à la resynchronisation")
    func dedupParIdentifiantExterne() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let position = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "CRYPTO", assetName: "Bitcoin",
            ticker: "BTC", purchaseDate: date("2025-01-01")))

        let externe = "binance_BTCUSDT_3848291"
        #expect(repo.addOrder(ordre(position, .buy, quantite: 1, prix: 40_000,
                                    identifiantExterne: externe)))
        // A second sync replays the same transactions.
        _ = repo.addOrder(ordre(position, .buy, quantite: 1, prix: 40_000,
                                identifiantExterne: externe))

        #expect(repo.fetchOrders(positionId: position).count == 1,
                "sans dédup, chaque synchronisation doublerait le portefeuille")
        #expect(repo.orderExistsWithExternalId(externe))
        #expect(!repo.orderExistsWithExternalId("jamais_vu"))
    }

    @Test("Deux ordres manuels identiques restent deux ordres")
    func ordresManuelsNonDedupliques() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let position = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2025-01-01")))

        // Two real purchases of the same security, the same day, at the same price:
        // merging them would make half the portfolio disappear.
        #expect(repo.addOrder(ordre(position, .buy, quantite: 5, prix: 20)))
        #expect(repo.addOrder(ordre(position, .buy, quantite: 5, prix: 20)))

        #expect(repo.fetchOrders(positionId: position).count == 2)
        #expect(repo.fetchPositions(accountId: compte).first?.quantity == 10)
    }

    @Test("Supprimer un ordre met à jour la position dérivée")
    func suppressionDOrdre() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let position = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2025-01-01")))
        #expect(repo.addOrder(ordre(position, .buy, quantite: 10, prix: 100)))
        #expect(repo.addOrder(ordre(position, .buy, quantite: 10, prix: 200)))
        let aSupprimer = try #require(repo.fetchOrders(positionId: position)
            .first { $0.unitPrice == 200 })

        #expect(repo.deleteOrder(id: aSupprimer.id))

        let relu = try #require(repo.fetchPositions(accountId: compte).first)
        #expect(relu.quantity == 10)
        #expect(abs(relu.averageBuyPrice - 100) < 0.005, "obtenu : \(relu.averageBuyPrice)")
    }

    // MARK: - Suppressions en cascade

    @Test("Supprimer une position emporte ses ordres")
    func cascadePosition() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let position = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2025-01-01")))
        #expect(repo.addOrder(ordre(position, .buy, quantite: 10, prix: 100)))

        #expect(repo.deletePosition(id: position))

        #expect(repo.fetchPositions(accountId: compte).isEmpty)
        // Orphan orders would throw off any later recalculation.
        #expect(repo.fetchOrders(positionId: position).isEmpty)
    }

    @Test("Supprimer un compte emporte ses positions")
    func cascadeCompte() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        _ = repo.addPositionAndGetId(accountId: compte, assetType: "STOCK",
                                     assetName: "Titre", ticker: "T",
                                     purchaseDate: date("2025-01-01"))

        #expect(repo.deleteAccount(id: compte))

        #expect(repo.fetchAccounts().isEmpty)
        #expect(repo.fetchPositions(accountId: compte).isEmpty)
    }

    // MARK: - Isolation between accounts

    @Test("Les positions d'un compte n'apparaissent pas dans un autre")
    func isolationDesComptes() throws {
        let (db, repo, pea) = try fixture()
        defer { db.destroy() }
        let cto = try #require(repo.addAccountAndGetId(name: "CTO", broker: "C",
                                                        currency: "EUR", accountType: "CTO",
                                                        openedAt: date("2024-02-01")))
        _ = repo.addPositionAndGetId(accountId: pea, assetType: "STOCK",
                                     assetName: "Sur PEA", ticker: "A",
                                     purchaseDate: date("2025-01-01"))
        _ = repo.addPositionAndGetId(accountId: cto, assetType: "STOCK",
                                     assetName: "Sur CTO", ticker: "B",
                                     purchaseDate: date("2025-01-01"))

        #expect(repo.fetchPositions(accountId: pea).map(\.assetName) == ["Sur PEA"])
        #expect(repo.fetchPositions(accountId: cto).map(\.assetName) == ["Sur CTO"])
    }
}
