import Foundation
import Testing
@testable import Nemoris

/// Liens de synchronisation automatique (bourses et portefeuilles).
///
/// Ce que cette table contient est aussi important que ce qu'elle ne contient
/// pas : **aucun identifiant secret**. Les clés d'API vivent dans le trousseau,
/// et la table ne garde que le pointeur vers le fournisseur, sa configuration
/// et le résultat de la dernière synchronisation.
@Suite("LiveSyncRepository")
struct LiveSyncRepositoryTests {

    private func fixture() throws -> (TestDatabase, LiveSyncRepository) {
        let db = try TestDatabase()
        return (db, LiveSyncRepository(store: db.store))
    }

    // MARK: - Création

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

        // Le compte est créé automatiquement à la première synchronisation :
        // exiger un compte dès la création imposerait de le préparer à la main.
        let id = try #require(repo.addLink(providerId: "bitcoin_wallet",
                                           displayName: "Cold wallet",
                                           accountId: nil, config: [:]))
        #expect(repo.fetchLink(id: id)?.accountId == nil)
    }

    @Test("Plusieurs liens peuvent viser le même fournisseur")
    func plusieursLiensMemeFournisseur() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        // Deux portefeuilles Ethereum, ou deux comptes chez la même bourse :
        // interdire le doublon de fournisseur empêcherait un cas courant.
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
        // Le trousseau indexe les identifiants secrets PAR identifiant de lien :
        // en changer un ici les rendrait introuvables.
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

        // Une pause de synchronisation ne doit pas coûter la ressaisie de la clé.
        #expect(repo.fetchLinks().count == 1)
        #expect(repo.fetchLink(id: id)?.enabled == false)
    }

    // MARK: - Compte rendu de synchronisation

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

        // Sans le message, l'utilisateur voit « échec » sans savoir quoi corriger.
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
        // Garder l'ancien message afficherait une erreur résolue comme actuelle.
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

    // MARK: - Suppression

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
