import Foundation

/// Runs the cascade planned by `MerchantQueryPlanner`.
///
/// A full chain, one direction, no cycles:
///
///     extract (pure) → resolve (async, cached) → plan (pure) → execute → rank (pure)
///
/// The executor DECIDES nothing: the plan says what to try and in what order, the budget
/// says when to stop, the ranker says who wins. Here we only call and count.
/// That's what makes the logic testable without a network.
actor MerchantQueryExecutor {

    static let shared = MerchantQueryExecutor()

    private let registry = CompanyRegistryClient.shared
    private let resolver = GeoCommuneResolver.shared

    // MARK: - API

    /// Plans then executes. `knownNafPrefixes` is passed as data so the ranker
    /// stays pure (it has no access to the NAF bundle).
    func search(input: MerchantQueryPlanner.Input,
                budget: SearchBudget = .interactive,
                knownNafPrefixes: Set<String> = []) async -> MerchantSearchResult {
        let started = Date()
        let extraction = MerchantQueryPlanner.extract(input)

        // Resolving the commune BEFORE planning: the plan needs to know its
        // filters to exist (see `LocalityResolver`'s rationale).
        var usage = SearchBudget.Usage()
        var locality: ResolvedLocality?
        if !extraction.localityTokens.isEmpty, !extraction.degenerate,
           !extraction.isPersonNotBusiness {
            locality = await resolver.resolve(extraction.localityTokens,
                                              countryHint: extraction.countryHint)
        }

        let options = MerchantQueryPlanner.Options(
            maxAttempts: budget.maxAttempts,
            includeCeased: budget.includeCeased,
            allowPlaces: budget.allowPlaces,
            matchingLimit: budget.matchingLimit
        )
        let plan = MerchantQueryPlanner.plan(extraction: extraction, locality: locality,
                                             options: options)

        var context = plan.ranking
        if !knownNafPrefixes.isEmpty {
            context = RankingContext(
                nameTokens: context.nameTokens,
                freeLocalityText: context.freeLocalityText,
                inseeCode: context.inseeCode,
                postalCodes: context.postalCodes,
                departmentCode: context.departmentCode,
                cityLabel: context.cityLabel,
                knownNafPrefixes: knownNafPrefixes
            )
        }

        var outcomes: [SearchAttemptOutcome] = []
        // Accumulator deduplicated by SIREN across ALL attempts: ranking
        // happens on the final union, never on "first one in".
        var pool: [String: CompanyMatch] = [:]

        for attempt in plan.attempts {
            if usage.requests >= budget.maxRequests {
                outcomes.append(.init(attemptId: attempt.id, status: .skipped("budget épuisé"),
                                      resultCount: 0, elapsed: 0))
                continue
            }
            if Date().timeIntervalSince(started) > budget.deadline {
                outcomes.append(.init(attemptId: attempt.id, status: .skipped("délai dépassé"),
                                      resultCount: 0, elapsed: 0))
                continue
            }
            // Short-circuit 1→2→3: if the commune filter already returned something, no
            // point retrying with a broader filter — we'd get the same results, less precise.
            if shouldSkipBroaderGeo(attempt, pool: pool, plan: plan) {
                outcomes.append(.init(attemptId: attempt.id,
                                      status: .skipped("filtre plus précis déjà concluant"),
                                      resultCount: 0, elapsed: 0))
                continue
            }
            // Proximity and closed companies: last resort only.
            if isLastResort(attempt), !pool.isEmpty {
                outcomes.append(.init(attemptId: attempt.id,
                                      status: .skipped("des candidats ont déjà été trouvés"),
                                      resultCount: 0, elapsed: 0))
                continue
            }

            // The map search is driven by the view (MapKit needs the main
            // actor). The executor leaves it in the plan so the UI knows what to run,
            // but doesn't count it as a request: it doesn't fire from here.
            if case .placeText = attempt.kind {
                outcomes.append(.init(attemptId: attempt.id,
                                      status: .skipped("déléguée à la carte"),
                                      resultCount: 0, elapsed: 0))
                continue
            }

            let attemptStart = Date()
            do {
                let found = try await run(attempt)
                usage.requests += 1
                for match in found { pool[match.siren] = pool[match.siren] ?? match }
                outcomes.append(.init(attemptId: attempt.id, status: .ok,
                                      resultCount: found.count,
                                      elapsed: Date().timeIntervalSince(attemptStart)))

                // Quality short-circuit: a very good candidate AND geographically
                // confirmed makes the remaining attempts pointless.
                if isGoodEnough(pool: pool, context: context) { break }
            } catch {
                usage.requests += 1
                outcomes.append(.init(attemptId: attempt.id,
                                      status: .failed(error.localizedDescription),
                                      resultCount: 0,
                                      elapsed: Date().timeIntervalSince(attemptStart)))
            }
        }

        usage.elapsed = Date().timeIntervalSince(started)
        let ranked = rank(pool: Array(pool.values), context: context)
        return MerchantSearchResult(plan: plan, outcomes: outcomes,
                                    companies: ranked, budgetUsed: usage)
    }

    // MARK: - Running one attempt

    private func run(_ attempt: SearchAttempt) async throws -> [CompanyMatch] {
        switch attempt.kind {
        case .companyRegistry(let query):
            return try await registry.search(query)
        case .companyRegistryNearPoint(let lat, let lon, let radius, let perPage):
            return try await registry.searchNearPoint(latitude: lat, longitude: lon,
                                                      radiusKm: radius, perPage: perPage)
        case .placeText:
            // The map search is driven by MapKit on the UI side (it needs the
            // main actor and its own result model). The executor only handles
            // company registries.
            return []
        }
    }

    // MARK: - Short-circuit rules

    private func shouldSkipBroaderGeo(_ attempt: SearchAttempt,
                                      pool: [String: CompanyMatch],
                                      plan: MerchantQueryPlan) -> Bool {
        guard !pool.isEmpty, case .companyRegistry(let query) = attempt.kind else { return false }
        // A filter broader than one that already returned something adds nothing.
        let isBroader = query.codePostal != nil || query.departement != nil
        return isBroader && plan.locality?.inseeCode != nil
    }

    private func isLastResort(_ attempt: SearchAttempt) -> Bool {
        switch attempt.kind {
        case .companyRegistryNearPoint:
            return true
        case .companyRegistry(let query):
            return query.etatAdministratif == nil   // a replay including closed ones
        case .placeText:
            return false
        }
    }

    /// A candidate good enough AND geographically confirmed stops the cascade.
    /// Thresholds deliberately high: continuing costs a request, stopping too soon
    /// costs the right result.
    private func isGoodEnough(pool: [String: CompanyMatch], context: RankingContext) -> Bool {
        let ranked = rank(pool: Array(pool.values), context: context)
        guard let best = ranked.first, let top = best.rankedEstablishments.first else { return false }
        return top.score >= 0.80 && top.breakdown.localityMatch >= 0.9
    }

    // MARK: - Ranking

    private func rank(pool: [CompanyMatch], context: RankingContext) -> [RankedCompany] {
        let query = context.nameTokens
        let ranked: [RankedCompany] = pool.map { match in
            let viaEnseigne = match.matchedViaEnseigne(query: query)
            let companyNames = [match.legalName, match.nomComplet].compactMap { $0 }
            let candidates = match.allEstablishments.map {
                $0.rankable(providerWeight: 1.0, matchedViaEnseigne: viaEnseigne,
                            companyNames: companyNames)
            }
            let rankedEstablishments = CandidateRanker.rank(candidates, context: context)
            // A company's score is that of its BEST establishment: we're
            // after the right storefront, not the head office.
            let companyScore = rankedEstablishments.first?.score
                ?? CandidateRanker.score(
                    RankableCandidate(id: match.siren, names: match.searchableNames),
                    context: context
                ).weightedTotal
            return RankedCompany(match: match, score: companyScore,
                                 rankedEstablishments: rankedEstablishments)
        }
        // A TOTAL order, as with establishments: never a residual tie, so
        // never a dependency on network arrival order.
        return ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.match.isActive != rhs.match.isActive { return lhs.match.isActive }
            return lhs.match.siren < rhs.match.siren
        }
    }
}

