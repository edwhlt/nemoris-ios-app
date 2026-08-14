import Foundation

/// Exécute la cascade planifiée par `MerchantQueryPlanner`.
///
/// Chaîne complète, une seule direction, aucun cycle :
///
///     extract (pur) → resolve (async, caché) → plan (pur) → execute → rank (pur)
///
/// L'exécuteur ne DÉCIDE de rien : le plan dit quoi tenter et dans quel ordre, le budget
/// dit quand s'arrêter, le ranker dit qui gagne. Ici on ne fait qu'appeler et compter.
/// C'est ce qui rend la logique testable sans réseau.
actor MerchantQueryExecutor {

    static let shared = MerchantQueryExecutor()

    private let registry = CompanyRegistryClient.shared
    private let resolver = GeoCommuneResolver.shared

    // MARK: - API

    /// Planifie puis exécute. `knownNafPrefixes` est passé en donnée pour que le ranker
    /// reste pur (il n'a pas accès au bundle NAF).
    func search(input: MerchantQueryPlanner.Input,
                budget: SearchBudget = .interactive,
                knownNafPrefixes: Set<String> = []) async -> MerchantSearchResult {
        let started = Date()
        let extraction = MerchantQueryPlanner.extract(input)

        // Résolution de la commune AVANT la planification : le plan doit connaître ses
        // filtres pour exister (cf. l'argumentaire de `LocalityResolver`).
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
        // Accumulateur dédupliqué par SIREN sur TOUTES les tentatives : le classement se
        // fait sur l'union finale, jamais sur « le premier arrivé ».
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
            // Court-circuit 1→2→3 : si le filtre commune a donné, inutile de retenter avec
            // un filtre plus large — on aurait les mêmes résultats en moins précis.
            if shouldSkipBroaderGeo(attempt, pool: pool, plan: plan) {
                outcomes.append(.init(attemptId: attempt.id,
                                      status: .skipped("filtre plus précis déjà concluant"),
                                      resultCount: 0, elapsed: 0))
                continue
            }
            // Proximité et entreprises fermées : dernier recours seulement.
            if isLastResort(attempt), !pool.isEmpty {
                outcomes.append(.init(attemptId: attempt.id,
                                      status: .skipped("des candidats ont déjà été trouvés"),
                                      resultCount: 0, elapsed: 0))
                continue
            }

            // La recherche cartographique est portée par la vue (MapKit a besoin du main
            // actor). L'exécuteur la laisse dans le plan pour que l'UI sache quoi lancer,
            // mais ne la compte pas comme une requête : elle ne part pas d'ici.
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

                // Court-circuit sur la qualité : un candidat très bon ET géographiquement
                // confirmé rend les tentatives suivantes inutiles.
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

    // MARK: - Exécution d'une tentative

    private func run(_ attempt: SearchAttempt) async throws -> [CompanyMatch] {
        switch attempt.kind {
        case .companyRegistry(let query):
            return try await registry.search(query)
        case .companyRegistryNearPoint(let lat, let lon, let radius, let perPage):
            return try await registry.searchNearPoint(latitude: lat, longitude: lon,
                                                      radiusKm: radius, perPage: perPage)
        case .placeText:
            // La recherche cartographique est portée par MapKit côté UI (elle a besoin du
            // main actor et de son propre modèle de résultat). L'exécuteur ne traite que
            // les registres d'entreprises.
            return []
        }
    }

    // MARK: - Règles de court-circuit

    private func shouldSkipBroaderGeo(_ attempt: SearchAttempt,
                                      pool: [String: CompanyMatch],
                                      plan: MerchantQueryPlan) -> Bool {
        guard !pool.isEmpty, case .companyRegistry(let query) = attempt.kind else { return false }
        // Un filtre plus large que celui qui a déjà donné n'apporte rien.
        let isBroader = query.codePostal != nil || query.departement != nil
        return isBroader && plan.locality?.inseeCode != nil
    }

    private func isLastResort(_ attempt: SearchAttempt) -> Bool {
        switch attempt.kind {
        case .companyRegistryNearPoint:
            return true
        case .companyRegistry(let query):
            return query.etatAdministratif == nil   // rejeu incluant les fermées
        case .placeText:
            return false
        }
    }

    /// Un candidat suffisamment bon ET géographiquement confirmé arrête la cascade.
    /// Seuils volontairement élevés : continuer coûte une requête, s'arrêter trop tôt
    /// coûte le bon résultat.
    private func isGoodEnough(pool: [String: CompanyMatch], context: RankingContext) -> Bool {
        let ranked = rank(pool: Array(pool.values), context: context)
        guard let best = ranked.first, let top = best.rankedEstablishments.first else { return false }
        return top.score >= 0.80 && top.breakdown.localityMatch >= 0.9
    }

    // MARK: - Classement

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
            // Le score d'une entreprise est celui de son MEILLEUR établissement : c'est la
            // bonne boutique qu'on cherche, pas le siège social.
            let companyScore = rankedEstablishments.first?.score
                ?? CandidateRanker.score(
                    RankableCandidate(id: match.siren, names: match.searchableNames),
                    context: context
                ).weightedTotal
            return RankedCompany(match: match, score: companyScore,
                                 rankedEstablishments: rankedEstablishments)
        }
        // Ordre TOTAL, comme pour les établissements : jamais d'égalité résiduelle, donc
        // jamais de dépendance à l'ordre d'arrivée réseau.
        return ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.match.isActive != rhs.match.isActive { return lhs.match.isActive }
            return lhs.match.siren < rhs.match.siren
        }
    }
}

// MARK: - Résultat

struct SearchAttemptOutcome: Sendable, Identifiable {
    enum Status: Sendable, Equatable {
        case ok
        case skipped(String)
        case failed(String)

        /// Libellé FR affiché dans « Détails de la recherche ».
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

    /// L'établissement le plus plausible pour ce libellé.
    var bestEstablishment: Establishment? {
        guard let top = rankedEstablishments.first else { return match.headquarters }
        return match.allEstablishments.first { $0.id == top.candidate.id }
    }
}

/// Tout ce que l'UI a besoin de savoir : le plan (donc les tentatives et les jetons
/// retirés), ce qui a réellement tourné, et les résultats classés.
struct MerchantSearchResult: Sendable {
    let plan: MerchantQueryPlan
    let outcomes: [SearchAttemptOutcome]
    let companies: [RankedCompany]
    let budgetUsed: SearchBudget.Usage

    var isEmpty: Bool { companies.isEmpty }

    /// Résumé de coût affichable : « 3 requêtes · 0,8 s ».
    var costSummary: String {
        let requests = budgetUsed.requests
        let seconds = String(format: "%.1f", budgetUsed.elapsed)
        return "\(requests) requête\(requests > 1 ? "s" : "") · \(seconds) s"
    }
}
