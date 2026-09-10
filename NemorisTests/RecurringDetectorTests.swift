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

    @Test("Deux occurrences seules ne suffisent pas : un seul écart ne prouve rien")
    func deuxOccurrencesInsuffisantes() {
        let historique = [
            tx(id: 1, jour: "2026-01-05"),
            tx(id: 2, jour: "2026-02-05"),
        ]
        #expect(RecurringDetector.detect(from: historique).isEmpty,
                "un seul écart ne permet pas de vérifier une périodicité")
    }

    @Test("Un montant qui varie trop rejette le candidat, même à date et tiers identiques")
    func montantVariableRejette() {
        // Même tiers, mêmes jours du mois, mais un montant qui dérive de plus
        // de 8 % — ce n'est pas un "prix identique", donc pas un récurrent.
        let historique = [
            tx(id: 1, montant: -10.00, jour: "2026-01-05"),
            tx(id: 2, montant: -14.00, jour: "2026-02-05"),
            tx(id: 3, montant: -18.00, jour: "2026-03-05"),
        ]
        #expect(RecurringDetector.detect(from: historique).isEmpty,
                "un montant qui dérive de 40 % n'est pas un prix identique")
    }

    @Test("Une date qui dérive trop dans le mois rejette le candidat, même avec des écarts ~mensuels")
    func dateVariableRejette() {
        // Même tiers, même montant, des écarts tous dans la fenêtre "mensuel"
        // (33-36j) — donc la fréquence seule laisserait passer — mais le jour
        // du mois glisse progressivement de 5 à 20 : ce n'est pas la même
        // échéance d'un mois sur l'autre.
        let historique = [
            tx(id: 1, jour: "2026-01-05"),
            tx(id: 2, jour: "2026-02-10"),
            tx(id: 3, jour: "2026-03-15"),
            tx(id: 4, jour: "2026-04-20"),
        ]
        #expect(RecurringDetector.detect(from: historique).isEmpty,
                "un jour du mois qui dérive de 5 à 20 n'est pas une échéance stable")
    }

    @Test("Un écart irrégulier entre occurrences (pas une vraie fréquence) rejette le candidat")
    func ecartsIrreguliersRejettent() {
        // Même tiers, même montant, mais des écarts de 10j puis 90j : aucune
        // fréquence canonique ne couvre les deux à la fois.
        let historique = [
            tx(id: 1, jour: "2026-01-01"),
            tx(id: 2, jour: "2026-01-11"),
            tx(id: 3, jour: "2026-04-11"),
        ]
        #expect(RecurringDetector.detect(from: historique).isEmpty,
                "des écarts de 10j puis 90j ne forment pas une fréquence régulière")
    }

    @Test("Un prélèvement carte qui oscille entre le 7 et le 9 du mois est détecté")
    func prelevementCarteOscillant() {
        // Reproduction d'un retour terrain : même tiers, montant identique
        // (14,71 €), mais le jour de prélèvement carte bancaire oscille entre
        // le 7 et le 9 selon les mois (week-ends, jours fériés bancaires).
        let historique = [
            tx(id: 1, montant: -14.71, jour: "2026-04-08"),
            tx(id: 2, montant: -14.71, jour: "2026-05-07"),
            tx(id: 3, montant: -14.71, jour: "2026-06-09"),
            tx(id: 4, montant: -14.71, jour: "2026-07-08"),
            tx(id: 5, montant: -14.71, jour: "2026-08-07"),
        ]
        let candidats = RecurringDetector.detect(from: historique)
        #expect(!candidats.isEmpty, "5 prélèvements à 14,71€ entre le 7 et le 9 du mois doivent être détectés")
        if let c = candidats.first {
            #expect(c.frequency == .monthly, "fréquence détectée : \(c.frequency.rawValue)")
        }
    }

    @Test("Exactement 3 occurrences (07/06, 07/07, 08/08) au minimum d'occurrences sont détectées")
    func troisOccurrencesPileAuMinimum() {
        // Reproduction du retour terrain exact (correction : 3 occurrences,
        // pas 5) — cas limite car minOccurrences == 3 pile.
        let historique = [
            tx(id: 1, montant: -14.71, jour: "2026-06-07"),
            tx(id: 2, montant: -14.71, jour: "2026-07-07"),
            tx(id: 3, montant: -14.71, jour: "2026-08-08"),
        ]
        let candidats = RecurringDetector.detect(from: historique)
        #expect(!candidats.isEmpty, "3 prélèvements à 14,71€ (07/06, 07/07, 08/08) doivent être détectés")
        if let c = candidats.first {
            #expect(c.frequency == .monthly, "fréquence détectée : \(c.frequency.rawValue)")
            #expect(c.anchorDay == 7, "jour d'ancrage : \(c.anchorDay.map(String.init) ?? "aucun")")
        }
    }

    @Test("Un abonnement bimensuel (toutes les 2 semaines) est détecté comme tel")
    func abonnementBimensuel() {
        let historique = [
            tx(id: 1, jour: "2026-01-02"),
            tx(id: 2, jour: "2026-01-16"),
            tx(id: 3, jour: "2026-01-30"),
            tx(id: 4, jour: "2026-02-13"),
        ]
        let candidats = RecurringDetector.detect(from: historique)
        #expect(!candidats.isEmpty)
        #expect(candidats.first?.frequency == .biweekly,
                "fréquence détectée : \(candidats.first?.frequency.rawValue ?? "aucune")")
    }

    @Test("Un abonnement trimestriel est détecté comme tel, pas comme mensuel")
    func abonnementTrimestriel() {
        let historique = [
            tx(id: 1, jour: "2026-01-10"),
            tx(id: 2, jour: "2026-04-10"),
            tx(id: 3, jour: "2026-07-10"),
            tx(id: 4, jour: "2026-10-10"),
        ]
        let candidats = RecurringDetector.detect(from: historique)
        #expect(!candidats.isEmpty)
        #expect(candidats.first?.frequency == .quarterly,
                "fréquence détectée : \(candidats.first?.frequency.rawValue ?? "aucune")")
    }

    @Test("Un abonnement semestriel est détecté comme tel")
    func abonnementSemestriel() {
        let historique = [
            tx(id: 1, jour: "2026-01-15"),
            tx(id: 2, jour: "2026-07-15"),
            tx(id: 3, jour: "2027-01-15"),
        ]
        let candidats = RecurringDetector.detect(from: historique)
        #expect(!candidats.isEmpty)
        #expect(candidats.first?.frequency == .semiannual,
                "fréquence détectée : \(candidats.first?.frequency.rawValue ?? "aucune")")
    }

    @Test("Un prélèvement calé sur la fin du mois reste stable malgré les mois courts")
    func finDeMoisStable() {
        // 31, 28 (février), 31, 30 : c'est la même échéance "fin de mois",
        // pas une dérive de date.
        let historique = [
            tx(id: 1, jour: "2026-01-31"),
            tx(id: 2, jour: "2026-02-28"),
            tx(id: 3, jour: "2026-03-31"),
            tx(id: 4, jour: "2026-04-30"),
        ]
        let candidats = RecurringDetector.detect(from: historique)
        #expect(!candidats.isEmpty, "une échéance de fin de mois doit rester reconnue malgré les mois courts")
        #expect(candidats.first?.frequency == .monthly)
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

    // MARK: - Motif déjà existant ("Déjà suivi")

    @Test("Un candidat est lié à un motif existant par payee, ou à défaut par nom")
    func existingMatchParPayeeOuNom() {
        let historique = (0..<3).map { i in tx(id: i, jour: "2026-0\(i + 1)-05") }
        guard let candidat = RecurringDetector.detect(from: historique).first else {
            Issue.record("candidat attendu")
            return
        }

        #expect(candidat.existingMatch(in: []) == nil, "aucun motif existant : pas de lien")

        let memePayee = motif(frequence: .yearly) // payeeId 1, différent de tout sauf le payee
        #expect(candidat.existingMatch(in: [memePayee]) != nil,
                "même payeeId ⇒ lié, même si la fréquence stockée diffère")

        let memeNomAutrePayee = RecurringPattern(
            id: 2, name: candidat.name, amountAvg: -1, amountTolerance: 0.1,
            categoryId: nil, payeeId: 999, frequency: .monthly, anchorDay: nil,
            isActive: false, isManual: true, createdAt: date("2026-01-01"),
            lastDetectedAt: nil, startDate: date("2026-01-01"), endDate: nil
        )
        #expect(candidat.existingMatch(in: [memeNomAutrePayee]) != nil,
                "payeeId absent du candidat ou différent ⇒ repli sur le nom, motif inactif compris")

        let autre = RecurringPattern(
            id: 3, name: "Autre tiers", amountAvg: -1, amountTolerance: 0.1,
            categoryId: nil, payeeId: 999, frequency: .monthly, anchorDay: nil,
            isActive: true, isManual: true, createdAt: date("2026-01-01"),
            lastDetectedAt: nil, startDate: date("2026-01-01"), endDate: nil
        )
        #expect(candidat.existingMatch(in: [autre]) == nil, "ni payee ni nom en commun ⇒ pas de lien")
    }

    @Test("Un montant qui a dérivé de plus de 1% est signalé, une différence minime ne l'est pas")
    func differsFromDetecteLaDerive() {
        let historique = (0..<3).map { i in
            tx(id: i, montant: -15.09, jour: "2026-0\(i + 1)-05")
        }
        guard let candidat = RecurringDetector.detect(from: historique).first else {
            Issue.record("candidat attendu")
            return
        }
        #expect(abs(candidat.amountAvg - (-15.09)) < 0.01)

        let motifADerive = motif(frequence: .monthly, ancre: 5) // amountAvg -50, très différent de -15.09
        #expect(candidat.differsFrom(motifADerive), "14,71€ → 15,09€ (retour terrain) : écart réel, doit être signalé")

        let motifAJour = RecurringPattern(
            id: 4, name: candidat.name, amountAvg: -15.09, amountTolerance: 0.1,
            categoryId: nil, payeeId: 1, frequency: .monthly, anchorDay: 5,
            isActive: true, isManual: false, createdAt: date("2026-01-01"),
            lastDetectedAt: nil, startDate: date("2026-01-01"), endDate: nil
        )
        #expect(!candidat.differsFrom(motifAJour), "montant/fréquence/ancrage identiques ⇒ rien à mettre à jour")

        let motifPresqueIdentique = RecurringPattern(
            id: 5, name: candidat.name, amountAvg: -15.10, amountTolerance: 0.1,
            categoryId: nil, payeeId: 1, frequency: .monthly, anchorDay: 5,
            isActive: true, isManual: false, createdAt: date("2026-01-01"),
            lastDetectedAt: nil, startDate: date("2026-01-01"), endDate: nil
        )
        #expect(!candidat.differsFrom(motifPresqueIdentique), "1 centime d'écart est du bruit, pas une dérive")

        let mergedPattern = candidat.updating(motifADerive)
        #expect(mergedPattern.id == motifADerive.id, "l'id du motif existant est préservé (mise à jour, pas création)")
        #expect(abs(mergedPattern.amountAvg - candidat.amountAvg) < 0.001, "le montant vient du candidat fraîchement détecté")
        #expect(mergedPattern.categoryId == motifADerive.categoryId, "la config du motif existant (catégorie…) est préservée")
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
