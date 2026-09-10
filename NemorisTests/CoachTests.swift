import Foundation
import Testing
@testable import Nemoris

/// Le coach IA : arbitrage des recommandations, lecture de la réponse du
/// modèle, et construction des dossiers qui lui sont envoyés.
///
/// Ce que ces tests protègent en priorité : le coach coûte cher (un appel
/// modèle par analyse) et n'est pas reproductible. Tout ce qui PEUT être
/// décidé sans lui — priorité, tolérance de parsing, contenu du dossier — doit
/// donc l'être ici, une fois pour toutes.
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
        // Régression directe de `Insight.compositeScore`, qui MULTIPLIAIT les
        // trois dimensions : tout insight à impact nul valait 0 et ne
        // remontait jamais — alors que « tu es à 70 % sur une seule ligne »
        // est exactement le conseil structurant qu'un consultant met en avant.
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
        // Au-delà du plafond, deux montants « énormes » ne doivent plus se
        // départager par le seul montant.
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
        // Deux recommandations rigoureusement équivalentes ne doivent pas
        // s'inverser d'un rendu au suivant — sinon l'écran « bouge tout seul ».
        let items = [reco("zebre", impact: 100, id: 1), reco("alpha", impact: 100, id: 2)]
        #expect(CoachRanker.ranked(items).map(\.ref) == CoachRanker.ranked(items.reversed()).map(\.ref))
    }

    @Test("Les valeurs aberrantes du modèle sont ramenées dans leurs bornes")
    func normalisation() {
        // Un modèle rend volontiers un effort hors barème et une confiance en
        // pourcentage. Sans normalisation, ces valeurs contaminent le classement.
        let a = CoachRanker.normalize(annualImpact: -50, effort: 12, confidence: 85)
        #expect(a.annualImpact == 0, "un impact négatif n'a pas de sens ici")
        #expect(a.effort == 5)
        #expect(abs(a.confidence - 0.85) < 0.001, "« 85 » doit être lu comme 85 %")

        let b = CoachRanker.normalize(annualImpact: .nan, effort: 0, confidence: .infinity)
        #expect(b.annualImpact == 0 && b.effort == 1 && b.confidence <= 1)
    }

    // MARK: - Lecture de la réponse du modèle

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
        // C'est la classe de bug déjà payée sur l'import de documents : une
        // clé manquante faisait jeter la page entière.
        let raw = """
        {"recommendations":[
          {"title":"Garde-moi","detail":"D","annual_impact":"120,50","effort":"4","confidence":"0,9"},
          {"detail":"Pas de titre, donc inexploitable"},
          {"title":"Moi aussi","detail":"D2"}
        ]}
        """
        let drafts = CoachResponseParser.parse(raw).drafts
        #expect(drafts.count == 2, "obtenu : \(drafts.map(\.title))")
        // Un modèle qui répond en français écrit « 120,50 » : les trois
        // écritures doivent donner le même nombre.
        #expect(abs(drafts[0].annualImpact - 120.5) < 0.01)
        #expect(drafts[0].effort == 4)
        #expect(abs(drafts[0].confidence - 0.9) < 0.01)
    }

    @Test("Deux recommandations sur le même sujet ne sont comptées qu'une fois")
    func parseDedupe() {
        // La table a un UNIQUE(domain, ref) : sans déduplication, la seconde
        // écraserait la première en silence.
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
        // C'est ce qui fait tenir le rejet persistant : le modèle reformule
        // presque toujours légèrement le même conseil d'une analyse à l'autre.
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
        // Retour d'usage 2026-08-28 : les deux cas étaient confondus, donc
        // « le modèle n'a rien à proposer » s'affichait « l'analyse n'a pas
        // abouti » — et les vrais échecs devenaient indiagnosticables, noyés
        // dans le même message.
        let result = CoachResponseParser.parse(#"{"profile":"Tout est sain.","recommendations":[]}"#)
        #expect(result.drafts.isEmpty)
        #expect(result.failure == nil, "une liste vide est une réponse légitime")
        #expect(result.profileSummary == "Tout est sain.")
    }

    @Test("Une réponse coupée en plein JSON conserve les recommandations complètes")
    func reponseTronqueeEstRecuperee() {
        // Cause la plus probable de l'échec constaté : sur un modèle à petit
        // contexte, le dossier et les consignes laissent trop peu de place et
        // la réponse est coupée. `LenientJSON` refuse par conception de
        // refermer les accolades — mais les objets écrits AVANT la coupure
        // sont complets, et les jeter perdrait des recommandations valides.
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
        // On demande une réponse en français : un modèle qui rédige en
        // français traduit volontiers « recommendations » en
        // « recommandations », ce qui rendait la réponse entière inexploitable.
        let raw = #"{"profil":"P","recommandations":[{"key":"x","title":"T","detail":"D"}]}"#
        let result = CoachResponseParser.parse(raw)
        #expect(result.failure == nil)
        #expect(result.drafts.count == 1)
        #expect(result.profileSummary == "P")
    }

    @Test("La réponse réelle qui échouait est désormais exploitée")
    func reponseTerrainMalformee() {
        // Réponse BRUTE capturée en production (2026-08-28), reproduite ici à
        // l'identique dans sa structure. Deux défauts cumulés :
        //  1. `,"recommendations":` OUBLIÉ — le tableau est collé à la fin de
        //     la chaîne `profile`, jamais refermée, ce qui décale la parité
        //     des guillemets pour tout le reste du document ;
        //  2. `effort:` et `confidence:` écrites SANS guillemets, alors que
        //     les autres clés du même objet en ont.
        // Résultat avant correctif : « La réponse du modèle n'a pas pu être
        // exploitée », alors que les deux recommandations étaient complètes.
        let raw = """
        {"profile":"Tu es un utilisateur avec un revenu moyen de 2 830,20 €/mois. Ton rythme de dépense est élevé.\n[{"key":"abonnements_streaming","title":"Annule l'Abonnement Canal+ cette semaine","detail":"Tu dois supprimer l'Abonnement Canal+ de 21,99 €.","rationale":"Abonnement Canal+ : 21,99 €/mois.","category":"Abonnements","annual_impact":0, effort:2, confidence:0.92},{"key":"abonnements_diversification","title":"Réévalue l'Abonnement","detail":"Tu dois examiner l'Abonnement.","rationale":"Abonnement : 92,42 €/mois.","category":"Abonnements","annual_impact":0, effort:4, confidence:0.85}]}
        """
        let result = CoachResponseParser.parse(raw)
        #expect(result.failure == nil, "cette réponse contient deux recommandations complètes")
        #expect(result.drafts.count == 2, "obtenu : \(result.drafts.map(\.title))")
        #expect(result.drafts.first?.ref == "abonnements_streaming")
        // Les clés nues doivent avoir été récupérées, pas remplacées par les défauts.
        #expect(result.drafts.first?.effort == 2)
        #expect(abs((result.drafts.first?.confidence ?? 0) - 0.92) < 0.01)
        // Le profil, collé au tableau, doit être récupéré sans sa queue parasite.
        #expect(result.profileSummary?.contains("revenu moyen") == true)
        #expect(result.profileSummary?.hasSuffix("[{") == false, "la queue « \\n[{ » doit être retirée")
    }

    @Test("Un préambule coupé avant toute recommandation est nommé précisément")
    func coupeAvantLesRecommandations() {
        // Deuxième réponse réelle capturée (2026-08-28) : le modèle a dépensé
        // tout son budget de sortie dans le profil et s'est arrêté net, sans
        // guillemet fermant ni la moindre recommandation. Il n'y a RIEN à
        // récupérer — le dire précisément importe, parce que la seule action
        // utile est de changer de backend, pas de relancer.
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
        // C'est la parade structurelle à la troncature : si la réponse est
        // coupée, mieux vaut perdre le profil que tous les conseils. Vérifié
        // pour les DEUX budgets — un profil plus détaillé en `.generous` ne
        // doit jamais faire passer les recommandations après lui.
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
        // Retour d'usage 2026-08-29 : « avant on avait beaucoup plus de
        // détail sur le profil » — la consigne « 2 phrases COURTES au
        // maximum » s'appliquait uniformément, y compris quand le backend
        // avait largement la place d'en dire plus.
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
        // Garde-fou du réparateur : « Bilan: … » dans une phrase française est
        // fréquent, et le réécrire corromprait la valeur.
        let repaired = LenientJSON.quotingBareKeys(#"{"detail":"Bilan: revoir ce poste", effort:3}"#)
        #expect(repaired.contains(#""effort":3"#), "la clé nue doit être citée")
        #expect(repaired.contains("Bilan: revoir ce poste"), "le texte de la valeur doit rester intact")
    }

    @Test("Un JSON valide sans liste de recommandations est signalé comme tel")
    func listeAbsente() {
        let result = CoachResponseParser.parse(#"{"profile":"P","autre_chose":123}"#)
        #expect(result.failure == .missingList, "à distinguer d'une liste vide et d'une réponse illisible")
    }

    // MARK: - Dossier « dépenses »

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
        // Les sous-catégories sont remontées à leur racine, sinon le dossier
        // se noie dans des postes à quelques euros.
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

    /// Un dossier « au maximum » : chaque liste au-delà de son plafond, sur un
    /// historique long. C'est le pire cas réaliste, celui qui doit rester
    /// exploitable par le modèle.
    private func inputMaximal(objectives: String = "") -> CoachBriefingBuilder.Input {
        var txs: [FinanceTransaction] = []
        var id = 0
        // 36 mois d'historique — au-delà du plafond de 24.
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
        // Le mois en cours, pour que les enveloppes aient de quoi se remplir.
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
        // Décision de conception : les objectifs sont ajoutés APRÈS la
        // troncature. C'est la seule partie que l'utilisateur a écrite
        // lui-même — la sacrifier reviendrait à analyser sans savoir ce qu'il
        // cherche, précisément ce que le coach doit éviter.
        let text = CoachBriefingBuilder.build(inputMaximal(objectives: "Acheter un appartement d'ici 2029."))
        #expect(text.contains("tronqué"),
                "ce jeu de données doit saturer le dossier (obtenu : \(text.count) caractères)")
        #expect(text.contains("Acheter un appartement d'ici 2029."),
                "les objectifs doivent survivre à la troncature")
    }

    @Test("Le dossier reste borné quel que soit le volume")
    func dossierBorne() {
        let text = CoachBriefingBuilder.build(inputMaximal())
        // Marge au-delà du plafond pour le bloc objectifs et le marqueur.
        #expect(text.count < CoachBriefingBuilder.maxCharacters + 2_000,
                "dossier de \(text.count) caractères — il doit tenir dans la fenêtre de contexte")
    }

    @Test("Chaque liste du dossier est plafonnée, sans exception")
    func toutesLesListesSontPlafonnees() {
        // Le détail mensuel et les enveloppes étaient les deux seules listes
        // non bornées : sur un historique long, c'était la TRONCATURE qui
        // décidait de ce qui partait au modèle, en coupant la fin.
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
        // Retour d'usage 2026-08-29 : le dossier et le profil étaient bridés
        // aux mêmes plafonds qu'Apple Intelligence même quand le backend
        // réellement utilisé (serveur local, cloud) avait largement la place.
        #expect(CoachContextBudget.resolved(from: .foundationModels) == .compact)
        #expect(CoachContextBudget.resolved(from: .localServer) == .generous)
        #expect(CoachContextBudget.resolved(from: .cloud(.claude)) == .generous)
        #expect(CoachContextBudget.resolved(from: .cloud(.openAI)) == .generous)
        // Ne devraient jamais atteindre un appel modèle réel, mais un défaut
        // prudent (compact) plutôt qu'un crash si jamais c'est le cas.
        #expect(CoachContextBudget.resolved(from: .automatic) == .compact)
        #expect(CoachContextBudget.resolved(from: .off) == .compact)
        #expect(CoachContextBudget.resolved(from: nil) == .compact)
    }

    @Test("Un modèle qui réfléchit sans conclure déclenche UNE relance en passes courtes")
    func repliQuandLeModeleNeConclutJamais() {
        // Signature mesurée trois fois (qwen3.5-9b via LM Studio) : du
        // raisonnement tronqué, zéro réponse. Ce motif-là — et lui seul — se
        // rattrape en réduisant l'entrée.
        #expect(CoachContextBudget.shouldRetryInPasses(
            budget: .generous, sawReasoningOnly: true,
            producedRecommendations: false, alreadyRetried: false))

        // Une réponse hors format n'a rien à voir avec la taille de l'entrée :
        // relancer ferait juste attendre deux fois.
        #expect(!CoachContextBudget.shouldRetryInPasses(
            budget: .generous, sawReasoningOnly: false,
            producedRecommendations: false, alreadyRetried: false))

        // Des recommandations sont sorties malgré tout : on ne jette pas un
        // résultat obtenu pour retenter.
        #expect(!CoachContextBudget.shouldRetryInPasses(
            budget: .generous, sawReasoningOnly: true,
            producedRecommendations: true, alreadyRetried: false))

        // UNE seule relance : si les passes courtes échouent aussi, le
        // problème n'est plus la taille de l'entrée.
        #expect(!CoachContextBudget.shouldRetryInPasses(
            budget: .generous, sawReasoningOnly: true,
            producedRecommendations: false, alreadyRetried: true))

        // Déjà en passes courtes : il n'y a rien de plus court à tenter.
        #expect(!CoachContextBudget.shouldRetryInPasses(
            budget: .compact, sawReasoningOnly: true,
            producedRecommendations: false, alreadyRetried: false))
    }

    @Test("Le repli réduit vraiment ce qui part au modèle")
    func repliReduitLEntree() {
        // C'est la raison d'être du repli : si les passes courtes n'allégeaient
        // pas l'entrée, relancer ne changerait rien au problème constaté.
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
        // Même jeu de données « pire cas réaliste » que `dossierBorne` — en
        // `.compact` il sature et se fait couper ; en `.generous`, le plafond
        // 3-4× plus large doit suffire à tout faire tenir.
        let compact = CoachBriefingBuilder.build(inputMaximal(), budget: .compact)
        let generous = CoachBriefingBuilder.build(inputMaximal(), budget: .generous)
        #expect(compact.contains("tronqué"), "le cas compact doit rester le pire cas déjà testé par `dossierBorne`")
        #expect(!generous.contains("tronqué"),
                "un budget généreux doit absorber ce même dossier sans coupure (obtenu : \(generous.count) caractères)")
        #expect(generous.count > compact.count)
        #expect(generous.count < CoachBriefingBuilder.maxCharactersGenerous + 2_000,
                "le budget généreux reste borné, ce n'est pas « illimité »")
    }

    // MARK: - Découpage en passes

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
        // C'est LE point du découpage : sur un modèle à petite fenêtre, ce
        // n'était pas « moins bien analysé », c'était l'analyse entière qui
        // échouait (Apple Intelligence, retour d'usage 2026-09-02).
        let input = inputMaximal(objectives: "Moins dépenser tous les mois.")
        let sections = CoachBriefingBuilder.sections(input)
        let passes = CoachPassPlanner.plan(sections: sections,
                                           header: CoachBriefingBuilder.condensedHeader(input),
                                           objectivesBlock: CoachBriefingBuilder.objectivesBlock(input),
                                           budget: .compact)
        #expect(passes.count > 1, "ce dossier ne tient pas en une passe étroite")
        #expect(passes.allSatisfy { $0.total == passes.count })
        #expect(passes.map(\.index) == Array(1...passes.count))

        // Chaque section apparaît dans exactement une passe : rien n'est
        // abandonné en route, sinon le découpage ferait disparaître de la
        // matière au lieu de l'étaler.
        for section in sections {
            let carriers = passes.filter { $0.focus.contains(section.title) }
            #expect(carriers.count == 1, "section « \(section.title) » portée par \(carriers.count) passe(s)")
        }
    }

    @Test("Chaque passe porte les chiffres clés ET les objectifs")
    func chaquePassePorteLeContexte() {
        // Une passe qui ne voit que « les marchands » n'a aucune échelle de
        // référence et conseille dans le vide ; une passe qui ne voit pas les
        // objectifs conseille à côté de ce que la personne cherche.
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
        // Le budget par passe n'est pas décoratif : c'est ce qui garantit qu'il
        // reste de la place pour ÉCRIRE la réponse dans une fenêtre de 4 000
        // tokens.
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
        // Des objectifs à rallonge ne doivent pas affamer la matière à analyser.
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

    // MARK: - Fusion des passes

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
        // La version dont le modèle est le plus sûr gagne, jamais « la dernière vue ».
        #expect(merged.first(where: { $0.ref == "abo" })?.title == "Annule Canal+ (vu ailleurs)")
        // L'ordre de première apparition est conservé : le classement final,
        // c'est le rôle de `CoachRanker`, pas celui de la fusion.
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

    // MARK: - Dossier « portefeuille »

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
        // 8 000 / 10 000 : la première ligne pèse 80 % — c'est le risque
        // structurel qu'un particulier ne voit pas de lui-même.
        #expect(text.contains("80 %"), "le poids de la 1re ligne doit apparaître")
        // 2 000 de cash sur 12 000 de capital total ≈ 17 %.
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
        // C'est LE reproche fait à la version précédente. Si cette contrainte
        // disparaît des consignes, le modèle retombe spontanément dans le
        // conseil passe-partout.
        for domain in CoachDomain.allCases {
            let system = CoachPrompt.system(for: domain)
            #expect(system.contains("CHIFFRE PRÉCIS"))
            #expect(system.contains("N'invente AUCUN chiffre"))
            #expect(system.lowercased().contains("json"))
        }
        // Le coach investissement ne doit jamais se transformer en oracle.
        #expect(CoachPrompt.system(for: .investments).contains("Tu ne prédis JAMAIS"))
    }

    @Test("Chaque domaine a son propre réglage de backend IA")
    func domainesEtBackends() {
        #expect(CoachDomain.transactions.aiFeature == .insights)
        #expect(CoachDomain.investments.aiFeature == .investmentCoach)
        // Le rawValue historique doit être conservé, sinon le choix de backend
        // déjà persisté par l'utilisateur est perdu en silence.
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
