import Foundation
import Testing
@testable import Nemoris

/// Matching a real transaction against a budget forecast.
///
/// This engine decides on its own, above 0.60 confidence. A mistake
/// produces no message: it marks a due date as honored when
/// it isn't, or the reverse — and the displayed budget becomes wrong
/// with nothing signaling it.
@Suite("TransactionMatcher")
struct TransactionMatcherTests {

    private func transaction(id: Int = 1, tiersId: Int? = nil, tiers: String = "",
                             libelle: String? = nil, montant: Double = -50,
                             jour: String = "2026-03-10") -> FinanceTransaction {
        FinanceTransaction(id: id, accountId: 1, tiersId: tiersId, categoryId: nil,
                           paymentTypeId: nil, remboursementTiersId: nil,
                           tiersName: tiers, categoryName: "", paymentTypeName: "",
                           remboursementTiersName: "", information: "",
                           libelleBrut: libelle, amount: montant, date: date(jour))
    }

    private func prevision(id: Int = 1, patternId: Int = 1, montant: Double = -50,
                           jour: String = "2026-03-10",
                           statut: PrevisionStatus = .pending) -> BudgetPrevision {
        BudgetPrevision(id: id, recurringPatternId: patternId, amount: montant,
                        expectedDate: date(jour), status: statut,
                        actualTransactionId: nil, notes: nil)
    }

    private func motif(id: Int = 1, nom: String = "Netflix", payeeId: Int? = nil,
                       montant: Double = -50, tolerance: Double = 5) -> RecurringPattern {
        RecurringPattern(id: id, name: nom, amountAvg: montant, amountTolerance: tolerance,
                         categoryId: nil, payeeId: payeeId, frequency: .monthly,
                         anchorDay: 10, isActive: true, isManual: false,
                         createdAt: date("2026-01-01"), lastDetectedAt: nil,
                         startDate: date("2026-01-01"), endDate: nil)
    }

    // MARK: - Label normalization

    @Test("Les mots bancaires parasites disparaissent du libellé")
    func normalisationMotsBancaires() {
        let normalise = TransactionMatcher.normalizeLabel("PRLV SEPA NETFLIX EUR")
        #expect(normalise.contains("netflix"))
        #expect(!normalise.contains("prlv"))
        #expect(!normalise.contains("sepa"))
        #expect(!normalise.contains("eur"))
    }

    @Test("Les jetons purement numériques sont écartés")
    func normalisationChiffres() {
        // Card numbers and references vary from one month to the next:
        // keeping them would tank the similarity between two withdrawals
        // that are actually identical.
        let a = TransactionMatcher.normalizeLabel("CB SPOTIFY 4567 12345678")
        let b = TransactionMatcher.normalizeLabel("CB SPOTIFY 8901 87654321")
        #expect(a == b, "« \(a) » vs « \(b) »")
    }

    @Test("Un libellé sans contenu significatif se normalise à vide")
    func normalisationVide() {
        #expect(TransactionMatcher.normalizeLabel("VIR SEPA 12345 EUR").isEmpty)
    }

    // MARK: - Similarity

