import Foundation
import Testing
@testable import Nemoris

/// The Investments module's aggregates.
///
/// The design point to protect is explicit in the code: everything is
/// derived from `allPositions`, the real state, not from `account.currentValue` —
/// a cache never resynced that stayed at zero. Falling back to this cache
/// would show an empty portfolio with nothing signaling it.
@MainActor
@Suite("InvestmentsViewModel")
struct InvestmentsViewModelTests {

    private func fixture() throws -> (TestDatabase, InvestmentsViewModel, InvestmentRepository) {
        let db = try TestDatabase()
        return (db, InvestmentsViewModel(store: db.store), InvestmentRepository(store: db.store))
    }

    private func compte(id: Int, nom: String, valeurCache: Double = 0,
                        ouvert: String = "2024-01-01") -> InvestmentAccount {
        InvestmentAccount(id: id, name: nom, broker: "Courtier", currency: "EUR",
                          accountType: "CTO", currentValue: valeurCache, investedAmount: 0,
                          openedAt: date(ouvert), cashBalance: 0)
    }

    private func position(id: Int, compteId: Int, type: String = "STOCK",
                          qty: Double, pru: Double, valeur: Double) -> InvestmentPosition {
        InvestmentPosition(id: id, accountId: compteId, assetType: type,
                           assetName: "Titre \(id)", ticker: "T\(id)", isin: "",
                           quantity: qty, averageBuyPrice: pru, currentValue: valeur,
                           purchaseDate: date("2024-06-01"))
    }

    // MARK: - The design point not to lose

    @Test("La valorisation vient des positions, jamais du cache du compte")
    func valorisationDepuisLesPositions() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        // The account's cache reports 0 — that's exactly the historical defect.
        vm.accounts = [compte(id: 1, nom: "CTO", valeurCache: 0)]
        vm.allPositions = [position(id: 1, compteId: 1, qty: 10, pru: 100, valeur: 1_500)]

