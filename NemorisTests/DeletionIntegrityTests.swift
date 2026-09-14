import Foundation
import Testing
@testable import Nemoris

/// What a deletion must take with it.
///
/// The schema declares `ON DELETE CASCADE` on sixteen relations, but SQLite
/// ignores foreign keys unless `PRAGMA foreign_keys = ON` has been
/// set — and that setting is **per connection**, not per database. A schema
/// declaration is therefore not a guarantee: each deletion path must
/// be verified individually.
///
/// Orphan rows aren't just dead weight. They all carry a `uuid` and
/// `updated_at`, so they get synced and
/// arrive on other devices referencing a row that no longer
/// exists there.
@Suite("Intégrité des suppressions")
struct DeletionIntegrityTests {

    private func fixture() throws -> (TestDatabase, TransactionRepository) {
        let db = try TestDatabase()
        return (db, TransactionRepository(store: db.store))
    }

    /// A transaction with a tag, a tracked reimbursement, and a
    /// metadata entry — the three children declared as cascading.
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

        // The fixture must be complete, otherwise the following test proves nothing.
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
        // The tag itself survives: it's a reference entity, shared
        // by other transactions. Only the LINK disappears.
        #expect(db.count("tags") == 1)
    }

    @Test("La suppression multiple emporte les enfants de chaque transaction")
    func suppressionMultiple() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let txId = try transactionAvecEnfants(db, repo)

        // The batch path is distinct from the single-row path: it reuses a
        // single statement for the whole selection. Verifying one says nothing
        // about the other.
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

        // A cascade that's too broad is just as serious as a missing one.
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

        // A tag can be applied to a Tricount expense just as to a
        // transaction: deletion must cover BOTH link tables, not just
        // the one for the module it's deleted from.
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
