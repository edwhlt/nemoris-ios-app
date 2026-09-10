import Foundation

// MARK: - CoachService
//
// Orchestration d'une analyse : rassembler les données → construire le dossier
// → interroger le modèle → parser → persister.
//
// Impur par nature (base + IA). Toute la logique décidable est en dehors :
// `CoachBriefingBuilder`, `InvestmentBriefingBuilder`, `CoachPrompt`,
// `CoachResponseParser`, `CoachRanker` sont des moteurs purs testés à part.
//
// ⚠️ Le chargement des données et l'écriture tournent en `Task.detached` : une
// analyse lit jusqu'à 10 000 transactions, ce qui bloquerait l'UI pendant
// plusieurs centaines de millisecondes sur le main actor. C'est la même raison
// qui avait fait sortir `SearchService` du main actor (gels macOS documentés).

@MainActor
enum CoachService {

    /// Fenêtre d'analyse. 6 mois : assez pour dégager une tendance et repérer
    /// une dérive, assez court pour que les conseils portent sur la situation
    /// actuelle et non sur un comportement abandonné depuis.
    ///
    /// `nonisolated` : lu depuis la construction des dossiers, qui tourne hors
    /// du main actor.
    nonisolated static let analysisMonths = 6

    // MARK: - Analyse

    /// Lance une analyse complète pour un domaine et persiste le résultat.
    /// Ne lève jamais : un échec est un `CoachAnalysis` en erreur, affichable.
    static func analyze(domain: CoachDomain, now: Date = Date()) async -> CoachAnalysis {
        guard AIEnrichmentBackend.isAvailable(for: domain.aiFeature) else {
            let reason = AIEnrichmentBackend.unavailabilityReason(for: domain.aiFeature)
                ?? "Aucune source d'IA disponible."
            let failed = CoachAnalysis(domain: domain, profileSummary: nil, generatedAt: nil,
                                       isError: true, message: reason, backend: nil, rawResponse: nil)
            await persist(analysis: failed)
            return failed
        }
        let resolvedBackend = AIEnrichmentBackend.resolved(for: domain.aiFeature)
        let backendLabel = resolvedBackend?.displayName
        // Le dossier et le profil demandé s'adaptent au backend RÉSOLU, pas au
        // choix brut de l'utilisateur : Apple Intelligence a une fenêtre de
        // contexte fixe et non négociable, un serveur local ou un fournisseur
        // cloud encaisse largement plus — cf. `CoachContextBudget`.
        let budget = CoachContextBudget.resolved(from: resolvedBackend)

        // Le dossier est découpé en PASSES : une seule quand le backend
        // encaisse tout (comportement historique), plusieurs quand la fenêtre
        // est étroite. Cf. `CoachPassPlanner` pour le pourquoi.
        let passes = await Task.detached(priority: .utility) {
            buildPasses(domain: domain, now: now, budget: budget)
        }.value

        guard !passes.isEmpty else {
            let failed = CoachAnalysis(domain: domain, profileSummary: nil, generatedAt: nil,
                                       isError: true,
                                       message: "Pas assez de données pour analyser ce domaine.",
                                       backend: backendLabel, rawResponse: nil)
            await persist(analysis: failed)
            return failed
        }

        var outcome = await run(passes: passes, domain: domain, budget: budget)
        var passCount = passes.count
        var degraded = false

        // Repli ADAPTATIF : le serveur vient de montrer sa vraie limite (du
        // raisonnement tronqué, aucune réponse). On ne l'a pas deviné à
        // l'avance — le même modèle réussit ailleurs — mais maintenant qu'on
        // le sait, on rejoue en passes courtes, qui divisent l'entrée par
        // ~2,5 et lui rendent de quoi conclure.
        if CoachContextBudget.shouldRetryInPasses(budget: budget,
                                                  sawReasoningOnly: outcome.sawReasoningOnly,
                                                  producedRecommendations: !outcome.drafts.isEmpty,
                                                  alreadyRetried: false) {
            let shortPasses = await Task.detached(priority: .utility) {
                buildPasses(domain: domain, now: now, budget: .compact)
            }.value
            if !shortPasses.isEmpty {
                degraded = true
                passCount = shortPasses.count
                outcome = await run(passes: shortPasses, domain: domain, budget: .compact,
                                    forceDirectAnswer: true)
            }
        }

        // ⚠️ Une réponse LUE mais sans recommandation n'est PAS une erreur :
        // c'est le modèle qui n'a rien à proposer. Les confondre affichait
        // « l'analyse n'a pas abouti » alors que tout s'était bien passé — et
        // empêchait de diagnostiquer les vrais échecs, noyés dans le même
        // message (retour d'usage 2026-08-28).
        //
        // ⚠️ En multi-passe, une passe en échec ne condamne PLUS l'analyse :
        // c'est tout l'intérêt du découpage, chaque morceau réussit ou échoue
        // pour son compte. On n'échoue que si RIEN n'a abouti.
        if outcome.drafts.isEmpty, let failure = outcome.failure {
            let failed = CoachAnalysis(domain: domain, profileSummary: outcome.profile,
                                       generatedAt: nil, isError: true,
                                       message: message(for: failure, passes: passCount,
                                                        sawReasoningOnly: outcome.sawReasoningOnly),
                                       backend: backendLabel,
                                       rawResponse: outcome.rawFailure.map { String($0.prefix(4_000)) })
            await persist(analysis: failed)
            return failed
        }

        let analysis = CoachAnalysis(domain: domain, profileSummary: outcome.profile,
                                     generatedAt: now, isError: false,
                                     message: partialNote(outcome, passes: passCount, degraded: degraded),
                                     backend: backendLabel, rawResponse: nil)
        let drafts = outcome.drafts
        await Task.detached(priority: .utility) {
            CoachRepository.shared.replaceRecommendations(domain: domain, drafts: drafts, now: now)
            CoachRepository.shared.saveAnalysis(analysis)
        }.value
        return analysis
    }

