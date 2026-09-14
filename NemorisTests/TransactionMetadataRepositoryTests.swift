import Foundation
import Testing
@testable import Nemoris

/// Free-form metadata attached to transactions.
///
/// These keys replace the previously imposed payment method: the user
/// defines what they want to track themselves. The `payment_method` role is
/// exclusive, and it's the one import fills in — if it doesn't exist, the
/// deduced hint must be ignored rather than inventing a key behind the user's back.
@Suite("TransactionMetadataRepository")
struct TransactionMetadataRepositoryTests {

    private func fixture() throws -> (TestDatabase, TransactionMetadataRepository, TransactionRepository) {
        let db = try TestDatabase()
        return (db, TransactionMetadataRepository(store: db.store),
                TransactionRepository(store: db.store))
    }

    /// Creates an account and a transaction, and returns its id.
    private func transaction(_ repo: TransactionRepository, montant: Double = -30) -> Int {
        if repo.fetchAccounts().isEmpty { _ = repo.addAccount(name: "Courant") }
        let compte = repo.fetchAccounts()[0]
        return repo.addTransaction(accountId: compte.id, tiersId: nil, categoryId: nil,
                                   paymentTypeId: nil, information: "x", amount: montant,
                                   date: date("2026-03-01"))!
    }

    // MARK: - Keys

    @Test("Une clé créée est relue avec son icône et son rôle")
    func creationDeCle() throws {
        let (db, meta, _) = try fixture()
        defer { db.destroy() }

        let id = meta.addKey(name: "Projet", icon: "folder", role: nil)
        #expect(id != nil)

        let cles = meta.fetchKeys().filter { $0.name == "Projet" }
        #expect(cles.count == 1)
        #expect(cles[0].icon == "folder")
        #expect(cles[0].role == nil)
    }

    @Test("Un nom vide ou fait d'espaces est refusé")
    func nomVide() throws {
        let (db, meta, _) = try fixture()
        defer { db.destroy() }

        #expect(meta.addKey(name: "", icon: nil, role: nil) == nil)
        #expect(meta.addKey(name: "   ", icon: nil, role: nil) == nil)
    }