        #expect(vm.dashboard.totalValuation == 1_500,
                "un portefeuille garni ne doit pas s'afficher à zéro")
        #expect(vm.dashboard.totalInvested == 1_000, "10 × 100")
        #expect(vm.dashboard.performance == 500)
    }

    @Test("Le montant investi se dérive de la quantité et du prix de revient")
    func montantInvesti() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.accounts = [compte(id: 1, nom: "CTO")]
        vm.allPositions = [position(id: 1, compteId: 1, qty: 7, pru: 34.53, valeur: 300),
                           position(id: 2, compteId: 1, qty: 2, pru: 100, valeur: 250)]

        #expect(abs(vm.dashboard.totalInvested - (7 * 34.53 + 200)) < 0.01,
                "investi : \(vm.dashboard.totalInvested)")
        #expect(vm.dashboard.totalValuation == 550)
    }

    @Test("Une performance négative reste négative")
    func performanceNegative() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.accounts = [compte(id: 1, nom: "CTO")]
        vm.allPositions = [position(id: 1, compteId: 1, qty: 10, pru: 100, valeur: 700)]

        #expect(vm.dashboard.performance == -300,
                "une moins-value doit s'afficher comme telle, pas être ramenée à zéro")
    }

    // MARK: - Allocations

    @Test("L'allocation par type regroupe les positions et trie par poids")
    func allocationParType() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.accounts = [compte(id: 1, nom: "CTO")]
        vm.allPositions = [position(id: 1, compteId: 1, type: "STOCK", qty: 1, pru: 1, valeur: 300),
                           position(id: 2, compteId: 1, type: "CRYPTO", qty: 1, pru: 1, valeur: 800),
                           position(id: 3, compteId: 1, type: "STOCK", qty: 1, pru: 1, valeur: 200)]

        let parType = vm.dashboard.byAssetType
        #expect(parType.count == 2, "obtenu : \(parType.map(\.name))")
        #expect(parType[0].name == "CRYPTO", "les plus gros postes d'abord")
        #expect(parType[0].value == 800)
        #expect(parType[1].value == 500, "les deux lignes STOCK doivent se cumuler")
    }

    @Test("L'allocation par compte somme les positions, pas les caches")
    func allocationParCompte() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.accounts = [compte(id: 1, nom: "PEA", valeurCache: 99_999),
                       compte(id: 2, nom: "CTO", valeurCache: 99_999)]
        vm.allPositions = [position(id: 1, compteId: 1, qty: 1, pru: 1, valeur: 1_200),
                           position(id: 2, compteId: 2, qty: 1, pru: 1, valeur: 800)]

        let parCompte = vm.dashboard.byAccount
        #expect(parCompte.first?.name == "PEA")
        #expect(parCompte.first?.value == 1_200, "obtenu : \(parCompte.first?.value ?? -1)")
        #expect(parCompte.last?.value == 800)
    }

    @Test("Un compte sans position apparaît à zéro plutôt que de disparaître")
    func compteVide() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.accounts = [compte(id: 1, nom: "Avec"), compte(id: 2, nom: "Sans")]
        vm.allPositions = [position(id: 1, compteId: 1, qty: 1, pru: 1, valeur: 500)]

        let parCompte = vm.dashboard.byAccount
        #expect(parCompte.count == 2, "un compte vide reste visible dans la répartition")
        #expect(parCompte.first(where: { $0.name == "Sans" })?.value == 0)
    }

    @Test("Un portefeuille vide s'agrège à zéro sans diviser par zéro")
    func portefeuilleVide() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        let d = vm.dashboard
        #expect(d.totalValuation == 0)
        #expect(d.totalInvested == 0)
        #expect(d.performance == 0)
        #expect(d.byAssetType.isEmpty)
    }

    // MARK: - Selection

    @Test("Le compte sélectionné est résolu depuis son identifiant")
    func compteSelectionne() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.accounts = [compte(id: 1, nom: "PEA"), compte(id: 2, nom: "CTO")]

        vm.selectedAccountId = 2
        #expect(vm.selectedAccount?.name == "CTO")

        // A stale id — an account deleted elsewhere — must not crash.
        vm.selectedAccountId = 99
        #expect(vm.selectedAccount == nil)

        vm.selectedAccountId = nil
        #expect(vm.selectedAccount == nil)
    }

    // MARK: - Loading

    @Test("Le chargement sélectionne le premier compte et agrège toutes les positions")
    func chargement() throws {
        let (db, vm, repo) = try fixture()
        defer { db.destroy() }

        let pea = repo.addAccountAndGetId(name: "PEA", broker: "B", currency: "EUR",
                                          accountType: "PEA", openedAt: date("2024-01-01"))!
        let cto = repo.addAccountAndGetId(name: "CTO", broker: "B", currency: "EUR",
                                          accountType: "CTO", openedAt: date("2024-02-01"))!
        for compteId in [pea, cto] {
            _ = repo.addPositionAndGetId(accountId: compteId, assetType: "STOCK",
                                         assetName: "Titre", ticker: "T",
                                         purchaseDate: date("2024-06-01"))
        }

        vm.load()

        #expect(vm.accounts.count == 2)
        #expect(vm.selectedAccountId != nil, "un compte doit être présélectionné à l'ouverture")
        #expect(vm.allPositions.count == 2,
                "allPositions couvre TOUS les comptes, pas seulement le sélectionné")
        #expect(vm.positions.count == 1, "positions ne couvre que le compte sélectionné")
    }

    @Test("Sans compte, le chargement ne sélectionne rien et ne plante pas")
    func chargementSansCompte() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.load()

        #expect(vm.accounts.isEmpty)
        #expect(vm.selectedAccountId == nil)
        #expect(vm.positions.isEmpty)
        #expect(vm.allPositions.isEmpty)
    }
}
