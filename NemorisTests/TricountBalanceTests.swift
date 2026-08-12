import Foundation
import Testing
@testable import Nemoris

/// Calcul des soldes d'un Tricount : qui doit quoi à qui.
///
/// C'est le seul endroit de l'application où un chiffre faux se traduit
/// directement par une somme d'argent réclamée à tort, ou jamais réclamée.
/// La fonction est pure — elle prend les écritures, les parts et le nom de
/// l'utilisateur — donc entièrement vérifiable sans base.
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
        // Edwin paie 100, partagé à parts égales avec Anne.
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

        // Le même fait vu des deux côtés doit donner des montants opposés.
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
        // Edwin paie 100 partagé, puis Anne paie 60 partagé : 50 − 30 = 20.
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
        // Invariant fondamental d'un partage de dépenses : l'argent ne se crée
        // ni ne disparaît. Attention à ce qu'on somme — computeBalances rend les
        // soldes DU POINT DE VUE d'une personne, donc la somme de SA liste vaut
        // sa propre position nette, et non zéro. C'est en additionnant les
        // positions nettes de TOUS les membres qu'on doit retomber sur zéro.
        //
        // Ici : Edwin paie 90 et doit 60 (+30), Anne paie 60 et doit 60 (0),
        // Marc paie 30 et doit 60 (−30).
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
        // Chacun paie exactement sa part : aucune dette ne doit apparaître.
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
        // Cas réel : une écriture importée dont les parts n'ont pas suivi.
        // Elle ne doit pas créer de dette fantôme.
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
        // 100 € à trois : 33,34 + 33,33 + 33,33. La somme doit rester nulle
        // malgré l'arrondi, sinon un centime se crée à chaque dépense.
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
