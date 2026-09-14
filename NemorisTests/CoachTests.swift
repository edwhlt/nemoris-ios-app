import Foundation
import Testing
@testable import Nemoris

/// The AI coach: ranking recommendations, reading the model's
/// response, and building the briefings sent to it.
///
/// What these tests protect above all: the coach is expensive (one model
/// call per analysis) and isn't reproducible. Everything that CAN be
/// decided without it — priority, parsing tolerance, briefing content — must
/// therefore be decided here, once and for all.
@Suite("Coach")
struct CoachTests {

    // MARK: - Fabriques

    private func reco(_ ref: String, impact: Double = 0, effort: Int = 3,
                      confidence: Double = 0.8, domain: CoachDomain = .transactions,
                      status: CoachRecommendationStatus = .new, id: Int = 0) -> CoachRecommendation {
        CoachRecommendation(id: id == 0 ? abs(ref.hashValue % 100_000) : id,
                            domain: domain, ref: ref, title: ref, detail: "",
                            rationale: nil, category: nil, annualImpact: impact,
                            effort: effort, confidence: confidence, status: status,
                            generatedAt: date("2026-08-01"))
    }

    private func tx(id: Int, montant: Double, jour: String,
                    categoryId: Int? = nil, tiersId: Int? = nil,
                    tiers: String = "Marchand") -> FinanceTransaction {
        FinanceTransaction(id: id, accountId: 1, tiersId: tiersId, categoryId: categoryId,
                           paymentTypeId: nil, remboursementTiersId: nil,
                           tiersName: tiers, categoryName: "", paymentTypeName: "",
                           remboursementTiersName: "", information: "",
                           libelleBrut: nil, amount: montant, date: date(jour))
    }

    // MARK: - Arbitrage