    // MARK: - Exécution des passes

    private struct PassOutcome {
        var drafts: [CoachRecommendationDraft] = []
        var profile: String?
        var failure: CoachResponseParser.Failure?
        /// Réponse brute de la PREMIÈRE passe en échec — de quoi diagnostiquer
        /// sans noyer l'utilisateur sous N réponses.
        var rawFailure: String?
        var failedPasses = 0
        var salvaged = false
        /// Au moins une passe a rendu du raisonnement et aucune réponse — le
        /// seul motif d'échec qui se rattrape en réduisant l'entrée.
        var sawReasoningOnly = false
    }

    private static func run(passes: [CoachAnalysisPass],
                            domain: CoachDomain,
                            budget: CoachContextBudget,
                            forceDirectAnswer: Bool = false) async -> PassOutcome {
        var outcome = PassOutcome()
        var batches: [[CoachRecommendationDraft]] = []

        for pass in passes {
            let system = pass.isOnly
                ? CoachPrompt.system(for: domain, budget: budget)
                : CoachPrompt.partialSystem(for: domain, pass: pass)
            let user = pass.isOnly
                ? CoachPrompt.user(briefing: pass.body)
                : pass.body

            // Génération GUIDÉE d'abord quand c'est Apple Intelligence qui
            // répond : le schéma interdit structurellement la prose, qui est
            // précisément ce que rendait ce backend.
            if let guided = await CoachGuidedGeneration.recommendations(
                system: system, user: user, feature: domain.aiFeature) {
                batches.append(guided)
                continue
            }

            let completion = await AIEnrichmentBackend.complete(
                feature: domain.aiFeature, system: system, user: user,
                forceDirectAnswer: forceDirectAnswer)
            if completion.isReasoningOnly { outcome.sawReasoningOnly = true }

            guard let raw = completion.text, !raw.isEmpty else {
                outcome.failedPasses += 1
                if outcome.failure == nil { outcome.failure = .unreadable }
                continue
            }

            let parsed = CoachResponseParser.parse(raw)
            if let failure = parsed.failure, parsed.drafts.isEmpty {
                outcome.failedPasses += 1
                if outcome.failure == nil {
                    outcome.failure = failure
                    outcome.rawFailure = raw
                }
                // Une passe partielle ne rend pas de profil ; sur la passe
                // unique, un profil lisible reste affichable même en échec.
                if pass.isOnly { outcome.profile = parsed.profileSummary }
                continue
            }
            batches.append(parsed.drafts)
            outcome.salvaged = outcome.salvaged || parsed.wasSalvaged
            if pass.isOnly, let summary = parsed.profileSummary { outcome.profile = summary }
        }

        outcome.drafts = CoachResponseParser.merge(batches)

        // Le profil est demandé À PART quand l'analyse est découpée : sur une
        // fenêtre étroite, le réclamer en même temps que les recommandations
        // revient à faire arbitrer le modèle entre les deux — et c'est le
        // profil qui saute.
        if passes.count > 1, !outcome.drafts.isEmpty {
            outcome.profile = await runProfilePass(domain: domain, passes: passes,
                                                   drafts: outcome.drafts,
                                                   forceDirectAnswer: forceDirectAnswer)
        }
        return outcome
    }

