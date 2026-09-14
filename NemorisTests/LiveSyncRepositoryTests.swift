import Foundation
import Testing
@testable import Nemoris

/// Automatic sync links (exchanges and wallets).
///
/// What this table holds matters as much as what it doesn't hold:
/// **no secret credentials**. API keys live in the keychain,
/// and the table only keeps the pointer to the provider, its configuration,
/// and the last sync's result.
@Suite("LiveSyncRepository")
struct LiveSyncRepositoryTests {

    private func fixture() throws -> (TestDatabase, LiveSyncRepository) {
        let db = try TestDatabase()
        return (db, LiveSyncRepository(store: db.store))
    }

    // MARK: - Creation

    @Test("Un lien créé se relit avec sa configuration")
    func creation() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let id = try #require(repo.addLink(providerId: "evm_wallet",
                                           displayName: "MetaMask principal",
                                           accountId: nil,
                                           config: ["chain": "polygon"]))

        let lien = try #require(repo.fetchLink(id: id))
        #expect(lien.providerId == "evm_wallet")
        #expect(lien.displayName == "MetaMask principal")
        #expect(lien.enabled, "un lien tout juste créé est actif")
        #expect(lien.configJSON?.contains("polygon") == true,
                "sans la chaîne, on interrogerait le bon portefeuille au mauvais endroit")
    }

    @Test("Un lien sans compte associé reste valide")
    func sansCompteAssocie() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        // The account is created automatically on the first sync:
        // requiring an account at creation would force preparing it by hand.
        let id = try #require(repo.addLink(providerId: "bitcoin_wallet",
                                           displayName: "Cold wallet",
                                           accountId: nil, config: [:]))
        #expect(repo.fetchLink(id: id)?.accountId == nil)
    }

    @Test("Plusieurs liens peuvent viser le même fournisseur")
    func plusieursLiensMemeFournisseur() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        // Two Ethereum wallets, or two accounts at the same exchange:
        // forbidding a duplicate provider would rule out a common case.
        _ = repo.addLink(providerId: "evm_wallet", displayName: "Wallet A",
                         accountId: nil, config: ["chain": "eth"])
        _ = repo.addLink(providerId: "evm_wallet", displayName: "Wallet B",
                         accountId: nil, config: ["chain": "base"])

        #expect(repo.fetchLinks().count == 2)
    }

    @Test("Les liens sont rendus du plus récent au plus ancien")
    func ordreDesLiens() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        _ = repo.addLink(providerId: "binance", displayName: "Ancien",
                         accountId: nil, config: [:])
        _ = repo.addLink(providerId: "solana_wallet", displayName: "Récent",
                         accountId: nil, config: [:])

        let noms = repo.fetchLinks().map(\.displayName)
        #expect(noms.first == "Récent", "obtenu : \(noms)")
    }

    // MARK: - Modification

    @Test("Modifier un lien préserve son identifiant")
    func modification() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.addLink(providerId: "evm_wallet", displayName: "Avant",
                                           accountId: nil, config: ["chain": "eth"]))
        var lien = try #require(repo.fetchLink(id: id))

        lien.displayName = "Après"
        lien.enabled = false
        #expect(repo.updateLink(lien))

        let relu = try #require(repo.fetchLink(id: id))
        #expect(relu.displayName == "Après")
        #expect(!relu.enabled)
        // The keychain indexes secret credentials BY link id:
        // changing one here would make them unfindable.
        #expect(relu.id == id)
    }

    @Test("Désactiver un lien le conserve plutôt que de l'effacer")
    func desactivation() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.addLink(providerId: "binance", displayName: "Binance",
                                           accountId: nil, config: [:]))
        var lien = try #require(repo.fetchLink(id: id))

        lien.enabled = false
        _ = repo.updateLink(lien)

        // Pausing a sync must not cost re-entering the key.
        #expect(repo.fetchLinks().count == 1)
        #expect(repo.fetchLink(id: id)?.enabled == false)
    }

    // MARK: - Sync report

    @Test("Un succès de synchronisation est horodaté et daté")
    func succesDeSynchronisation() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.addLink(providerId: "binance", displayName: "Binance",
                                           accountId: nil, config: [:]))
        #expect(repo.fetchLink(id: id)?.lastSyncAt == nil, "rien avant la première synchronisation")

        repo.updateSyncStatus(linkId: id, status: .ok, message: "+3 nouvelles, 12 maj",
                              syncedAt: date("2026-03-10"))

        let lien = try #require(repo.fetchLink(id: id))
        #expect(lien.lastSyncStatus == .ok)
        #expect(lien.lastSyncMessage == "+3 nouvelles, 12 maj")
        #expect(lien.lastSyncAt != nil)
    }

    @Test("Un échec conserve son message pour l'écran de réglages")
    func echecDeSynchronisation() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.addLink(providerId: "evm_wallet", displayName: "Wallet",
                                           accountId: nil, config: [:]))

        repo.updateSyncStatus(linkId: id, status: .error, message: "Clé refusée")

        // Without the message, the user sees "failed" with no idea what to fix.
        #expect(repo.fetchLink(id: id)?.lastSyncMessage == "Clé refusée")
    }

    @Test("Un nouveau compte rendu remplace le précédent")
    func compteRenduRemplace() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.addLink(providerId: "binance", displayName: "Binance",
                                           accountId: nil, config: [:]))

        repo.updateSyncStatus(linkId: id, status: .error, message: "Réseau indisponible")
        repo.updateSyncStatus(linkId: id, status: .ok, message: nil)

        let lien = try #require(repo.fetchLink(id: id))
        #expect(lien.lastSyncStatus == .ok)
        // Keeping the old message would show a resolved error as current.
        #expect(lien.lastSyncMessage == nil)
    }

    @Test("Le compte rendu ne touche que le lien visé")
    func compteRenduCible() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let a = try #require(repo.addLink(providerId: "binance", displayName: "A",
                                          accountId: nil, config: [:]))
        let b = try #require(repo.addLink(providerId: "bitcoin_wallet", displayName: "B",
                                          accountId: nil, config: [:]))

        repo.updateSyncStatus(linkId: a, status: .error, message: "Échec")

        #expect(repo.fetchLink(id: b)?.lastSyncStatus == nil,
                "une synchronisation par lien : un échec ne doit pas contaminer les autres")
    }

    // MARK: - Deletion

    @Test("Supprimer un lien le retire de la liste")
    func suppression() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let id = try #require(repo.addLink(providerId: "binance", displayName: "Binance",
                                           accountId: nil, config: [:]))

        #expect(repo.deleteLink(id: id))
        #expect(repo.fetchLink(id: id) == nil)
        #expect(repo.fetchLinks().isEmpty)
    }

    @Test("Lire un lien inexistant rend l'absence, pas une valeur par défaut")
    func lienInexistant() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.fetchLink(id: 9_999) == nil)
        #expect(repo.fetchLinks().isEmpty)
    }
}
