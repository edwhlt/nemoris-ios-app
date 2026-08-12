import Foundation
import Testing
@testable import Nemoris

/// Détection automatique des dépenses et revenus récurrents.
///
/// Ce moteur propose à l'utilisateur de créer des récurrents à partir de son
/// historique. Deux erreurs symétriques y coûtent cher : rater un abonnement
/// évident laisse le budget incomplet, et en inventer un à partir d'achats
/// sans lien pollue le calendrier de prévisions fantômes.
@Suite("RecurringDetector")
struct RecurringDetectorTests {

    private func tx(id: Int, payeeId: Int? = 1, tiers: String = "Netflix",
                    montant: Double = -13.49, jour: String) -> FinanceTransaction {
        FinanceTransaction(id: id, accountId: 1, tiersId: payeeId, categoryId: nil,
                           paymentTypeId: nil, remboursementTiersId: nil,
                           tiersName: tiers, categoryName: "", paymentTypeName: "",
                           remboursementTiersName: "", information: "",
                           libelleBrut: nil, amount: montant, date: date(jour))
    }

    private func motif(frequence: RecurrenceFrequency, ancre: Int? = nil,
                       actif: Bool = true) -> RecurringPattern {
        RecurringPattern(id: 1, name: "Test", amountAvg: -50, amountTolerance: 0.1,
                         categoryId: nil, payeeId: 1, frequency: frequence,
                         anchorDay: ancre, isActive: actif, isManual: false,
                         createdAt: date("2026-01-01"), lastDetectedAt: nil,
                         startDate: date("2026-01-01"), endDate: nil)
    }

    // MARK: - Détection

    @Test("Un abonnement mensuel régulier est détecté")
    func abonnementMensuel() {
        let historique = (0..<6).map { i in
            tx(id: i, jour: "2026-0\(i + 1)-05")
        }

        let candidats = RecurringDetector.detect(from: historique)
        #expect(!candidats.isEmpty, "six prélèvements identiques au même jour du mois")
        let c = candidats[0]
        #expect(c.frequency == .monthly, "fréquence détectée : \(c.frequency.rawValue)")
        #expect(c.anchorDay == 5, "jour d'ancrage : \(c.anchorDay.map(String.init) ?? "aucun")")
        #expect(abs(c.amountAvg - (-13.49)) < 0.5)
    }

    @Test("Une transaction isolée ne devient pas un récurrent")
    func transactionIsolee() {
        let candidats = RecurringDetector.detect(from: [tx(id: 1, jour: "2026-03-14")])
        #expect(candidats.isEmpty, "une occurrence unique ne prouve aucune récurrence")
    }

    @Test("Des achats sans régularité ne produisent pas de candidat")
    func achatsIrreguliers() {
        // Même marchand, mais des dates et des montants sans structure.
        // C'est le faux positif le plus coûteux : il pollue le calendrier.
        let historique = [
            tx(id: 1, tiers: "Carrefour", montant: -12.30, jour: "2026-01-03"),
            tx(id: 2, tiers: "Carrefour", montant: -87.50, jour: "2026-01-19"),
            tx(id: 3, tiers: "Carrefour", montant: -5.10, jour: "2026-02-27"),
            tx(id: 4, tiers: "Carrefour", montant: -143.00, jour: "2026-05-02"),
        ]

        let candidats = RecurringDetector.detect(from: historique)
        let fort = candidats.filter { $0.confidence >= 0.6 }
        #expect(fort.isEmpty, "candidats retenus à tort : \(fort.map(\.name))")
    }

    @Test("Un historique vide ne fait pas planter la détection")
    func historiqueVide() {
        #expect(RecurringDetector.detect(from: []).isEmpty)
    }