    private static func runProfilePass(domain: CoachDomain,
                                       passes: [CoachAnalysisPass],
                                       drafts: [CoachRecommendationDraft],
                                       forceDirectAnswer: Bool) async -> String? {
        // Les chiffres clés sont en tête de chaque passe : les reprendre de la
        // première évite de reconstruire le dossier une fois de plus.
        let header = passes[0].body.components(separatedBy: "\n\n").first ?? ""
        let system = CoachPrompt.profileSystem(for: domain)
        let user = CoachPrompt.profileUser(header: header, titles: drafts.prefix(10).map(\.title))

        if let guided = await CoachGuidedGeneration.profile(system: system, user: user,
                                                            feature: domain.aiFeature) {
            return guided
        }
        let completion = await AIEnrichmentBackend.complete(
            feature: domain.aiFeature, system: system, user: user,
            forceDirectAnswer: forceDirectAnswer)
        guard let raw = completion.text, !raw.isEmpty, !completion.isReasoningOnly else { return nil }
        return CoachResponseParser.parseProfileOnly(raw)
    }

    // MARK: - Messages

    private static func message(for failure: CoachResponseParser.Failure, passes: Int,
                                sawReasoningOnly: Bool) -> String {
        // Le cas « raisonnement sans réponse » a déjà été rejoué en passes
        // courtes, mode raisonnement coupé. S'il revient ici, réduire l'entrée
        // ne suffit pas : le dire, plutôt que de reproposer ce qu'on vient
        // d'essayer tout seul.
        if sawReasoningOnly {
            return "Ce modèle réfléchit sans jamais écrire sa réponse : il dépense tout son budget en réflexion interne. L'app a déjà réessayé avec un dossier découpé en \(passes) extraits courts et le mode raisonnement coupé, sans succès — la réflexion brute est consultable ci-dessous. Dans ton serveur, augmente la longueur de contexte du modèle chargé (LM Studio : ⚙️ du modèle → « Context Length »), ou désactive son mode « Reasoning ». Un modèle sans mode raisonnement fonctionnera aussi."
        }
        let scope = passes > 1
            ? "Aucun des \(passes) extraits du dossier n'a produit de conseil exploitable. "
            : ""
        switch failure {
        case .unreadable:
            return scope + "Le modèle a répondu, mais sa réponse ne contenait aucun JSON exploitable — c'est souvent un modèle trop petit pour tenir le format demandé. La réponse brute est consultable ci-dessous. Essaie un modèle plus gros, ou un autre backend dans Réglages → Intelligence artificielle."
        case .missingList:
            return scope + "Le modèle a répondu sans fournir de liste de recommandations. Relance l'analyse, ou essaie un autre backend."
        case .truncatedBeforeRecommendations:
            return scope + "Le modèle a été coupé avant d'écrire la moindre recommandation : il a dépensé tout son budget de réponse dans son préambule. Il faut un modèle capable de produire une réponse plus longue (Réglages → Intelligence artificielle)."
        }
    }

    /// Note affichée quand l'analyse a abouti SANS être complète — le dire
    /// vaut mieux que de laisser croire à un dossier entièrement couvert.
    private static func partialNote(_ outcome: PassOutcome, passes: Int, degraded: Bool) -> String? {
        if degraded {
            let missed = outcome.failedPasses > 0 ? " (\(outcome.failedPasses) extrait(s) sans résultat)" : ""
            return "Ton modèle a d'abord réfléchi sans conclure : l'analyse a été relancée sur \(passes) extraits courts\(missed). Pour l'éviter, augmente la longueur de contexte du modèle dans ton serveur."
        }
        if outcome.failedPasses > 0 {
            return "Analyse en \(passes) extraits : \(outcome.failedPasses) n'ont rien donné, les autres ont produit \(outcome.drafts.count) recommandation(s)."
        }
        if outcome.salvaged {
            return "Réponse tronquée par le modèle : \(outcome.drafts.count) recommandation(s) ont pu être récupérées, il en manque probablement."
        }
        return nil
    }

