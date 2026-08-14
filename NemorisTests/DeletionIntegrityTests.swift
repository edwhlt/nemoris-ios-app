import Foundation
import Testing
@testable import Nemoris

/// Ce qu'une suppression doit emporter avec elle.
///
/// Le schéma déclare `ON DELETE CASCADE` sur seize relations, mais SQLite
/// ignore les clés étrangères tant que `PRAGMA foreign_keys = ON` n'a pas été
/// posé — et ce réglage vaut **par connexion**, pas par base. Une déclaration
/// de schéma n'est donc pas une garantie : chaque chemin de suppression doit
/// être vérifié individuellement.
///
/// Les lignes orphelines ne sont pas seulement du poids mort. Elles portent
/// toutes un `uuid` et un `updated_at`, donc elles partent en synchronisation
/// et arrivent sur les autres appareils en référençant une ligne qui n'y
/// existe plus.
@Suite("Intégrité des suppressions")
struct DeletionIntegrityTests {

    private func fixture() throws -> (TestDatabase, TransactionRepository) {
        let db = try TestDatabase()
        return (db, TransactionRepository(store: db.store))
    }

    /// Transaction dotée d'un tag, d'un remboursement suivi et d'une
    /// métadonnée — les trois enfants déclarés en cascade.
    private func transactionAvecEnfants(
        _ db: TestDatabase,
        _ repo: TransactionRepository
    ) throws -> Int {
        #expect(repo.addAccount(name: "Compte courant", type: "COURANT"))
        let compte = try #require(repo.fetchAccounts().first)

        let txId = try #require(repo.addTransaction(
            accountId: compte.id, tiersId: nil, categoryId: nil, paymentTypeId: nil,
            information: "Course", amount: -42, date: Date()))

        let tagId = try #require(repo.findOrCreateTag(name: "vacances"))
        #expect(repo.setTags([tagId], forTransaction: txId))

        let payeurId = try #require(repo.addTiersAndGetId(name: "Alex", regex: ""))
        #expect(ReimbursementRepository(store: db.store)
            .setReimbursement(transactionId: txId, payeeId: payeurId))

        let meta = TransactionMetadataRepository(store: db.store)
        let cleId = try #require(meta.addKey(name: "Projet", icon: nil, role: nil))
        #expect(meta.setValue("Déménagement", keyId: cleId, transactionId: txId))

        // La fixture doit être complète, sinon le test qui suit ne prouve rien.
        #expect(db.count("transaction_tags") == 1)
        #expect(db.count("reimbursements") == 1)
        #expect(db.count("transaction_metadata_values") == 1)

        return txId
    }

    // MARK: - Transactions

    @Test("Supprimer une transaction emporte son tag, son remboursement et ses métadonnées")
    func suppressionUnitaire() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let txId = try transactionAvecEnfants(db, repo)

        #expect(repo.deleteTransaction(id: txId))

        #expect(db.count("transaction_tags") == 0)
        #expect(db.count("reimbursements") == 0)
        #expect(db.count("transaction_metadata_values") == 0)
        // Le tag lui-même survit : c'est une entité du référentiel, partagée
        // par d'autres transactions. Seule la LIAISON disparaît.
        #expect(db.count("tags") == 1)
    }

    @Test("La suppression multiple emporte les enfants de chaque transaction")
    func suppressionMultiple() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let txId = try transactionAvecEnfants(db, repo)

        // Le chemin par lot est distinct du chemin unitaire : il réutilise un
        // seul statement pour toute la sélection. Vérifier l'un ne dit rien
        // de l'autre.
        #expect(repo.deleteTransactions(ids: [txId]) == 1)

        #expect(db.count("transaction_tags") == 0)
        #expect(db.count("reimbursements") == 0)
        #expect(db.count("transaction_metadata_values") == 0)
    }

    @Test("Une transaction voisine garde ses propres enfants")
    func suppressionCiblee() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let supprimee = try transactionAvecEnfants(db, repo)

        // Une cascade trop large est aussi grave qu'une cascade absente.
        let compte = try #require(repo.fetchAccounts().first)
        let gardee = try #require(repo.addTransaction(
            accountId: compte.id, tiersId: nil, categoryId: nil, paymentTypeId: nil,
            information: "Essence", amount: -60, date: Date()))
        let tagId = try #require(repo.findOrCreateTag(name: "vacances"))
        #expect(repo.setTags([tagId], forTransaction: gardee))

        #expect(repo.deleteTransaction(id: supprimee))

        #expect(db.count("transaction_tags") == 1)
        #expect(db.count("transactions") == 1)
    }

    // MARK: - Tags

    @Test("Supprimer un tag emporte ses liaisons des deux côtés")
    func suppressionTag() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        let tagId = try #require(repo.findOrCreateTag(name: "voyage"))

        #expect(repo.addAccount(name: "Compte courant", type: "COURANT"))
        let compte = try #require(repo.fetchAccounts().first)
        let txId = try #require(repo.addTransaction(
            accountId: compte.id, tiersId: nil, categoryId: nil, paymentTypeId: nil,
            information: "Train", amount: -80, date: Date()))
        #expect(repo.setTags([tagId], forTransaction: txId))

        // Un tag est posable sur une dépense Tricount comme sur une
        // transaction : la suppression doit couvrir les DEUX tables de
        // liaison, pas seulement celle du module d'où l'on supprime.
        let tricount = TricountRepository(store: db.store)
        let groupeId = try #require(tricount.saveGroup(
            key: "wk1", title: "Week-end", currency: "EUR", myName: "Moi",
            entries: [ParsedTCEntry(
                sourceUUID: "e1", sourceUpdatedAt: nil, typeTransaction: "NORMAL",
                whoPaid: "Moi", total: 100, currency: "EUR",
                localTotal: nil, localCurrency: nil,
                description: "Hôtel", date: "2026-01-10",
                shares: [(memberName: "Moi", amount: 100)], category: "")]))
        let entree = try #require(tricount.fetchEntries(groupId: groupeId).first)
        #expect(repo.setTags([tagId], forTricountEntry: entree.id))
        #expect(db.count("tricount_entry_tags") == 1)

        #expect(repo.deleteTag(id: tagId))

        #expect(db.count("tags") == 0)
        #expect(db.count("transaction_tags") == 0)
        #expect(db.count("tricount_entry_tags") == 0)
    }
}
