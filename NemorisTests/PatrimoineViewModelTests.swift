import Foundation
import Testing
@testable import Nemoris

/// Agrégats du module patrimoine.
///
/// Le ViewModel compose trois sources — actifs résolus, immobilier, prêts —
/// pour produire les chiffres du hero et du bandeau du tableau de bord. Une
/// erreur d'agrégation y est invisible : un patrimoine net faux reste un
/// montant plausible.
@MainActor
@Suite("PatrimoineViewModel")
struct PatrimoineViewModelTests {

    private func fixture() throws -> (TestDatabase, PatrimoineViewModel, PatrimoineRepository) {
        let db = try TestDatabase()
        return (db, PatrimoineViewModel(store: db.store), PatrimoineRepository(store: db.store))
    }

    private func actif(id: Int, compte: Int? = nil, investissement: Int? = nil,
                       manuel: Double = 0, dernierConnu: Double = 0) -> PatrimoineAsset {
        PatrimoineAsset(id: id, name: "Actif \(id)", assetKind: .savings,
                        linkedAccountId: compte, linkedInvestmentAccountId: investissement,
                        manualValue: manuel, lastKnownValue: dernierConnu,
                        notes: nil, createdAt: date("2026-01-01"))
    }

    private func bien(id: Int, achat: Double, actuel: Double) -> PatrimoineRealEstate {
        PatrimoineRealEstate(id: id, name: "Bien \(id)", purchasePrice: achat,
                             purchaseDate: date("2022-01-01"), currentValue: actuel,
                             estimatedAt: nil, address: nil, notes: nil,
                             createdAt: date("2022-01-01"))
    }

    private func pret(id: Int, principal: Double) -> PatrimoineLoan {
        PatrimoineLoan(id: id, name: "Prêt \(id)", loanType: .amortizing,
                       principal: principal, annualRate: 0.03, durationMonths: 240,
                       deferralMonths: 0, startDate: date("2024-01-01"),
                       insuranceMonthly: 0, linkedRealEstateId: nil, notes: nil,
                       createdAt: date("2024-01-01"))
    }

    // MARK: - Agrégats

    @Test("Le patrimoine net additionne liquide et immobilier, moins les dettes")
    func patrimoineNet() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.assets = [actif(id: 1, manuel: 20_000)]
        vm.resolvedAssetValues = [1: 20_000]
        vm.realEstates = [bien(id: 1, achat: 150_000, actuel: 180_000)]
        vm.loans = [pret(id: 1, principal: 120_000)]

        // Sans état de prêt calculé, le capital initial fait office de filet.
        #expect(vm.snapshot.totalAssets == 200_000)
        #expect(vm.snapshot.totalLiabilities == 120_000)
        #expect(vm.snapshot.netWorth == 80_000)
    }

    @Test("La valeur résolue prime sur la valeur saisie")
    func valeurResoluePrime() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.assets = [actif(id: 1, compte: 10, manuel: 999, dernierConnu: 888)]
        vm.resolvedAssetValues = [1: 4_200]

        #expect(vm.totalAssetsValue == 4_200,
                "le solde réel du compte lié doit primer sur toute valeur figée")
    }

    @Test("La plus-value immobilière compare la valeur actuelle au prix d'achat")
    func plusValueImmobiliere() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.realEstates = [bien(id: 1, achat: 150_000, actuel: 180_000),
                          bien(id: 2, achat: 90_000, actuel: 85_000)]

        // Une moins-value doit se soustraire, pas être ignorée.
        #expect(abs(vm.totalRealEstateCapitalGain - 25_000) < 0.01,
                "plus-value : \(vm.totalRealEstateCapitalGain)")
        #expect(vm.totalRealEstateValue == 265_000)
    }

    // MARK: - Ratio d'endettement

    @Test("Le ratio d'endettement rapporte les dettes au patrimoine brut")
    func ratioEndettement() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.assets = [actif(id: 1, manuel: 100_000)]
        vm.resolvedAssetValues = [1: 100_000]
        vm.loans = [pret(id: 1, principal: 50_000)]

        #expect(abs(vm.leverageRatio - 0.5) < 0.01, "ratio : \(vm.leverageRatio)")
    }

    @Test("Un patrimoine brut nul ne fait pas diverger le ratio")
    func ratioSansPatrimoine() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.loans = [pret(id: 1, principal: 50_000)]

        // Sans garde, la division par zéro remplirait la barre du hero d'infini.
        #expect(vm.leverageRatio == 0, "ratio : \(vm.leverageRatio)")
        #expect(vm.leverageRatio.isFinite)
    }

    @Test("Le ratio est plafonné pour rester affichable")
    func ratioPlafonne() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        // Dette dix fois supérieure au patrimoine : la barre doit rester bornée.
        vm.assets = [actif(id: 1, manuel: 10_000)]
        vm.resolvedAssetValues = [1: 10_000]
        vm.loans = [pret(id: 1, principal: 100_000)]

        #expect(vm.leverageRatio == 2.0, "ratio : \(vm.leverageRatio)")
    }

    // MARK: - Liens

    @Test("Les liens rompus sont signalés pour l'alerte de l'écran")
    func liensRompus() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        #expect(!vm.hasBrokenLinks, "aucun lien rompu au départ")

        vm.brokenLinkAssetIds = [3]
        #expect(vm.hasBrokenLinks,
                "sans ce drapeau, un actif figé sur une vieille valeur passerait inaperçu")
    }

    @Test("Les identifiants de comptes liés sont extraits sans doublon")
    func comptesLies() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.assets = [actif(id: 1, compte: 10), actif(id: 2, compte: 10),
                     actif(id: 3, compte: 20), actif(id: 4, investissement: 7),
                     actif(id: 5, manuel: 100)]

        #expect(vm.linkedBankAccountIds == [10, 20])
        #expect(vm.linkedInvestmentAccountIds == [7])
    }

    // MARK: - Chargement

    @Test("Le chargement remonte ce qui est en base")
    func chargement() throws {
        let (db, vm, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAsset(name: "Livret", assetKind: .savings, linkedAccountId: nil,
                              linkedInvestmentAccountId: nil, manualValue: 8_000,
                              lastKnownValue: 8_000, notes: nil))
        #expect(repo.addRealEstate(name: "Studio", purchasePrice: 150_000,
                                   purchaseDate: date("2022-01-01"), currentValue: 180_000,
                                   estimatedAt: nil, address: nil, notes: nil))

        vm.load()

        #expect(vm.assets.count == 1)
        #expect(vm.realEstates.count == 1)
        #expect(vm.resolvedAssetValues[vm.assets[0].id] == 8_000,
                "la valeur d'un actif sans lien vient de sa saisie manuelle")
    }

    @Test("Un patrimoine vide s'agrège à zéro et se signale comme vide")
    func patrimoineVide() throws {
        let (db, vm, _) = try fixture()
        defer { db.destroy() }

        vm.load()

        #expect(vm.snapshot.netWorth == 0)
        #expect(!vm.snapshot.hasData, "l'écran doit proposer son état vide")
        #expect(!vm.hasBrokenLinks)
    }
}
