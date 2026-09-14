import Foundation
import Testing
@testable import Nemoris

/// Computing a Tricount's balances: who owes what to whom.
///
/// This is the only place in the app where a wrong number translates
/// directly into money wrongly claimed, or never claimed at all.
/// The function is pure — it takes the entries, the shares, and the
/// user's name — so it's fully verifiable with no database.
@Suite("Soldes Tricount")
struct TricountBalanceTests {

    private let repo = TricountRepository()

    private func ecriture(id: Int, type: String = "NORMAL", paye: String,
                          total: Double, jour: String = "2026-03-01") -> TricountEntry {
        TricountEntry(id: id, groupId: 1, sourceUUID: nil, sourceUpdatedAt: nil,
                      typeTransaction: type, whoPaid: paye, total: total, currency: "EUR",
                      localTotal: nil, localCurrency: nil, description: "Dépense",
                      date: date(jour), category: "", userCategoryId: nil,
                      userCategoryName: "", linkedTransactionId: nil)
    }

    private func part(_ id: Int, _ entryId: Int, _ membre: String, _ montant: Double) -> TricountShare {
        TricountShare(id: id, entryId: entryId, memberName: membre, amount: montant)
    }

    // MARK: - Cas de base

    @Test("Une dépense partagée en deux crée une dette de la moitié")
    func partageSimple() {
        // Edwin pays 100, split evenly with Anne.
        let entries = [ecriture(id: 1, paye: "Edwin", total: 100)]
        let shares = [part(1, 1, "Edwin", 50), part(2, 1, "Anne", 50)]

        let soldes = repo.computeBalances(entries: entries, shares: shares, myName: "Edwin")
        let anne = soldes.first { $0.memberName == "Anne" }

        #expect(anne != nil, "Anne doit apparaître dans les soldes")
        #expect(abs((anne?.net ?? 0) - 50) < 0.01,
                "Anne doit 50 à Edwin, net obtenu : \(anne?.net ?? 0)")
    }

    @Test("Le point de vue s'inverse selon l'utilisateur")
    func pointDeVue() {
        let entries = [ecriture(id: 1, paye: "Edwin", total: 100)]
        let shares = [part(1, 1, "Edwin", 50), part(2, 1, "Anne", 50)]

        let vuEdwin = repo.computeBalances(entries: entries, shares: shares, myName: "Edwin")
        let vuAnne = repo.computeBalances(entries: entries, shares: shares, myName: "Anne")

        let anneVueEdwin = vuEdwin.first { $0.memberName == "Anne" }?.net ?? 0
        let edwinVueAnne = vuAnne.first { $0.memberName == "Edwin" }?.net ?? 0

        // The same fact seen from both sides must give opposite amounts.
        #expect(abs(anneVueEdwin + edwinVueAnne) < 0.01,
                "\(anneVueEdwin) et \(edwinVueAnne) devraient s'annuler")
    }

    @Test("Payer sa propre part ne crée aucune dette")
    func depensePersonnelle() {
        let entries = [ecriture(id: 1, paye: "Edwin", total: 40)]
        let shares = [part(1, 1, "Edwin", 40)]

        let soldes = repo.computeBalances(entries: entries, shares: shares, myName: "Edwin")
        #expect(soldes.allSatisfy { abs($0.net) < 0.01 },
                "soldes non nuls : \(soldes.map { "\($0.memberName) \($0.net)" })")
    }

    // MARK: - Compensation

    @Test("Deux dépenses croisées se compensent")
    func compensationCroisee() {
        // Edwin pays a shared 100, then Anne pays a shared 60: 50 − 30 = 20.
        let entries = [ecriture(id: 1, paye: "Edwin", total: 100),
                       ecriture(id: 2, paye: "Anne", total: 60)]
        let shares = [part(1, 1, "Edwin", 50), part(2, 1, "Anne", 50),
                      part(3, 2, "Edwin", 30), part(4, 2, "Anne", 30)]

        let soldes = repo.computeBalances(entries: entries, shares: shares, myName: "Edwin")
        let anne = soldes.first { $0.memberName == "Anne" }

        #expect(abs((anne?.net ?? 0) - 20) < 0.01, "net obtenu : \(anne?.net ?? 0)")
    }

    @Test("Un remboursement direct solde la dette")
    func remboursementSolde() {
        let entries = [ecriture(id: 1, paye: "Edwin", total: 100),
                       ecriture(id: 2, type: "BALANCE", paye: "Anne", total: 50)]
        let shares = [part(1, 1, "Edwin", 50), part(2, 1, "Anne", 50),
                      part(3, 2, "Edwin", 50)]

        let soldes = repo.computeBalances(entries: entries, shares: shares, myName: "Edwin")
        let anne = soldes.first { $0.memberName == "Anne" }?.net ?? 0

        #expect(abs(anne) < 0.01,
                "après remboursement intégral le solde doit être nul, obtenu : \(anne)")
    }

    // MARK: - Invariants

    @Test("Les positions nettes de tous les membres s'annulent entre elles")
    func positionsSAnnulent() {
        // The fundamental invariant of an expense split: money is neither created
        // nor destroyed. Careful what you sum — computeBalances returns
        // balances FROM ONE PERSON'S point of view, so the sum of THEIR list equals
        // their own net position, not zero. It's by adding up the
        // net positions of EVERY member that the total must come out to zero.
        //
        // Here: Edwin pays 90 and owes 60 (+30), Anne pays 60 and owes 60 (0),
        // Marc pays 30 and owes 60 (−30).
        let entries = [ecriture(id: 1, paye: "Edwin", total: 90),
                       ecriture(id: 2, paye: "Anne", total: 60),
                       ecriture(id: 3, paye: "Marc", total: 30)]
        let shares = [part(1, 1, "Edwin", 30), part(2, 1, "Anne", 30), part(3, 1, "Marc", 30),
                      part(4, 2, "Edwin", 20), part(5, 2, "Anne", 20), part(6, 2, "Marc", 20),
                      part(7, 3, "Edwin", 10), part(8, 3, "Anne", 10), part(9, 3, "Marc", 10)]

        var positions: [String: Double] = [:]
        for moi in ["Edwin", "Anne", "Marc"] {
            let soldes = repo.computeBalances(entries: entries, shares: shares, myName: moi)
            positions[moi] = soldes.reduce(0) { $0 + $1.net }
        }

        #expect(abs((positions["Edwin"] ?? 0) - 30) < 0.01, "Edwin : \(positions["Edwin"] ?? 0)")
        #expect(abs(positions["Anne"] ?? 99) < 0.01, "Anne : \(positions["Anne"] ?? 0)")
        #expect(abs((positions["Marc"] ?? 0) + 30) < 0.01, "Marc : \(positions["Marc"] ?? 0)")

        let somme = positions.values.reduce(0, +)
        #expect(abs(somme) < 0.01, "les positions doivent s'annuler, obtenu : \(somme)")
    }

    @Test("Un groupe équilibré ne réclame rien à personne")
    func groupeEquilibre() {
        // Everyone pays exactly their share: no debt should appear.
        let entries = [ecriture(id: 1, paye: "Edwin", total: 30),
                       ecriture(id: 2, paye: "Anne", total: 30)]
        let shares = [part(1, 1, "Edwin", 30), part(2, 2, "Anne", 30)]

        let soldes = repo.computeBalances(entries: entries, shares: shares, myName: "Edwin")
        #expect(soldes.allSatisfy { abs($0.net) < 0.01 },
                "soldes : \(soldes.map { "\($0.memberName) \($0.net)" })")
    }

    @Test("Un groupe sans écriture ne produit aucun solde")
    func groupeVide() {
        #expect(repo.computeBalances(entries: [], shares: [], myName: "Edwin").isEmpty)
    }

    @Test("Une écriture sans part associée ne fait pas dériver les soldes")
    func ecritureSansPart() {
        // A real case: an imported entry whose shares weren't updated.
        // It must not create a phantom debt.
        let entries = [ecriture(id: 1, paye: "Edwin", total: 100),
                       ecriture(id: 2, paye: "Anne", total: 999)]
        let shares = [part(1, 1, "Edwin", 50), part(2, 1, "Anne", 50)]

        let soldes = repo.computeBalances(entries: entries, shares: shares, myName: "Edwin")
        let anne = soldes.first { $0.memberName == "Anne" }?.net ?? 0

        #expect(abs(anne - 50) < 0.01,
                "l'écriture orpheline ne doit pas peser, net obtenu : \(anne)")
    }

    @Test("Les centimes ne se perdent pas sur un partage à trois")
    func partageInegal() {
        // €100 among three: 33.34 + 33.33 + 33.33. The sum must stay zero
        // despite the rounding, otherwise a cent gets created on every expense.
        let entries = [ecriture(id: 1, paye: "Edwin", total: 100)]
        let shares = [part(1, 1, "Edwin", 33.34),
                      part(2, 1, "Anne", 33.33),
                      part(3, 1, "Marc", 33.33)]

        let soldes = repo.computeBalances(entries: entries, shares: shares, myName: "Edwin")
        let total = soldes.reduce(0) { $0 + $1.net }
        #expect(abs(total - 66.66) < 0.01,
                "Edwin doit récupérer 66,66 au total, obtenu : \(total)")
    }
}
