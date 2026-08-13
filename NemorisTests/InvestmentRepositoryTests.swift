import Foundation
import Testing
@testable import Nemoris

/// Dépôt des investissements.
///
/// Le point à protéger est un choix de conception : depuis la migration v30,
/// la quantité, le prix de revient et la date d'achat d'une position ne sont
/// plus STOCKÉS mais DÉRIVÉS de ses ordres, à la lecture. Écrire ces champs
/// n'a donc aucun effet — un appelant qui l'ignorerait croirait avoir corrigé
/// une position sans que rien ne change.
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

    // MARK: - Quantité et prix de revient dérivés

    @Test("Une position sans ordre a une quantité nulle")
    func positionSansOrdre() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        _ = repo.addPositionAndGetId(accountId: compte, assetType: "STOCK",
                                     assetName: "Titre", ticker: "T",
                                     purchaseDate: date("2025-01-01"))

        let position = try #require(repo.fetchPositions(accountId: compte).first)
        // C'est le bug qu'avait l'import CSV : créer la position sans ordre
        // donnait une ligne à « 0,0000 @ 0,00 € » dans le portefeuille.
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

        // 10 à 100 € puis 30 à 60 € : la moyenne simple donnerait 80 €,
        // la moyenne pondérée 70 €. C'est cette dernière qui reflète le coût.
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

        // 10 × 100 € + 5 € de frais = 1 005 € pour 10 titres.
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
        // Vendre ne change pas ce qu'on a payé pour ce qui reste.
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
        // Saisie incohérente : vendre plus qu'on ne détient.
        #expect(repo.addOrder(ordre(position, .sell, quantite: 25, prix: 60)))

        let relu = try #require(repo.fetchPositions(accountId: compte).first)
        // Une quantité négative afficherait une position fantôme à valeur négative.
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
        // C'est le point d'entrée marqué sur le graphique de la position.
        #expect(composants.year == 2025 && composants.month == 2,
                "obtenu : \(relu.purchaseDate)")
    }

    // MARK: - Ce que l'écriture ne peut plus faire

    @Test("Écrire quantité et prix de revient sur une position n'a aucun effet")
    func champsDerivesNonEcrivables() throws {
        let (db, repo, compte) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.addPositionAndGetId(
            accountId: compte, assetType: "STOCK", assetName: "Titre",
            ticker: "T", purchaseDate: date("2025-01-01")))
        #expect(repo.addOrder(ordre(id, .buy, quantite: 10, prix: 100)))

        // Un appelant qui tenterait de « corriger » la position ainsi croirait
        // avoir agi : les valeurs sont silencieusement ignorées.
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

    // MARK: - Ordres

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
        // Une seconde synchronisation rejoue les mêmes transactions.
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

        // Deux achats réels du même titre, le même jour, au même cours : les
        // fusionner ferait disparaître la moitié du portefeuille.
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
        // Des ordres orphelins fausseraient tout recalcul ultérieur.
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

    // MARK: - Isolation entre comptes

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