    @Test("Deux libellés identiques ont une similarité maximale, deux étrangers une nulle")
    func similariteBornes() {
        #expect(TransactionMatcher.labelSimilarity("netflix", "netflix") == 1.0)
        #expect(TransactionMatcher.labelSimilarity("netflix", "carrefour") == 0.0)
        #expect(TransactionMatcher.labelSimilarity("", "netflix") == 0.0,
                "un libellé vide ne ressemble à rien, il ne doit pas valoir 1")
    }

    @Test("Une sous-chaîne est reconnue comme une ressemblance")
    func similariteSousChaine() {
        // "netflix" inside "netflixcom": the same merchant written differently.
        let s = TransactionMatcher.labelSimilarity("netflix", "netflixcom")
        #expect(s > 0, "similarité : \(s)")
        #expect(s <= 1.0, "la similarité ne doit jamais dépasser 1")
    }

    // MARK: - Choosing the label

    @Test("Le nom du tiers prime sur le libellé brut")
    func choixDuLibelle() {
        #expect(TransactionMatcher.bestLabel(
            transaction(tiers: "Netflix", libelle: "PRLV SEPA NFLX 998877")) == "Netflix")

        // With no resolved payee, we fall back to the raw label rather than nothing.
        #expect(TransactionMatcher.bestLabel(
            transaction(tiers: "", libelle: "PRLV SEPA NFLX")) == "PRLV SEPA NFLX")
    }

    // MARK: - Rapprochement

    @Test("Un tiers identique et une date exacte donnent une confiance élevée")
    func rapprochementEvident() {
        let candidat = TransactionMatcher.findBestMatch(
            for: transaction(tiersId: 7, tiers: "Netflix", montant: -50, jour: "2026-03-10"),
            in: [prevision()],
            patterns: [motif(payeeId: 7)])

        #expect(candidat != nil)
        #expect((candidat?.confidence ?? 0) >= TransactionMatcher.autoAcceptThreshold,
                "confiance : \(candidat?.confidence ?? 0)")
    }

    @Test("Une transaction sans rapport n'est pas rapprochée")
    func rapprochementRefuse() {
        let candidat = TransactionMatcher.findBestMatch(
            for: transaction(tiersId: 99, tiers: "Carrefour", montant: -230, jour: "2026-07-22"),
            in: [prevision()],
            patterns: [motif(payeeId: 7)])

        #expect(candidat == nil, "confiance obtenue : \(candidat?.confidence ?? 0)")
    }

    @Test("Une prévision sans récurrent connu est ignorée")
    func previsionOrpheline() {
        // A real case: the recurring pattern was deleted but the forecast remains.
        // Matching it would make no sense, with no reference to compare against.
        let candidat = TransactionMatcher.findBestMatch(
            for: transaction(tiersId: 7, tiers: "Netflix"),
            in: [prevision(patternId: 42)],
            patterns: [motif(id: 1, payeeId: 7)])

        #expect(candidat == nil)
    }

    @Test("Une date éloignée fait chuter la confiance sous le seuil")
    func effetDeLaDate() {
        let proche = TransactionMatcher.findBestMatch(
            for: transaction(tiers: "Netflix", jour: "2026-03-11"),
            in: [prevision(jour: "2026-03-10")], patterns: [motif()])
        let lointain = TransactionMatcher.findBestMatch(
            for: transaction(tiers: "Netflix", jour: "2026-05-25"),
            in: [prevision(jour: "2026-03-10")], patterns: [motif()])

        #expect((proche?.confidence ?? 0) > (lointain?.confidence ?? 0),
                "proche \(proche?.confidence ?? 0) vs lointain \(lointain?.confidence ?? 0)")
    }

    // MARK: - Rapprochement automatique

    @Test("Une prévision déjà rapprochée n'est pas reprise par une autre transaction")
    func pasDeDoubleRapprochement() {
        let previsions = [prevision(id: 1)]
        let paires = TransactionMatcher.autoMatch(
            transactions: [transaction(id: 10, tiersId: 7, tiers: "Netflix"),
                           transaction(id: 11, tiersId: 7, tiers: "Netflix")],
            previsions: previsions,
            patterns: [motif(payeeId: 7)])

        #expect(paires.count == 1,
                "deux transactions ne peuvent pas honorer la même échéance")
    }

    @Test("Seules les prévisions en attente sont candidates")
    func seulementLesEnAttente() {
        let paires = TransactionMatcher.autoMatch(
            transactions: [transaction(tiersId: 7, tiers: "Netflix")],
            previsions: [prevision(statut: .matched), prevision(id: 2, statut: .skipped)],
            patterns: [motif(payeeId: 7)])

        #expect(paires.isEmpty,
                "une échéance déjà honorée ou ignorée ne doit pas être reprise")
    }

    @Test("Le rapprochement automatique est déterministe")
    func deterministe() {
        let txs = [transaction(id: 3, tiersId: 7, tiers: "Netflix", jour: "2026-03-12"),
                   transaction(id: 1, tiersId: 7, tiers: "Netflix", jour: "2026-03-09"),
                   transaction(id: 2, tiersId: 7, tiers: "Netflix", jour: "2026-03-10")]
        let previsions = [prevision(id: 1)]

        // The input order must not change the result: the engine sorts by
        // date. Without this sort, two runs on the same database could
        // match different transactions.
        let premier = TransactionMatcher.autoMatch(transactions: txs, previsions: previsions,
                                                   patterns: [motif(payeeId: 7)])
        let second = TransactionMatcher.autoMatch(transactions: txs.reversed(),
                                                  previsions: previsions,
                                                  patterns: [motif(payeeId: 7)])

        #expect(premier.map(\.transactionId) == second.map(\.transactionId),
                "\(premier.map(\.transactionId)) vs \(second.map(\.transactionId))")
    }
}