// MARK: - Result

struct SearchAttemptOutcome: Sendable, Identifiable {
    enum Status: Sendable, Equatable {
        case ok
        case skipped(String)
        case failed(String)

        /// FR wording shown in "Search details".
        var label: String {
            switch self {
            case .ok: return "exécutée"
            case .skipped(let reason): return "ignorée — \(reason)"
            case .failed(let reason): return "échec — \(reason)"
            }
        }
    }

    let attemptId: Int
    let status: Status
    let resultCount: Int
    let elapsed: TimeInterval

    var id: Int { attemptId }
}

struct RankedCompany: Sendable, Identifiable {
    let match: CompanyMatch
    let score: Double
    let rankedEstablishments: [RankedCandidate]

    var id: String { match.siren }

    /// The most plausible establishment for this label.
    var bestEstablishment: Establishment? {
        guard let top = rankedEstablishments.first else { return match.headquarters }
        return match.allEstablishments.first { $0.id == top.candidate.id }
    }
}

/// Everything the UI needs to know: the plan (so the attempts and the removed
/// tokens), what actually ran, and the ranked results.
struct MerchantSearchResult: Sendable {
    let plan: MerchantQueryPlan
    let outcomes: [SearchAttemptOutcome]
    let companies: [RankedCompany]
    let budgetUsed: SearchBudget.Usage

    var isEmpty: Bool { companies.isEmpty }

    /// Displayable cost summary: "3 requests · 0.8s".
    var costSummary: String {
        let requests = budgetUsed.requests
        let seconds = String(format: "%.1f", budgetUsed.elapsed)
        return "\(requests) requête\(requests > 1 ? "s" : "") · \(seconds) s"
    }
}
