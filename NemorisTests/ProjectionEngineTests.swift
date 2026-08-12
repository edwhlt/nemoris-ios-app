import Foundation
import Testing
@testable import Nemoris

/// Projection du patrimoine net mois par mois.
///
/// Ce moteur produit une courbe sur cinq ans à partir d'hypothèses. Une erreur
/// n'y est jamais visible : une trajectoire fausse reste une trajectoire
/// crédible. Les tests portent donc sur les propriétés de la courbe et sur les
/// relations entre scénarios, pas sur des valeurs qu'il faudrait recalculer.
@Suite("ProjectionEngine")
struct ProjectionEngineTests {

    private let depart = date("2026-01-01")

    private func patrimoine(actifs: Double, dettes: Double) -> PatrimoineSnapshot {
        PatrimoineSnapshot(totalAssets: actifs, totalLiabilities: dettes,
                           assetsCount: 1, realEstateCount: 0, loansCount: 0)
    }

    private func pret(principal: Double = 100_000, taux: Double = 0.03,
                      mois: Int = 240) -> PatrimoineLoan {
        PatrimoineLoan(id: 1, name: "Crédit", loanType: .amortizing, principal: principal,
                       annualRate: taux, durationMonths: mois, deferralMonths: 0,
                       startDate: depart, insuranceMonthly: 0,
                       linkedRealEstateId: nil, notes: nil, createdAt: depart)
    }

    private func projette(liquide: Double = 20_000, immobilier: Double = 0,
                          prets: [PatrimoineLoan] = [], flux: Double = 500,
                          scenario: ProjectionScenario = .conservative,
                          mois: Int = 60) -> [ProjectionPoint] {
        ProjectionEngine.project(
            snapshot: patrimoine(actifs: liquide + immobilier,
                                 dettes: prets.reduce(0) { $0 + $1.principal }),
            totalAssetsLiquid: liquide, realEstateValue: immobilier,
            loans: prets, netMonthlyCashFlow: flux, scenario: scenario,
            months: mois, startDate: depart)
    }

    // MARK: - Forme de la courbe

    @Test("La projection produit un point par mois, plus le point de départ")
    func nombreDePoints() {
        let points = projette(mois: 60)
        #expect(points.count == 61, "obtenu : \(points.count)")
        #expect(points.first?.date == depart, "le premier point est aujourd'hui")
    }

    @Test("Les dates avancent d'un mois et restent strictement croissantes")
    func datesCroissantes() {
        let points = projette(mois: 12)
        for i in 1..<points.count {
            #expect(points[i].date > points[i - 1].date,
                    "recul ou stagnation au point \(i)")
        }
    }

    @Test("Le patrimoine net est toujours actifs moins dettes")
    func coherenceInterne() {
        let points = projette(liquide: 30_000, immobilier: 200_000, prets: [pret()])
        for (i, p) in points.enumerated() {
            #expect(abs(p.netWorth - (p.totalAssets - p.totalLiabilities)) < 0.01,
                    "au point \(i) : \(p.totalAssets) − \(p.totalLiabilities) ≠ \(p.netWorth)")
        }
    }

    @Test("Une projection sur zéro mois rend le seul point de départ")
    func projectionVide() {
        let points = projette(mois: 0)
        #expect(points.count == 1)
    }

    // MARK: - Effet des entrées

    @Test("Un flux mensuel positif fait croître le patrimoine")
    func fluxPositif() {
        let points = projette(liquide: 10_000, flux: 800)
        #expect(points.last!.netWorth > points.first!.netWorth,
                "\(points.first!.netWorth) → \(points.last!.netWorth)")
    }

    @Test("Un flux mensuel négatif le fait décroître")
    func fluxNegatif() {
        // Vivre au-dessus de ses moyens doit se voir sur la courbe. Un moteur
        // qui ne saurait que monter serait rassurant et faux.
        let points = projette(liquide: 50_000, flux: -900, scenario: .conservative)
        #expect(points.last!.netWorth < points.first!.netWorth,
                "\(points.first!.netWorth) → \(points.last!.netWorth)")
    }

    @Test("La dette d'un prêt amortissable décroît sur toute la projection")
    func detteDecroissante() {
        let points = projette(liquide: 0, prets: [pret()], flux: 0)
        var precedent = Double.infinity
        for (i, p) in points.enumerated() {
            #expect(p.totalLiabilities <= precedent + 0.01,
                    "la dette remonte au point \(i)")
            #expect(p.totalLiabilities >= -0.01, "dette négative au point \(i)")
            precedent = p.totalLiabilities
        }
        #expect(points.last!.totalLiabilities < points.first!.totalLiabilities)
    }

    @Test("L'immobilier est tenu constant, conformément à l'hypothèse assumée")
    func immobilierConstant() {
        // Le moteur documente qu'il n'extrapole aucune plus-value immobilière.
        // Sans flux ni rendement, les actifs ne doivent donc pas bouger.
        let points = ProjectionEngine.project(
            snapshot: patrimoine(actifs: 300_000, dettes: 0),
            totalAssetsLiquid: 0, realEstateValue: 300_000,
            loans: [], netMonthlyCashFlow: 0, scenario: .conservative,
            months: 60, startDate: depart)

        #expect(abs(points.last!.totalAssets - points.first!.totalAssets) < 0.01,
                "\(points.first!.totalAssets) → \(points.last!.totalAssets)")
    }

    // MARK: - Relations entre scénarios

    @Test("Le scénario d'épargne renforcée dépasse le statu quo")
    func optimismeSuperieur() {
        let prudent = projette(scenario: .conservative)
        let ambitieux = projette(scenario: .optimistic)

        #expect(ambitieux.last!.netWorth > prudent.last!.netWorth,
                "prudent \(prudent.last!.netWorth) vs ambitieux \(ambitieux.last!.netWorth)")
    }

    @Test("Le remboursement accéléré laisse moins de dette")
    func accelerationDeDette() {
        let prudent = projette(liquide: 50_000, prets: [pret()], scenario: .conservative)
        let accelere = projette(liquide: 50_000, prets: [pret()], scenario: .accelerated)

        #expect(accelere.last!.totalLiabilities <= prudent.last!.totalLiabilities,
                "prudent \(prudent.last!.totalLiabilities) vs accéléré \(accelere.last!.totalLiabilities)")
    }

    @Test("Aucun scénario ne produit de valeur non finie")
    func valeursFinies() {
        for scenario in ProjectionScenario.allCases {
            let points = projette(liquide: 25_000, immobilier: 150_000,
                                  prets: [pret()], flux: 600, scenario: scenario)
            for (i, p) in points.enumerated() {
                #expect(p.netWorth.isFinite && p.totalAssets.isFinite && p.totalLiabilities.isFinite,
                        "\(scenario.rawValue) au point \(i)")
            }
        }
    }

    @Test("Un patrimoine vide ne fait pas diverger la projection")
    func patrimoineVide() {
        let points = ProjectionEngine.project(
            snapshot: .empty, totalAssetsLiquid: 0, realEstateValue: 0,
            loans: [], netMonthlyCashFlow: 0, scenario: .conservative,
            months: 24, startDate: depart)

        #expect(points.count == 25)
        #expect(points.allSatisfy { $0.netWorth.isFinite })
        #expect(abs(points.last!.netWorth) < 0.01, "rien n'entre, rien ne sort")
    }
}