    private static func persist(analysis: CoachAnalysis) async {
        await Task.detached(priority: .utility) {
            CoachRepository.shared.saveAnalysis(analysis)
        }.value
    }

    // MARK: - Dossiers

    /// Construit les passes d'un domaine. `nonisolated` : appelé depuis un
    /// `Task.detached`, jamais sur le main actor.
    ///
    /// Une passe unique en budget généreux (le dossier entier, comportement
    /// historique), plusieurs quand la fenêtre de contexte est étroite.
    /// Retourne `[]` quand il n'y a pas de données à analyser.
    nonisolated static func buildPasses(domain: CoachDomain, now: Date,
                                        budget: CoachContextBudget) -> [CoachAnalysisPass] {
        // Les objectifs du DOMAINE analysé, jamais un texte partagé : demander
        // au coach dépenses de servir un objectif de diversification, qu'aucun
        // chiffre de son dossier ne peut éclairer, ne produit qu'un conseil
        // d'évitement (« attends d'avoir un budget positif pour investir »).
        let objectives = CoachRepository.shared.fetchProfile(domain: domain).objectives
        switch domain {
        case .transactions: return transactionsPasses(objectives: objectives, now: now, budget: budget)
        case .investments:  return investmentsPasses(objectives: objectives, now: now, budget: budget)
        }
    }

    private nonisolated static func transactionsPasses(objectives: String, now: Date,
                                                       budget: CoachContextBudget) -> [CoachAnalysisPass] {
        let cal = Calendar(identifier: .gregorian)
        guard let from = cal.date(byAdding: .month, value: -analysisMonths, to: now) else { return [] }
        let txRepo = TransactionRepository()
        let transactions = txRepo.fetchTransactionsAllAccounts(from: from, to: now, limit: 10_000, offset: 0)
        guard !transactions.isEmpty else { return [] }

        // Les signaux déterministes servent d'amorce au modèle : inutile qu'il
        // re-déduise ce qu'un calcul exact sait déjà.
        let signals = InsightEngine.compute(txRepo: txRepo, now: now).map { insight in
            String(localized: insight.title)
        }

        let input = CoachBriefingBuilder.Input(
            transactions: transactions,
            categories: txRepo.fetchCategories(),
            tiers: txRepo.fetchTiers(),
            patterns: BudgetRepository.shared.fetchActivePatterns(),
            envelopes: BudgetRepository.shared.fetchEnvelopes(),
            signals: signals,
            objectives: objectives,
            now: now
        )
        return CoachPassPlanner.plan(sections: CoachBriefingBuilder.sections(input),
                                     header: CoachBriefingBuilder.condensedHeader(input),
                                     objectivesBlock: CoachBriefingBuilder.objectivesBlock(input),
                                     budget: budget)
    }

    private nonisolated static func investmentsPasses(objectives: String, now: Date,
                                                      budget: CoachContextBudget) -> [CoachAnalysisPass] {
        let repo = InvestmentRepository()
        let accounts = repo.fetchAccounts()
        guard !accounts.isEmpty else { return [] }

        var positions: [InvestmentPosition] = []
        for account in accounts {
            positions.append(contentsOf: repo.fetchPositions(accountId: account.id))
        }
        guard !positions.isEmpty else { return [] }

        // Activité sur la fenêtre d'analyse seulement : un ordre passé il y a
        // trois ans ne caractérise pas le comportement actuel.
        let cal = Calendar(identifier: .gregorian)
        let since = cal.date(byAdding: .month, value: -analysisMonths, to: now) ?? now
        var recentOrders: [InvestmentOrder] = []
        for position in positions {
            recentOrders.append(contentsOf: repo.fetchOrders(positionId: position.id).filter { $0.executedAt >= since })
        }

        let input = InvestmentBriefingBuilder.Input(
            accounts: accounts,
            positions: positions,
            recentOrders: recentOrders,
            objectives: objectives,
            now: now
        )
        return CoachPassPlanner.plan(sections: InvestmentBriefingBuilder.sections(input),
                                     header: InvestmentBriefingBuilder.condensedHeader(input),
                                     objectivesBlock: InvestmentBriefingBuilder.objectivesBlock(input),
                                     budget: budget)
    }
}