    @Test("Une recommandation non chiffrable reste dans la course")
    func impactNonChiffrableNeTombePasAZero() {
        // A direct regression of `Insight.compositeScore`, which MULTIPLIED the
        // three dimensions: any insight with zero impact was worth 0 and never
        // surfaced — even though "you're at 70% on a single line item"
        // is exactly the structuring advice a consultant would highlight.
        let structurel = reco("concentration", impact: 0, effort: 2, confidence: 0.95)
        #expect(CoachRanker.score(structurel) > 0.3,
                "score obtenu : \(CoachRanker.score(structurel))")
    }

    @Test("Un impact plus élevé prime, mais l'échelle sature")
    func impactLogarithmique() {
        let petit = CoachRanker.impactScore(20)
        let moyen = CoachRanker.impactScore(200)
        let gros = CoachRanker.impactScore(2_000)
        #expect(petit < moyen && moyen < gros)
        // Beyond the ceiling, two "huge" amounts must no longer be
        // distinguished by amount alone.
        #expect(CoachRanker.impactScore(50_000) == 1.0)
        #expect(CoachRanker.impactScore(3_000) == 1.0)
    }

    @Test("Le classement mélange les domaines et écarte ce qui est traité")
    func topToutDomaine() {
        let items = [
            reco("a", impact: 1_200, domain: .transactions, id: 1),
            reco("b", impact: 40, domain: .investments, id: 2),
            reco("c", impact: 5_000, domain: .investments, status: .dismissed, id: 3),
            reco("d", impact: 3_000, domain: .transactions, status: .done, id: 4),
            reco("e", impact: 600, domain: .investments, id: 5),
        ]
        let top = CoachRanker.topAcrossDomains(items, limit: 3)
        #expect(top.map(\.ref) == ["a", "e", "b"], "obtenu : \(top.map(\.ref))")
        #expect(!top.contains { $0.ref == "c" }, "une recommandation écartée ne doit jamais remonter")
        #expect(!top.contains { $0.ref == "d" }, "une recommandation faite ne doit jamais remonter")
    }

    @Test("Le classement est stable d'un affichage à l'autre")
    func classementStable() {
        // Two strictly equivalent recommendations must not swap order
        // from one render to the next — otherwise the screen "moves on its own".
        let items = [reco("zebre", impact: 100, id: 1), reco("alpha", impact: 100, id: 2)]
        #expect(CoachRanker.ranked(items).map(\.ref) == CoachRanker.ranked(items.reversed()).map(\.ref))
    }

    @Test("Les valeurs aberrantes du modèle sont ramenées dans leurs bornes")
    func normalisation() {
        // A model will happily return an out-of-range effort or a confidence
        // expressed as a percentage. Without normalization, these values contaminate the ranking.
        let a = CoachRanker.normalize(annualImpact: -50, effort: 12, confidence: 85)
        #expect(a.annualImpact == 0, "un impact négatif n'a pas de sens ici")
        #expect(a.effort == 5)
        #expect(abs(a.confidence - 0.85) < 0.001, "« 85 » doit être lu comme 85 %")

        let b = CoachRanker.normalize(annualImpact: .nan, effort: 0, confidence: .infinity)
        #expect(b.annualImpact == 0 && b.effort == 1 && b.confidence <= 1)
    }

    // MARK: - Reading the model's response

    @Test("Une réponse bien formée est lue intégralement")
    func parseNominal() {
        let raw = """
        {"profile":"Tu épargnes irrégulièrement.","recommendations":[
          {"key":"abo_streaming","title":"Résilier Netflix","detail":"Non utilisé.","rationale":"13,49 €/mois depuis 5 mois.","category":"Abonnements","annual_impact":161.88,"effort":5,"confidence":0.9}
        ]}
        """
        let result = CoachResponseParser.parse(raw)
        #expect(result.profileSummary == "Tu épargnes irrégulièrement.")
        #expect(result.drafts.count == 1)
        #expect(result.drafts.first?.ref == "abo_streaming")
        #expect(abs((result.drafts.first?.annualImpact ?? 0) - 161.88) < 0.01)
    }

    @Test("Le markdown et le bavardage autour du JSON n'empêchent pas la lecture")
    func parseAvecFences() {
        let raw = """
        Voici mon analyse :
        ```json
        {"profile":"OK","recommendations":[{"key":"x","title":"T","detail":"D","annual_impact":10,"effort":3,"confidence":0.5}]}
        ```
        """
        #expect(CoachResponseParser.parse(raw).drafts.count == 1)
    }

    @Test("Une ligne mal formée ne fait pas perdre les autres")
    func parseTolerant() {
        // This is the same class of bug already paid for on document import: a
        // missing key caused the entire page to be discarded.
        let raw = """
        {"recommendations":[
          {"title":"Garde-moi","detail":"D","annual_impact":"120,50","effort":"4","confidence":"0,9"},
          {"detail":"Pas de titre, donc inexploitable"},
          {"title":"Moi aussi","detail":"D2"}
        ]}
        """
        let drafts = CoachResponseParser.parse(raw).drafts
        #expect(drafts.count == 2, "obtenu : \(drafts.map(\.title))")
        // A model answering in French writes "120,50": all three
        // notations must produce the same number.
        #expect(abs(drafts[0].annualImpact - 120.5) < 0.01)
        #expect(drafts[0].effort == 4)
        #expect(abs(drafts[0].confidence - 0.9) < 0.01)
    }

    @Test("Deux recommandations sur le même sujet ne sont comptées qu'une fois")
    func parseDedupe() {
        // The table has a UNIQUE(domain, ref): without deduplication, the second
        // entry would silently overwrite the first.
        let raw = """
        {"recommendations":[
          {"key":"meme_sujet","title":"A","detail":"D"},
          {"key":"meme_sujet","title":"B","detail":"D"}
        ]}
        """
        #expect(CoachResponseParser.parse(raw).drafts.count == 1)
    }

    @Test("Sans clé fournie, la référence est dérivée du titre")
    func refDeriveeDuTitre() {
        let raw = #"{"recommendations":[{"title":"Réduire les Courses !","detail":"D"}]}"#
        #expect(CoachResponseParser.parse(raw).drafts.first?.ref == "reduire_les_courses")
    }

    @Test("La référence reste stable malgré une reformulation de surface")
    func slugStable() {
        // This is what makes persistent dismissal hold up: the model almost
        // always slightly rephrases the same advice from one analysis to the next.
        #expect(CoachRecommendationDraft.slug("Résilier l'abonnement Netflix")
                == CoachRecommendationDraft.slug("resilier l abonnement netflix"))
        #expect(CoachRecommendationDraft.slug("Frais : 2 %") == "frais_2")
    }

    @Test("Une réponse illisible ne produit rien plutôt que du bruit")
    func parseIllisible() {
        let result = CoachResponseParser.parse("désolé, je ne peux pas répondre")
        #expect(result.drafts.isEmpty)
        #expect(result.failure == .unreadable)
    }

    @Test("Zéro recommandation n'est PAS une erreur")
    func listeVideEstUnSucces() {
        // Usage feedback 2026-08-28: the two cases were conflated, so
        // "the model has nothing to propose" showed as "the analysis didn't
        // complete" — and real failures became undiagnosable, drowned
        // in the same message.
        let result = CoachResponseParser.parse(#"{"profile":"Tout est sain.","recommendations":[]}"#)
        #expect(result.drafts.isEmpty)
        #expect(result.failure == nil, "une liste vide est une réponse légitime")
        #expect(result.profileSummary == "Tout est sain.")
    }

    @Test("Une réponse coupée en plein JSON conserve les recommandations complètes")
    func reponseTronqueeEstRecuperee() {
        // The most likely cause of the observed failure: on a small-context
        // model, the briefing and instructions leave too little room and
        // the response gets cut off. `LenientJSON` deliberately refuses to
        // close braces on its own — but objects written BEFORE the cutoff
        // are complete, and discarding them would lose valid recommendations.
        let tronquee = """
        {"profile":"Profil","recommendations":[
          {"key":"un","title":"Premier conseil","detail":"D1","annual_impact":120,"effort":4,"confidence":0.9},
          {"key":"deux","title":"Deuxième conseil","detail":"D2","annual_impact":60,"effort":3,"confidence":0.7},
          {"key":"trois","title":"Troisième con
        """
        let result = CoachResponseParser.parse(tronquee)
        #expect(result.failure == nil, "une troncature ne doit pas tout invalider")
        #expect(result.drafts.count == 2, "obtenu : \(result.drafts.map(\.title))")
        #expect(result.wasSalvaged, "la récupération doit être signalée à l'utilisateur")
    }

    @Test("Un modèle qui traduit ses propres clés JSON reste lisible")
    func clesEnFrancais() {
        // We ask for a response in French: a model writing in
        // French will happily translate "recommendations" to
        // "recommandations", which made the entire response unusable.
        let raw = #"{"profil":"P","recommandations":[{"key":"x","title":"T","detail":"D"}]}"#
        let result = CoachResponseParser.parse(raw)
        #expect(result.failure == nil)
        #expect(result.drafts.count == 1)
        #expect(result.profileSummary == "P")
    }

    @Test("La réponse réelle qui échouait est désormais exploitée")
    func reponseTerrainMalformee() {
        // RAW response captured in production (2026-08-28), reproduced here
        // identically in structure. Two compounding defects:
        //  1. `,"recommendations":` MISSING — the array is glued to the end of
        //     the `profile` string, never closed, which shifts the quote
        //     parity for the rest of the document;
        //  2. `effort:` and `confidence:` written WITHOUT quotes, while
        //     the other keys of the same object have them.
        // Result before the fix: "The model's response couldn't be
        // used", even though both recommendations were complete.
        let raw = """
        {"profile":"Tu es un utilisateur avec un revenu moyen de 2 830,20 €/mois. Ton rythme de dépense est élevé.\n[{"key":"abonnements_streaming","title":"Annule l'Abonnement Canal+ cette semaine","detail":"Tu dois supprimer l'Abonnement Canal+ de 21,99 €.","rationale":"Abonnement Canal+ : 21,99 €/mois.","category":"Abonnements","annual_impact":0, effort:2, confidence:0.92},{"key":"abonnements_diversification","title":"Réévalue l'Abonnement","detail":"Tu dois examiner l'Abonnement.","rationale":"Abonnement : 92,42 €/mois.","category":"Abonnements","annual_impact":0, effort:4, confidence:0.85}]}
        """
        let result = CoachResponseParser.parse(raw)
        #expect(result.failure == nil, "cette réponse contient deux recommandations complètes")
        #expect(result.drafts.count == 2, "obtenu : \(result.drafts.map(\.title))")
        #expect(result.drafts.first?.ref == "abonnements_streaming")
        // The bare keys must have been recovered, not replaced by defaults.
        #expect(result.drafts.first?.effort == 2)
        #expect(abs((result.drafts.first?.confidence ?? 0) - 0.92) < 0.01)
        // The profile, glued to the array, must be recovered without its stray tail.
        #expect(result.profileSummary?.contains("revenu moyen") == true)
        #expect(result.profileSummary?.hasSuffix("[{") == false, "la queue « \\n[{ » doit être retirée")
    }

    @Test("Un préambule coupé avant toute recommandation est nommé précisément")
    func coupeAvantLesRecommandations() {
        // A second real response captured (2026-08-28): the model spent
        // its entire output budget on the profile and stopped dead, with no
        // closing quote and not a single recommendation. There is NOTHING to
        // recover — saying so precisely matters, because the only useful
        // action is switching backends, not retrying.
        let raw = """
        {"profile":"Tu es un utilisateur avec un rythme de dépenses élevé par rapport à tes revenus. Ton défi est de transformer chaque dépense en opportunité de contrôle, sans sacrifier ta stabilité.
        """
        let result = CoachResponseParser.parse(raw)
        #expect(result.drafts.isEmpty)
        #expect(result.failure == .truncatedBeforeRecommendations,
                "à distinguer d'un JSON illisible : ici le préambule est parfaitement lisible")
        #expect(result.profileSummary?.contains("rythme de dépenses") == true,
                "le profil reste affichable même si l'analyse a échoué")
    }

    @Test("Les consignes demandent les recommandations AVANT le profil")
    func recommandationsDemandeesEnPremier() {
        // This is the structural defense against truncation: if the response is
        // cut off, it's better to lose the profile than every recommendation. Verified
        // for BOTH budgets — a more detailed profile in `.generous` must
        // never push the recommendations behind it.
        for domain in CoachDomain.allCases {
            for budget: CoachContextBudget in [.compact, .generous] {
                let system = CoachPrompt.system(for: domain, budget: budget)
                guard let recoIndex = system.range(of: "{\"recommendations\""),
                      let profileIndex = system.range(of: "\"profile\":\"…\"") else {
                    Issue.record("gabarit JSON introuvable dans les consignes (\(budget))")
                    return
                }
                #expect(recoIndex.lowerBound < profileIndex.lowerBound,
                        "le gabarit doit placer \"recommendations\" en premier (\(budget))")
                #expect(system.contains("EN DERNIER"))
            }
        }
    }

    @Test("Le profil demandé est détaillé en budget généreux, court en Apple Intelligence")
    func profilDetailleSelonLeBudget() {
        // Usage feedback 2026-08-29: "before we had a lot more
        // detail on the profile" — the "2 SHORT sentences maximum"
        // instruction applied uniformly, even when the backend
        // had plenty of room to say more.
        for domain in CoachDomain.allCases {
            let compact = CoachPrompt.system(for: domain, budget: .compact)
            #expect(compact.contains("2 phrases COURTES"))
            #expect(!compact.contains("DÉTAILLÉ"))

            let generous = CoachPrompt.system(for: domain, budget: .generous)
            #expect(generous.contains("DÉTAILLÉ"))
            #expect(generous.contains("TYPE"), "le type de profil financier doit être demandé explicitement")
            #expect(generous.contains("HABITUDES"))
            #expect(generous.contains("ERREURS"))
            #expect(!generous.contains("2 phrases COURTES"))
        }
    }

    @Test("Une clé nue dans une valeur texte n'est jamais réécrite")
    func clesNuesSeulementHorsChaines() {
        // A guard for the repair pass: "Summary: …" in a French sentence is
        // common, and rewriting it would corrupt the value.
        let repaired = LenientJSON.quotingBareKeys(#"{"detail":"Bilan: revoir ce poste", effort:3}"#)
        #expect(repaired.contains(#""effort":3"#), "la clé nue doit être citée")
        #expect(repaired.contains("Bilan: revoir ce poste"), "le texte de la valeur doit rester intact")
    }

    @Test("Un JSON valide sans liste de recommandations est signalé comme tel")
    func listeAbsente() {
        let result = CoachResponseParser.parse(#"{"profile":"P","autre_chose":123}"#)
        #expect(result.failure == .missingList, "à distinguer d'une liste vide et d'une réponse illisible")
    }

    // MARK: - "Spending" briefing

    private func briefingInput(objectives: String = "", transactions: [FinanceTransaction]? = nil)
        -> CoachBriefingBuilder.Input {
        let txs = transactions ?? [
            tx(id: 1, montant: 2_000, jour: "2026-06-01"),
            tx(id: 2, montant: -700, jour: "2026-06-05", categoryId: 10, tiersId: 1, tiers: "Bailleur"),
            tx(id: 3, montant: -250, jour: "2026-06-08", categoryId: 21, tiersId: 2, tiers: "Carrefour"),
            tx(id: 4, montant: 2_000, jour: "2026-07-01"),
            tx(id: 5, montant: -700, jour: "2026-07-05", categoryId: 10, tiersId: 1, tiers: "Bailleur"),
            tx(id: 6, montant: -400, jour: "2026-07-09", categoryId: 21, tiersId: 2, tiers: "Carrefour"),
        ]
        return CoachBriefingBuilder.Input(
            transactions: txs,
            categories: [Category(id: 10, name: "Logement"),
                         Category(id: 20, name: "Alimentation"),
                         Category(id: 21, name: "Courses", parentId: 20)],
            tiers: [Tiers(id: 1, name: "Bailleur"), Tiers(id: 2, name: "Carrefour")],
            patterns: [], envelopes: [], signals: [],
            objectives: objectives,
            now: date("2026-08-01")
        )
    }

    @Test("Le dossier contient le profil chiffré et les postes de dépense")
    func dossierDepenses() {
        let text = CoachBriefingBuilder.build(briefingInput())
        #expect(text.contains("PROFIL"))
        #expect(text.contains("DÉPENSES PAR CATÉGORIE"))
        #expect(text.contains("Logement"))
        // Subcategories are rolled up to their root, otherwise the briefing
        // drowns in line items worth a few euros.
        #expect(text.contains("Alimentation"), "la sous-catégorie « Courses » doit être agrégée sous « Alimentation »")
        #expect(!text.contains("  Courses :"), "aucun poste ne doit apparaître au niveau sous-catégorie")
    }

    @Test("Les totaux mensuels sont exacts et chronologiques")
    func totauxMensuels() {
        let months = CoachBriefingBuilder.monthlyTotals(briefingInput())
        #expect(months.map(\.label) == ["2026-06", "2026-07"])
        #expect(months[0].income == 2_000 && months[0].expense == 950)
        #expect(months[1].income == 2_000 && months[1].expense == 1_100)
    }

    /// A briefing at its "maximum": every list past its cap, over a
    /// long history. This is the worst realistic case, the one that must
    /// stay usable by the model.
    private func inputMaximal(objectives: String = "") -> CoachBriefingBuilder.Input {
        var txs: [FinanceTransaction] = []
        var id = 0
        // 36 months of history — past the 24-month cap.
        for monthOffset in 0..<36 {
            let year = 2023 + monthOffset / 12
            let month = monthOffset % 12 + 1
            let jour = String(format: "%04d-%02d-05", year, month)
            id += 1; txs.append(tx(id: id, montant: 2_500, jour: jour))
            for c in 0..<25 {
                id += 1
                txs.append(tx(id: id, montant: -40, jour: jour, categoryId: c, tiersId: c, tiers: "Marchand numéro \(c)"))
            }
        }
        // The current month, so envelopes have something to fill them with.
        for c in 0..<25 {
            id += 1
            txs.append(tx(id: id, montant: -60, jour: "2026-08-05", categoryId: c, tiersId: c, tiers: "Marchand numéro \(c)"))
        }
        let categories = (0..<25).map { Category(id: $0, name: "Catégorie détaillée numéro \($0)") }
        let patterns = (0..<30).map { i in
            RecurringPattern(id: i, name: "Charge récurrente numéro \(i)", amountAvg: -30, amountTolerance: 0.15,
                             categoryId: i, payeeId: nil, frequency: .monthly, anchorDay: 5,
                             isActive: true, isManual: false, createdAt: date("2026-01-01"),
                             lastDetectedAt: nil, startDate: date("2026-01-01"), endDate: nil)
        }
        let envelopes = (0..<30).map { i in
            BudgetEnvelope(id: i, name: "Enveloppe numéro \(i)", categoryId: i,
                           amount: 100, period: .monthly, startDate: date("2026-01-01"), isActive: true)
        }
        return CoachBriefingBuilder.Input(
            transactions: txs, categories: categories,
            tiers: (0..<25).map { Tiers(id: $0, name: "Marchand numéro \($0)") },
            patterns: patterns, envelopes: envelopes,
            signals: (0..<12).map { "Signal détecté automatiquement numéro \($0)" },
            objectives: objectives, now: date("2026-08-20")
        )
    }

    @Test("Les objectifs de l'utilisateur survivent à la troncature du dossier")
    func objectifsJamaisTronques() {
        // Design decision: objectives are added AFTER
        // truncation. It's the only part the user wrote
        // themselves — sacrificing it would mean analyzing without knowing what they're
        // looking for, exactly what the coach must avoid.
        let text = CoachBriefingBuilder.build(inputMaximal(objectives: "Acheter un appartement d'ici 2029."))
        #expect(text.contains("tronqué"),
                "ce jeu de données doit saturer le dossier (obtenu : \(text.count) caractères)")
        #expect(text.contains("Acheter un appartement d'ici 2029."),
                "les objectifs doivent survivre à la troncature")
    }

    @Test("Le dossier reste borné quel que soit le volume")
    func dossierBorne() {
        let text = CoachBriefingBuilder.build(inputMaximal())
        // Margin past the cap for the objectives block and the marker.
        #expect(text.count < CoachBriefingBuilder.maxCharacters + 2_000,
                "dossier de \(text.count) caractères — il doit tenir dans la fenêtre de contexte")
    }

    @Test("Chaque liste du dossier est plafonnée, sans exception")
    func toutesLesListesSontPlafonnees() {
        // The monthly detail and the envelopes were the only two unbounded
        // lists: on a long history, it was TRUNCATION that
        // decided what reached the model, by cutting off the end.
        let text = CoachBriefingBuilder.build(inputMaximal())
        let monthLines = text.components(separatedBy: "\n").filter { $0.hasPrefix("  20") }
        #expect(monthLines.count <= CoachBriefingBuilder.maxMonths,
                "détail mensuel : \(monthLines.count) lignes")
        let envelopeLines = text.components(separatedBy: "\n").filter { $0.contains("Enveloppe numéro") }
        #expect(envelopeLines.count <= CoachBriefingBuilder.maxEnvelopes,
                "enveloppes : \(envelopeLines.count) lignes")
    }

    // MARK: - Budget de contexte (Apple Intelligence vs serveur local/cloud)

    @Test("Le budget se résout depuis le backend RÉSOLU, jamais depuis une préférence brute")
    func budgetResoluDepuisLeBackend() {
        // Usage feedback 2026-08-29: the briefing and the profile were capped
        // to the same limits as Apple Intelligence even when the backend
        // actually in use (local server, cloud) had plenty of room.
        #expect(CoachContextBudget.resolved(from: .foundationModels) == .compact)
        #expect(CoachContextBudget.resolved(from: .localServer) == .generous)
        #expect(CoachContextBudget.resolved(from: .cloud(.claude)) == .generous)
        #expect(CoachContextBudget.resolved(from: .cloud(.openAI)) == .generous)
        // Should never reach a real model call, but a cautious
        // default (compact) rather than a crash if it ever does.
        #expect(CoachContextBudget.resolved(from: .automatic) == .compact)
        #expect(CoachContextBudget.resolved(from: .off) == .compact)
        #expect(CoachContextBudget.resolved(from: nil) == .compact)
    }

    @Test("Un modèle qui réfléchit sans conclure déclenche UNE relance en passes courtes")
    func repliQuandLeModeleNeConclutJamais() {
        // A signature measured three times (qwen3.5-9b via LM Studio): truncated
        // reasoning, zero response. THIS pattern — and only this one — can be
        // recovered by shrinking the input.
        #expect(CoachContextBudget.shouldRetryInPasses(
            budget: .generous, sawReasoningOnly: true,
            producedRecommendations: false, alreadyRetried: false))

        // An out-of-format response has nothing to do with the input size:
        // retrying would just mean waiting twice.
        #expect(!CoachContextBudget.shouldRetryInPasses(
            budget: .generous, sawReasoningOnly: false,
            producedRecommendations: false, alreadyRetried: false))

        // Some recommendations came out anyway: a result already obtained isn't
        // discarded just to retry.
        #expect(!CoachContextBudget.shouldRetryInPasses(
            budget: .generous, sawReasoningOnly: true,
            producedRecommendations: true, alreadyRetried: false))

        // A SINGLE retry: if the short passes also fail, the
        // problem is no longer the input size.
        #expect(!CoachContextBudget.shouldRetryInPasses(
            budget: .generous, sawReasoningOnly: true,
            producedRecommendations: false, alreadyRetried: true))

        // Already in short passes: there's nothing shorter left to try.
        #expect(!CoachContextBudget.shouldRetryInPasses(
            budget: .compact, sawReasoningOnly: true,
            producedRecommendations: false, alreadyRetried: false))
    }

    @Test("Le repli réduit vraiment ce qui part au modèle")
    func repliReduitLEntree() {
        // This is the whole point of the fallback: if short passes didn't
        // lighten the input, retrying wouldn't change anything about the observed problem.
        let input = inputMaximal(objectives: "Moins dépenser tous les mois.")
        let sections = CoachBriefingBuilder.sections(input)
        let header = CoachBriefingBuilder.condensedHeader(input)
        let objectives = CoachBriefingBuilder.objectivesBlock(input)

        let generous = CoachPassPlanner.plan(sections: sections, header: header,
                                             objectivesBlock: objectives, budget: .generous)
        let compact = CoachPassPlanner.plan(sections: sections, header: header,
                                            objectivesBlock: objectives, budget: .compact)
        let plusGrossePasseCourte = compact.map(\.body.count).max() ?? 0
        #expect(plusGrossePasseCourte < generous[0].body.count / 2,
                "passe courte la plus grosse : \(plusGrossePasseCourte) vs \(generous[0].body.count) d'un coup")
    }

    @Test("Un dossier maximal survit sans troncature en budget généreux")
    func dossierGenereuxMoinsTronque() {
        // The same "worst realistic case" dataset as `dossierBorne` — in
        // `.compact` it saturates and gets cut off; in `.generous`, the
        // 3-4x wider cap should be enough to fit everything.
        let compact = CoachBriefingBuilder.build(inputMaximal(), budget: .compact)
        let generous = CoachBriefingBuilder.build(inputMaximal(), budget: .generous)
        #expect(compact.contains("tronqué"), "le cas compact doit rester le pire cas déjà testé par `dossierBorne`")
        #expect(!generous.contains("tronqué"),
                "un budget généreux doit absorber ce même dossier sans coupure (obtenu : \(generous.count) caractères)")
        #expect(generous.count > compact.count)
        #expect(generous.count < CoachBriefingBuilder.maxCharactersGenerous + 2_000,
                "le budget généreux reste borné, ce n'est pas « illimité »")
    }

    // MARK: - Splitting into passes

    @Test("Un backend qui encaisse tout le dossier reçoit UNE seule passe")
    func budgetGenereuxUneSeulePasse() {
        let input = inputMaximal(objectives: "Acheter un appartement d'ici 2029.")
        let passes = CoachPassPlanner.plan(sections: CoachBriefingBuilder.sections(input),
                                           header: CoachBriefingBuilder.condensedHeader(input),
                                           objectivesBlock: CoachBriefingBuilder.objectivesBlock(input),
                                           budget: .generous)
        #expect(passes.count == 1, "découper coûterait plusieurs appels ET priverait le modèle de la vue d'ensemble")
        #expect(passes[0].isOnly)
        #expect(passes[0].body.contains("Acheter un appartement"))
    }

    @Test("Une fenêtre étroite découpe le dossier sans jamais perdre de section")
    func passesCompactesGardentToutLeDossier() {
        // This is THE point of splitting: on a small-context model, it
        // wasn't "analyzed a bit worse" — the ENTIRE analysis was
        // failing (Apple Intelligence, usage feedback 2026-09-02).
        let input = inputMaximal(objectives: "Moins dépenser tous les mois.")
        let sections = CoachBriefingBuilder.sections(input)
        let passes = CoachPassPlanner.plan(sections: sections,
                                           header: CoachBriefingBuilder.condensedHeader(input),
                                           objectivesBlock: CoachBriefingBuilder.objectivesBlock(input),
                                           budget: .compact)
        #expect(passes.count > 1, "ce dossier ne tient pas en une passe étroite")
        #expect(passes.allSatisfy { $0.total == passes.count })
        #expect(passes.map(\.index) == Array(1...passes.count))

        // Each section appears in exactly one pass: nothing is
        // dropped along the way, otherwise splitting would make
        // material disappear instead of spreading it out.
        for section in sections {
            let carriers = passes.filter { $0.focus.contains(section.title) }
            #expect(carriers.count == 1, "section « \(section.title) » portée par \(carriers.count) passe(s)")
        }
    }

    @Test("Chaque passe porte les chiffres clés ET les objectifs")
    func chaquePassePorteLeContexte() {
        // A pass that only sees "merchants" has no reference scale and
        // gives advice in a vacuum; a pass that doesn't see the
        // objectives gives advice unrelated to what the person is looking for.
        let input = inputMaximal(objectives: "Moins dépenser tous les mois.")
        let passes = CoachPassPlanner.plan(sections: CoachBriefingBuilder.sections(input),
                                           header: CoachBriefingBuilder.condensedHeader(input),
                                           objectivesBlock: CoachBriefingBuilder.objectivesBlock(input),
                                           budget: .compact)
        for pass in passes {
            #expect(pass.body.contains("CHIFFRES CLÉS"), "passe \(pass.index) sans chiffres de référence")
            #expect(pass.body.contains("Moins dépenser"), "passe \(pass.index) sans les objectifs")
        }
    }

    @Test("Une passe reste dans son budget, objectifs compris")
    func passeBornee() {
        // The per-pass budget isn't decorative: it's what guarantees there's
        // still room to WRITE the response within a 4,000-token
        // window.
        let objectifsTresLongs = String(repeating: "Objectif détaillé numéro un. ", count: 200)
        let input = inputMaximal(objectives: objectifsTresLongs)
        let passes = CoachPassPlanner.plan(sections: CoachBriefingBuilder.sections(input),
                                           header: CoachBriefingBuilder.condensedHeader(input),
                                           objectivesBlock: CoachBriefingBuilder.objectivesBlock(input),
                                           budget: .compact)
        let header = CoachBriefingBuilder.condensedHeader(input).count
        let ceiling = header + CoachPassPlanner.compactPassCharacters
            + CoachPassPlanner.objectivesPerPassCharacters + 200
        for pass in passes {
            #expect(pass.body.count <= ceiling,
                    "passe \(pass.index) : \(pass.body.count) caractères")
        }
        // Lengthy objectives must not starve the material being analyzed.
        #expect(passes.allSatisfy { $0.body.contains("CHIFFRES CLÉS") })
    }

    @Test("Un portefeuille se découpe aussi")
    func passesInvestissement() {
        let input = InvestmentBriefingBuilder.Input(
            accounts: [InvestmentAccount(id: 1, name: "PEA", broker: "Bourso", currency: "EUR",
                                         accountType: "PEA", currentValue: 10_000, investedAmount: 8_000,
                                         openedAt: date("2024-01-01"), cashBalance: 2_000)],
            positions: [
                InvestmentPosition(id: 1, accountId: 1, assetType: "action", assetName: "Apple", ticker: "AAPL",
                                   quantity: 10, averageBuyPrice: 100, currentValue: 8_000, purchaseDate: date("2025-01-01"))
            ],
            recentOrders: [], objectives: "Ne pas dépasser 25 % sur une ligne.", now: date("2026-08-01"))
        let passes = CoachPassPlanner.plan(sections: InvestmentBriefingBuilder.sections(input),
                                           header: InvestmentBriefingBuilder.condensedHeader(input),
                                           objectivesBlock: InvestmentBriefingBuilder.objectivesBlock(input),
                                           budget: .compact)
        #expect(!passes.isEmpty)
        #expect(passes.allSatisfy { $0.body.contains("CHIFFRES CLÉS") })
        #expect(passes.allSatisfy { $0.body.contains("25 %") }, "les objectifs suivent chaque passe")
    }

    @Test("Un dossier vide ne produit aucune passe")
    func aucunePasseSansDonnees() {
        #expect(CoachPassPlanner.plan(sections: [], header: "X", objectivesBlock: nil, budget: .compact).isEmpty)
        #expect(CoachPassPlanner.plan(sections: [CoachBriefingSection(id: "a", title: "A", body: "   ")],
                                      header: "X", objectivesBlock: nil, budget: .generous).isEmpty)
    }

    // MARK: - Merging passes

    @Test("Deux passes qui repèrent le même sujet ne le comptent qu'une fois")
    func fusionDeduplique() {
        let a = [CoachRecommendationDraft(ref: "abo", title: "Annule Canal+", detail: "", rationale: nil,
                                          category: nil, annualImpact: 100, effort: 2, confidence: 0.6),
                 CoachRecommendationDraft(ref: "grab", title: "Réduis Grab", detail: "", rationale: nil,
                                          category: nil, annualImpact: 300, effort: 3, confidence: 0.9)]
        let b = [CoachRecommendationDraft(ref: "abo", title: "Annule Canal+ (vu ailleurs)", detail: "", rationale: nil,
                                          category: nil, annualImpact: 260, effort: 2, confidence: 0.95)]
        let merged = CoachResponseParser.merge([a, b])
        #expect(merged.count == 2)
        // The version the model is most confident about wins, never "the last one seen".
        #expect(merged.first(where: { $0.ref == "abo" })?.title == "Annule Canal+ (vu ailleurs)")
        // The order of first appearance is preserved: final ranking
        // is `CoachRanker`'s job, not the merge's.
        #expect(merged.map(\.ref) == ["abo", "grab"])
    }

    @Test("La fusion reste bornée même si chaque passe part en boucle")
    func fusionBornee() {
        let batches = (0..<5).map { pass in
            (0..<30).map { i in
                CoachRecommendationDraft(ref: "p\(pass)_r\(i)", title: "T\(pass)-\(i)", detail: "",
                                         rationale: nil, category: nil, annualImpact: 10,
                                         effort: 3, confidence: 0.5)
            }
        }
        #expect(CoachResponseParser.merge(batches).count == CoachResponseParser.maxRecommendations)
    }

    @Test("La passe de profil lit une réponse qui ne porte que le profil")
    func profilSeul() {
        #expect(CoachResponseParser.parseProfileOnly(#"{"profile":"Tu es prudent."}"#) == "Tu es prudent.")
        #expect(CoachResponseParser.parseProfileOnly(#"```json\#n{"profil":"Tu es prudent."}\#n```"#) == "Tu es prudent.")
        #expect(CoachResponseParser.parseProfileOnly("désolé") == nil)
    }

    // MARK: - "Portfolio" briefing

    @Test("Le dossier portefeuille chiffre la concentration et les liquidités")
    func dossierInvestissement() {
        let accounts = [InvestmentAccount(id: 1, name: "PEA", broker: "Bourso", currency: "EUR",
                                          accountType: "PEA", currentValue: 10_000, investedAmount: 8_000,
                                          openedAt: date("2024-01-01"), cashBalance: 2_000)]
        let positions = [
            InvestmentPosition(id: 1, accountId: 1, assetType: "action", assetName: "Apple", ticker: "AAPL",
                               quantity: 10, averageBuyPrice: 100, currentValue: 8_000, purchaseDate: date("2025-01-01")),
            InvestmentPosition(id: 2, accountId: 1, assetType: "etf", assetName: "World", ticker: "IWDA",
                               quantity: 10, averageBuyPrice: 100, currentValue: 2_000, purchaseDate: date("2025-01-01")),
        ]
        let text = InvestmentBriefingBuilder.build(InvestmentBriefingBuilder.Input(
            accounts: accounts, positions: positions, recentOrders: [],
            objectives: "", now: date("2026-08-01")))

        #expect(text.contains("PORTEFEUILLE"))
        #expect(text.contains("ALLOCATION ET CONCENTRATION"))
        // 8,000 / 10,000: the top line accounts for 80% — that's the
        // structural risk an individual won't spot on their own.
        #expect(text.contains("80 %"), "le poids de la 1re ligne doit apparaître")
        // 2,000 in cash out of 12,000 total capital ≈ 17%.
        #expect(text.contains("17 %"), "la part de liquidités dormantes doit apparaître")
    }

    @Test("Un portefeuille vide ne produit pas de dossier bancal")
    func dossierInvestissementVide() {
        let text = InvestmentBriefingBuilder.build(InvestmentBriefingBuilder.Input(
            accounts: [], positions: [], recentOrders: [], objectives: "", now: date("2026-08-01")))
        #expect(!text.contains("ALLOCATION"))
    }

    // MARK: - Consignes

    @Test("Les consignes interdisent explicitement le conseil générique")
    func promptInterditLeGenerique() {
        // This is THE complaint made about the previous version. If this constraint
        // is dropped from the instructions, the model spontaneously falls
        // back into generic advice.
        for domain in CoachDomain.allCases {
            let system = CoachPrompt.system(for: domain)
            #expect(system.contains("CHIFFRE PRÉCIS"))
            #expect(system.contains("N'invente AUCUN chiffre"))
            #expect(system.lowercased().contains("json"))
        }
        // The investment coach must never turn into an oracle.
        #expect(CoachPrompt.system(for: .investments).contains("Tu ne prédis JAMAIS"))
    }

    @Test("Chaque domaine a son propre réglage de backend IA")
    func domainesEtBackends() {
        #expect(CoachDomain.transactions.aiFeature == .insights)
        #expect(CoachDomain.investments.aiFeature == .investmentCoach)
        // The historical rawValue must be kept, otherwise the backend choice
        // already persisted by the user is silently lost.
        #expect(AIFeature.insights.rawValue == "insights")
    }

    @Test("Une analyse sans date est périmée, une analyse d'hier ne l'est pas")
    func peremption() {
        let now = date("2026-08-28")
        #expect(CoachAnalysis.empty(.transactions).isStale(now: now))
        var recente = CoachAnalysis.empty(.transactions)
        recente.generatedAt = date("2026-08-27")
        #expect(!recente.isStale(now: now))
        var vieille = CoachAnalysis.empty(.transactions)
        vieille.generatedAt = date("2026-08-01")
        #expect(vieille.isStale(now: now))
    }
}
