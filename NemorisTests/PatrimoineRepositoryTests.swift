import Foundation
import Testing
@testable import Nemoris

/// Le patrimoine porte trois entités indépendantes — biens, prêts, actifs —
/// reliées entre elles et au reste de l'application par des liens optionnels.
@Suite("PatrimoineRepository")
struct PatrimoineRepositoryTests {

    private func fixture() throws -> (TestDatabase, PatrimoineRepository) {
        let db = try TestDatabase()
        return (db, PatrimoineRepository(store: db.store))
    }

    // MARK: - Biens immobiliers

    @Test("Un bien créé est relu avec sa valorisation et ses champs optionnels")
    func bienAllerRetour() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addRealEstate(name: "Studio Lyon", purchasePrice: 180_000,
                                   purchaseDate: date("2021-09-15"), currentValue: 205_000,
                                   estimatedAt: date("2026-01-10"),
                                   address: "12 rue de la Part-Dieu", notes: "locataire en place"))

        let biens = repo.fetchRealEstate()
        #expect(biens.count == 1)
        let b = biens[0]
        #expect(b.name == "Studio Lyon")
        #expect(b.purchasePrice == 180_000)
        #expect(b.currentValue == 205_000)
        #expect(b.address == "12 rue de la Part-Dieu")
        #expect(b.estimatedAt != nil)
    }

    @Test("Un bien sans adresse ni note garde ces champs nuls")
    func bienChampsOptionnels() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addRealEstate(name: "Terrain", purchasePrice: 40_000,
                                   purchaseDate: date("2020-01-01"), currentValue: 45_000,
                                   estimatedAt: nil, address: nil, notes: nil))

        let b = repo.fetchRealEstate()[0]
        #expect(b.estimatedAt == nil)
        #expect(b.address == nil, "une adresse absente ne doit pas devenir une chaîne vide")
        #expect(b.notes == nil)
    }

    // MARK: - Prêts

    @Test("Chaque type de prêt fait l'aller-retour sans se dénaturer")
    func typesDePret() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        for type in LoanType.allCases {
            #expect(repo.addLoan(name: type.rawValue, loanType: type, principal: 100_000,
                                 annualRate: 0.034, durationMonths: 240, deferralMonths: 0,
                                 startDate: date("2024-01-01"), insuranceMonthly: 25,
                                 linkedRealEstateId: nil, notes: nil))
        }

        let relus = Dictionary(uniqueKeysWithValues: repo.fetchLoans().map { ($0.name, $0.loanType) })
        for type in LoanType.allCases {
            #expect(relus[type.rawValue] == type, "\(type.rawValue) relu incorrectement")
        }
    }

    @Test("Le taux et la durée traversent la base sans perte de précision")
    func precisionDuPret() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addLoan(name: "Prêt principal", loanType: .amortizing, principal: 217_500,
                             annualRate: 0.0349, durationMonths: 279, deferralMonths: 6,
                             startDate: date("2023-11-01"), insuranceMonthly: 31.42,
                             linkedRealEstateId: nil, notes: nil))

        let p = repo.fetchLoans()[0]
        #expect(p.principal == 217_500)
        #expect(p.annualRate == 0.0349, "un taux arrondi fausserait tout l'échéancier")
        #expect(p.durationMonths == 279)
        #expect(p.deferralMonths == 6)
    }

    @Test("Un prêt peut être rattaché à un bien")
    func pretLieAUnBien() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addRealEstate(name: "Maison", purchasePrice: 300_000,
                                   purchaseDate: date("2022-05-01"), currentValue: 320_000,
                                   estimatedAt: nil, address: nil, notes: nil))
        let bien = repo.fetchRealEstate()[0]

        #expect(repo.addLoan(name: "Crédit maison", loanType: .amortizing, principal: 240_000,
                             annualRate: 0.031, durationMonths: 300, deferralMonths: 0,
                             startDate: date("2022-05-01"), insuranceMonthly: 40,
                             linkedRealEstateId: bien.id, notes: nil))

        #expect(repo.fetchLoans()[0].linkedRealEstateId == bien.id)
    }

    // MARK: - Actifs

    @Test("Chaque nature d'actif fait l'aller-retour")
    func naturesDActif() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        for kind in AssetKind.allCases {
            #expect(repo.addAsset(name: kind.rawValue, assetKind: kind, linkedAccountId: nil,
                                  linkedInvestmentAccountId: nil, manualValue: 1_000,
                                  lastKnownValue: 1_000, notes: nil))
        }

        let relus = Dictionary(uniqueKeysWithValues: repo.fetchAssets().map { ($0.name, $0.assetKind) })
        for kind in AssetKind.allCases {
            #expect(relus[kind.rawValue] == kind)
        }
    }

    @Test("La dernière valeur connue se met à jour sans toucher au reste")
    func majDerniereValeur() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addAsset(name: "Livret A", assetKind: .savings, linkedAccountId: nil,
                              linkedInvestmentAccountId: nil, manualValue: 8_000,
                              lastKnownValue: 8_000, notes: "plafond atteint"))
        let actif = repo.fetchAssets()[0]

        #expect(repo.updateLastKnownValue(assetId: actif.id, value: 8_450))

        let relu = repo.fetchAssets()[0]
        #expect(relu.lastKnownValue == 8_450)
        #expect(relu.manualValue == 8_000, "la valeur saisie manuellement n'est pas écrasée")
        #expect(relu.notes == "plafond atteint")
    }

    @Test("On retrouve l'actif rattaché à un compte, et lui seul")
    func actifLieAUnCompte() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }
        let comptes = TransactionRepository(store: db.store)

        #expect(comptes.addAccount(name: "Livret", type: "EPARGNE"))
        let compte = comptes.fetchAccounts()[0]

        #expect(repo.addAsset(name: "Lié", assetKind: .savings, linkedAccountId: compte.id,
                              linkedInvestmentAccountId: nil, manualValue: 0,
                              lastKnownValue: 5_000, notes: nil))
        #expect(repo.addAsset(name: "Libre", assetKind: .cash, linkedAccountId: nil,
                              linkedInvestmentAccountId: nil, manualValue: 300,
                              lastKnownValue: 300, notes: nil))

        let lie = repo.fetchAssets().first { $0.name == "Lié" }!
        #expect(repo.assetIdLinkedTo(accountId: compte.id, investmentAccountId: nil,
                                     excludingAssetId: nil) == lie.id)

        // En s'excluant soi-même, plus rien ne répond : c'est ce qui permet de
        // vérifier qu'un compte n'est pas déjà pris lors d'une modification.
        #expect(repo.assetIdLinkedTo(accountId: compte.id, investmentAccountId: nil,
                                     excludingAssetId: lie.id) == nil)
        #expect(repo.assetIdLinkedTo(accountId: 999_999, investmentAccountId: nil,
                                     excludingAssetId: nil) == nil)
    }

    // MARK: - Suppressions

    @Test("Les trois entités se suppriment indépendamment")
    func suppressionsIndependantes() throws {
        let (db, repo) = try fixture()
        defer { db.destroy() }

        #expect(repo.addRealEstate(name: "Bien", purchasePrice: 1, purchaseDate: date("2024-01-01"),
                                   currentValue: 1, estimatedAt: nil, address: nil, notes: nil))
        #expect(repo.addLoan(name: "Prêt", loanType: .amortizing, principal: 1, annualRate: 0.01,
                             durationMonths: 12, deferralMonths: 0, startDate: date("2024-01-01"),
                             insuranceMonthly: 0, linkedRealEstateId: nil, notes: nil))
        #expect(repo.addAsset(name: "Actif", assetKind: .cash, linkedAccountId: nil,
                              linkedInvestmentAccountId: nil, manualValue: 1,
                              lastKnownValue: 1, notes: nil))

        #expect(repo.deleteAsset(id: repo.fetchAssets()[0].id))
        #expect(repo.fetchAssets().isEmpty)
        #expect(repo.fetchLoans().count == 1, "les autres entités ne bougent pas")
        #expect(repo.fetchRealEstate().count == 1)
    }
}
