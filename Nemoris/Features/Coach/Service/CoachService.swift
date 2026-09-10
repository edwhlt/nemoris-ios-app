import Foundation

// MARK: - CoachService
//
// Orchestrates one analysis: gather the data → build the briefing → query the
// model → parse → persist.
//
// Impure by nature (database + AI). Every decidable piece of logic lives
// outside: `CoachBriefingBuilder`, `InvestmentBriefingBuilder`, `CoachPrompt`,
// `CoachResponseParser` and `CoachRanker` are pure engines, tested separately.
//
// Loading and writing run in a `Task.detached`: one analysis reads up to
// 10,000 transactions, which would block the UI for several hundred
// milliseconds on the main actor. It's the same reason `SearchService` was
// moved off the main actor.

@MainActor
enum CoachService {

    /// Analysis window. 6 months: long enough to establish a trend and spot
    /// drift, short enough that the advice covers the current situation and
    /// not a behavior abandoned since.
    ///
    /// `nonisolated`: read from briefing construction, which runs off the
    /// main actor.
    nonisolated static let analysisMonths = 6

    // MARK: - Analysis

    /// Runs a full analysis for one domain and persists the result.
    /// Never throws: a failure is a `CoachAnalysis` in an error state, which
    /// is displayable.
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
        // The briefing and the requested profile adapt to the RESOLVED
        // backend, not to the user's raw choice: Apple Intelligence has a
        // fixed, non-negotiable context window, while a local server or a
        // cloud provider takes far more — see `CoachContextBudget`.
        let budget = CoachContextBudget.resolved(from: resolvedBackend)

        // The briefing is split into PASSES: a single one when the backend
        // takes everything (historical behavior), several when the window is
        // narrow. See `CoachPassPlanner` for the reasoning.
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

        // ADAPTIVE fallback: the server has just shown its real limit
        // (truncated reasoning, no answer). It couldn't be predicted — the
        // same model succeeds elsewhere — but now that it's known, the
        // analysis is replayed in short passes, which divide the input by
        // ~2.5 and give it room to conclude.
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

        // A response that was READ but carries no recommendation is NOT an
        // error: the model simply has nothing to propose. Conflating the two
        // displayed "the analysis didn't succeed" when everything had gone
        // fine — and buried the real failures under the same message.
        //
        // With multiple passes, one failed pass no longer condemns the
        // analysis: that's the whole point of splitting, each piece succeeds
        // or fails on its own. Failure is reported only if NOTHING came
        // through.
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

    // MARK: - Pass execution

    private struct PassOutcome {
        var drafts: [CoachRecommendationDraft] = []
        var profile: String?
        var failure: CoachResponseParser.Failure?
        /// Raw response of the FIRST failed pass — enough to diagnose
        /// without drowning the user under N responses.
        var rawFailure: String?
        var failedPasses = 0
        var salvaged = false
        /// At least one pass returned reasoning and no answer — the only
        /// failure mode that shrinking the input can recover from.
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

            // GUIDED generation first when Apple Intelligence answers: the
            // schema structurally forbids prose, which is precisely what
            // this backend was returning.
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
                // A partial pass returns no profile; on the single pass, a
                // readable profile stays displayable even on failure.
                if pass.isOnly { outcome.profile = parsed.profileSummary }
                continue
            }
            batches.append(parsed.drafts)
            outcome.salvaged = outcome.salvaged || parsed.wasSalvaged
            if pass.isOnly, let summary = parsed.profileSummary { outcome.profile = summary }
        }

        outcome.drafts = CoachResponseParser.merge(batches)

        // The profile is requested SEPARATELY when the analysis is split:
        // on a narrow window, asking for it alongside the recommendations
        // makes the model arbitrate between the two — and the profile is
        // what gets dropped.
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
        // The key figures head every pass: reusing the first one's avoids
        // rebuilding the briefing once more.
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
        // The "reasoning without an answer" case has already been replayed
        // in short passes with reasoning mode off. If it comes back here,
        // shrinking the input isn't enough: say so, rather than suggesting
        // what the app just tried on its own.
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

    /// Note shown when the analysis succeeded WITHOUT being complete —
    /// saying so beats implying the whole briefing was covered.
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

    // MARK: - Briefings

    /// Builds a domain's passes. `nonisolated`: called from a
    /// `Task.detached`, never on the main actor.
    ///
    /// A single pass on a generous budget (the whole briefing, historical
    /// behavior), several when the context window is narrow. Returns `[]`
    /// when there is no data to analyze.
    nonisolated static func buildPasses(domain: CoachDomain, now: Date,
                                        budget: CoachContextBudget) -> [CoachAnalysisPass] {
        // The goals of the DOMAIN being analyzed, never a shared text:
        // asking the spending coach to serve a diversification goal that no
        // figure in its briefing can inform yields nothing but evasive
        // advice ("wait until your budget is positive before investing").
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

        // The deterministic signals prime the model: no point having it
        // re-derive what an exact computation already knows.
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

        // Activity over the analysis window only: an order placed three
        // years ago doesn't characterize current behavior.
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