    @Test("Le nom est débarrassé de ses espaces de bord")
    func nomNettoye() throws {
        let (db, meta, _) = try fixture()
        defer { db.destroy() }

        _ = meta.addKey(name: "  Projet  ", icon: nil, role: nil)
        #expect(meta.fetchKeys().contains { $0.name == "Projet" },
                "noms obtenus : \(meta.fetchKeys().map(\.name))")
    }

    @Test("Le rôle est exclusif : la nouvelle clé libère la précédente")
    func roleExclusif() throws {
        let (db, meta, _) = try fixture()
        defer { db.destroy() }

        _ = meta.addKey(name: "Ancienne", icon: nil, role: .paymentMethod)
        _ = meta.addKey(name: "Nouvelle", icon: nil, role: .paymentMethod)

        // A partial UNIQUE index keeps the role exclusive. Without
        // explicitly releasing it from its previous holder, the insert would fail on
        // a constraint the user couldn't understand.
        let porteurs = meta.fetchKeys().filter { $0.role == .paymentMethod }
        #expect(porteurs.count == 1, "porteurs du rôle : \(porteurs.map(\.name))")
        #expect(porteurs.first?.name == "Nouvelle")
        #expect(meta.fetchKeys().contains { $0.name == "Ancienne" },
                "l'ancienne clé survit, elle perd seulement son rôle")
    }

    @Test("On retrouve la clé qui porte un rôle donné")
    func rechercheParRole() throws {
        let (db, meta, _) = try fixture()
        defer { db.destroy() }

        #expect(meta.key(withRole: .paymentMethod) == nil, "aucune clé au départ")
        _ = meta.addKey(name: "Mode de paiement", icon: nil, role: .paymentMethod)
        #expect(meta.key(withRole: .paymentMethod)?.name == "Mode de paiement")
    }

    @Test("Supprimer une clé emporte ses valeurs")
    func suppressionDeCle() throws {
        let (db, meta, repo) = try fixture()
        defer { db.destroy() }

        let cleId = meta.addKey(name: "Projet", icon: nil, role: nil)!
        let txId = transaction(repo)
        #expect(meta.setValue("Cuisine", keyId: cleId, transactionId: txId))
        #expect(db.count("transaction_metadata_values") == 1)

        #expect(meta.deleteKey(id: cleId))
        #expect(db.count("transaction_metadata_values") == 0,
                "des valeurs orphelines resteraient invisibles et pèseraient sur la synchronisation")
    }

    // MARK: - Valeurs

    @Test("Une valeur posée est relue sur sa transaction")
    func poseDeValeur() throws {
        let (db, meta, repo) = try fixture()
        defer { db.destroy() }

        let cleId = meta.addKey(name: "Projet", icon: nil, role: nil)!
        let txId = transaction(repo)

        #expect(meta.setValue("Cuisine", keyId: cleId, transactionId: txId))
        let valeurs = meta.fetchValues(transactionId: txId)
        #expect(valeurs.count == 1)
        #expect(valeurs[0].value == "Cuisine")
        #expect(valeurs[0].keyName == "Projet", "le nom de la clé accompagne la valeur")
    }

    @Test("Réécrire une valeur la remplace au lieu de l'empiler")
    func remplacementDeValeur() throws {
        let (db, meta, repo) = try fixture()
        defer { db.destroy() }

        let cleId = meta.addKey(name: "Projet", icon: nil, role: nil)!
        let txId = transaction(repo)

        #expect(meta.setValue("Cuisine", keyId: cleId, transactionId: txId))
        // This call goes through an UPSERT on a synced table — the exact
        // pattern that used to fail before the enqueue-trigger fix.
        #expect(meta.setValue("Salle de bain", keyId: cleId, transactionId: txId),
                "la seconde écriture ne doit pas être refusée")

        let valeurs = meta.fetchValues(transactionId: txId)
        #expect(valeurs.count == 1, "obtenu \(valeurs.count) valeurs")
        #expect(valeurs[0].value == "Salle de bain")
    }

    @Test("Une valeur vide efface la métadonnée")
    func valeurVideEfface() throws {
        let (db, meta, repo) = try fixture()
        defer { db.destroy() }

        let cleId = meta.addKey(name: "Projet", icon: nil, role: nil)!
        let txId = transaction(repo)
        #expect(meta.setValue("Cuisine", keyId: cleId, transactionId: txId))

        // This is how the user removes a metadata value: by clearing the field.
        #expect(meta.setValue("   ", keyId: cleId, transactionId: txId))
        #expect(meta.fetchValues(transactionId: txId).isEmpty)
    }

    @Test("Plusieurs clés cohabitent sur la même transaction")
    func plusieursClésParTransaction() throws {
        let (db, meta, repo) = try fixture()
        defer { db.destroy() }

        let projet = meta.addKey(name: "Projet", icon: nil, role: nil)!
        let compte = meta.addKey(name: "Compte", icon: nil, role: nil)!
        let txId = transaction(repo)

        #expect(meta.setValue("Cuisine", keyId: projet, transactionId: txId))
        #expect(meta.setValue("Joint", keyId: compte, transactionId: txId))

        #expect(meta.fetchValues(transactionId: txId).count == 2,
                "0..N métadonnées par transaction, contrairement au mode de paiement d'avant")
    }

    // MARK: - Suggestions et filtre

    @Test("Les valeurs déjà employées sont proposées, les plus fréquentes d'abord")
    func suggestionsParFrequence() throws {
        let (db, meta, repo) = try fixture()
        defer { db.destroy() }

        let cleId = meta.addKey(name: "Projet", icon: nil, role: nil)!
        for _ in 1...3 { _ = meta.setValue("Cuisine", keyId: cleId, transactionId: transaction(repo)) }
        _ = meta.setValue("Jardin", keyId: cleId, transactionId: transaction(repo))

        let suggestions = meta.distinctValues(keyId: cleId)
        #expect(suggestions.first == "Cuisine", "obtenu : \(suggestions)")
        #expect(suggestions.count == 2, "les doublons sont regroupés")
    }

    @Test("Le filtre rend les transactions portant une valeur, ou toutes celles de la clé")
    func filtreParValeur() throws {
        let (db, meta, repo) = try fixture()
        defer { db.destroy() }

        let cleId = meta.addKey(name: "Projet", icon: nil, role: nil)!
        let a = transaction(repo), b = transaction(repo), c = transaction(repo)
        #expect(meta.setValue("Cuisine", keyId: cleId, transactionId: a))
        #expect(meta.setValue("Cuisine", keyId: cleId, transactionId: b))
        #expect(meta.setValue("Jardin", keyId: cleId, transactionId: c))

        #expect(meta.transactionIds(keyId: cleId, value: "Cuisine") == [a, b])
        #expect(meta.transactionIds(keyId: cleId, value: "cuisine") == [a, b],
                "la casse ne doit pas faire rater le filtre")
        #expect(meta.transactionIds(keyId: cleId, value: nil) == [a, b, c],
                "sans valeur, toutes les transactions portant la clé")
    }

    // MARK: - Indice d'import

    @Test("L'indice d'import n'écrit que si une clé porte le rôle")
    func indiceDImport() throws {
        let (db, meta, repo) = try fixture()
        defer { db.destroy() }
        let txId = transaction(repo)

        // Without a key carrying the role, the hint is ignored: no
        // metadata is created behind the user's back.
        #expect(meta.applyImportHint("CB", transactionId: txId, paymentMethodKeyId: nil) == false)
        #expect(meta.fetchValues(transactionId: txId).isEmpty)

        let cleId = meta.addKey(name: "Mode de paiement", icon: nil, role: .paymentMethod)!
        #expect(meta.applyImportHint("CB", transactionId: txId, paymentMethodKeyId: cleId))
        #expect(meta.fetchValues(transactionId: txId).first?.value == "CB")
    }

    @Test("Un indice vide ne pose rien")
    func indiceVide() throws {
        let (db, meta, repo) = try fixture()
        defer { db.destroy() }

        let cleId = meta.addKey(name: "Mode de paiement", icon: nil, role: .paymentMethod)!
        let txId = transaction(repo)

        #expect(meta.applyImportHint(nil, transactionId: txId, paymentMethodKeyId: cleId) == false)
        #expect(meta.applyImportHint("", transactionId: txId, paymentMethodKeyId: cleId) == false)
        #expect(meta.fetchValues(transactionId: txId).isEmpty)
    }
}