    @Test("Les candidats sont triés par confiance décroissante")
    func triParConfiance() {
        var historique = (0..<6).map { i in tx(id: i, jour: "2026-0\(i + 1)-05") }
        historique += (0..<3).map { i in
            tx(id: 100 + i, payeeId: 2, tiers: "Spotify", montant: -9.99,
               jour: "2026-0\(i + 1)-\(17 + i * 2)")
        }

        let candidats = RecurringDetector.detect(from: historique)
        for i in 1..<max(1, candidats.count) {
            #expect(candidats[i - 1].confidence >= candidats[i].confidence,
                    "ordre rompu entre \(i - 1) et \(i)")
        }
    }

    // MARK: - Génération des échéances

    @Test("Un récurrent mensuel engendre une échéance par mois")
    func occurrencesMensuelles() {
        let dates = RecurringDetector.generateOccurrences(
            for: motif(frequence: .monthly, ancre: 5),
            from: date("2026-01-01"), to: date("2026-06-30"))

        #expect(dates.count == 6, "obtenu \(dates.count) : \(dates)")
        for d in dates {
            let jour = Calendar.current.component(.day, from: d)
            #expect(jour == 5, "échéance au \(jour) au lieu du 5")
        }
    }

    @Test("Les échéances restent strictement croissantes")
    func occurrencesCroissantes() {
        for f in RecurrenceFrequency.allCases {
            let dates = RecurringDetector.generateOccurrences(
                for: motif(frequence: f, ancre: 5),
                from: date("2026-01-01"), to: date("2026-04-01"))

            for i in 1..<max(1, dates.count) {
                #expect(dates[i] > dates[i - 1],
                        "\(f.rawValue) : recul entre \(dates[i - 1]) et \(dates[i])")
            }
        }
    }

    @Test("Un récurrent désactivé n'engendre plus rien")
    func recurrentDesactive() {
        let dates = RecurringDetector.generateOccurrences(
            for: motif(frequence: .monthly, ancre: 5, actif: false),
            from: date("2026-01-01"), to: date("2026-12-31"))

        #expect(dates.isEmpty, "un récurrent désactivé ne doit plus remplir le calendrier")
    }

    @Test("Une plage inversée ne produit aucune échéance")
    func plageInversee() {
        let dates = RecurringDetector.generateOccurrences(
            for: motif(frequence: .monthly, ancre: 5),
            from: date("2026-06-01"), to: date("2026-01-01"))

        #expect(dates.isEmpty, "sans ce garde, la génération boucle sans fin")
    }

    @Test("Toutes les échéances tombent dans la plage demandée")
    func occurrencesDansLaPlage() {
        let debut = date("2026-02-01"), fin = date("2026-05-31")
        let dates = RecurringDetector.generateOccurrences(
            for: motif(frequence: .monthly, ancre: 15), from: debut, to: fin)

        #expect(!dates.isEmpty)
        for d in dates {
            #expect(d >= debut && d <= fin, "échéance hors plage : \(d)")
        }
    }

    // MARK: - Rapprochement

    @Test("Le rapprochement accepte l'écart toléré et refuse au-delà")
    func toleranceDeMontant() {
        let m = motif(frequence: .monthly, ancre: 5)   // tolérance 10 %
        let prev = BudgetPrevision(id: 1, recurringPatternId: 1, amount: -100,
                                   expectedDate: date("2026-03-05"), status: .pending,
                                   actualTransactionId: nil, notes: nil)

        #expect(RecurringDetector.matchTransaction(
            tx(id: 1, montant: -105, jour: "2026-03-05"), toPrevision: prev, pattern: m),
                "5 % d'écart est dans la tolérance")

        #expect(!RecurringDetector.matchTransaction(
            tx(id: 2, montant: -140, jour: "2026-03-05"), toPrevision: prev, pattern: m),
                "40 % d'écart doit être refusé")
    }

    @Test("Le rapprochement tolère trois jours d'écart, pas davantage")
    func toleranceDeDate() {
        let m = motif(frequence: .monthly, ancre: 5)
        let prev = BudgetPrevision(id: 1, recurringPatternId: 1, amount: -100,
                                   expectedDate: date("2026-03-05"), status: .pending,
                                   actualTransactionId: nil, notes: nil)

        #expect(RecurringDetector.matchTransaction(
            tx(id: 1, montant: -100, jour: "2026-03-08"), toPrevision: prev, pattern: m))
        #expect(!RecurringDetector.matchTransaction(
            tx(id: 2, montant: -100, jour: "2026-03-20"), toPrevision: prev, pattern: m))
    }
}
