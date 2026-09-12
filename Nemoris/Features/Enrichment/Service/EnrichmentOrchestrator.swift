import Foundation

/// Orchestrator that runs Sirene + Apple Foundation Models + MapKit in parallel
/// and merges the results by weighted vote (confidence × source_weight).
///
/// Cache strategy:
///   1. Look up `enrichment_cache` by cacheKey → return immediately if present.
///   2. Otherwise, run the 3 sources in parallel (`async let`), merge, persist.
///
/// Limits:
///   - Sirene: ~7 req/s on the API side (gov.fr). The caller is responsible for rate-limiting
///     on batch imports (`Task.sleep(150ms)` between calls).
///   - MapKit: slow (500ms-2s per request). Apple's limits are undocumented.
///   - LLM: only iOS 18.1+ with Foundation Models. Otherwise a no-op.
actor EnrichmentOrchestrator {

    static let shared = EnrichmentOrchestrator()

    private let nafMapper = NAFCategoryMapper.shared
    private let repository = EnrichmentRepository()
    private let txRepository = TransactionRepository()
    private var categoryCache: [String: Int]? = nil  // categoryName lowercased → category_id

    /// Per-source weighting for the vote (a free sum, not normalized).
    private static let weights: [MerchantEnrichmentSource: Double] = [
        .sirene:   1.0,   // official data, reliable
        .mapkit:   0.7,   // good for physical POIs but noisy
        .llm:      0.6,   // useful for categorizing but can hallucinate
        .localLLM: 0.6,   // same confidence level as .llm — an AI guessed, can hallucinate
        .merged:   1.0,
        .manual:   2.0    // user always wins over everything
    ]

    // MARK: - Public API

    /// Enriches a context. Cache-first, otherwise runs the sources and persists the merged result.
    /// Returns `nil` if no source produced a usable signal.
    func enrich(_ context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        let key = context.cacheKey
        // The cache lives on the MainActor (`Library/Caches` via JSONFileCache),
        // hence the actor hop to fetch/save.
        if let cached = await repository.fetch(cacheKey: key), cached.hasContent {
            return cached
        }

        async let sireneTask = enrichViaSirene(context)
        async let llmTask = enrichViaLLM(context)
        async let mapkitTask = enrichViaMapKit(context)

        let candidates = await [sireneTask, llmTask, mapkitTask].compactMap { $0 }
        guard !candidates.isEmpty else { return nil }

        let merged = merge(candidates: candidates)
        guard merged.hasContent else { return nil }
        await repository.save(cacheKey: key, result: merged)
        return merged
    }

    // MARK: - Source branches

    private func enrichViaSirene(_ context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        // goes through the planner + the cascade executor instead of sending the
        // whole label in `q=`.
        //
        // Before: `q = canonicalName ?? rawLabel`, i.e. name + city + noise mixed
        // together. But the API matches `q` against the company name and trade names, NEVER against
        // the address: putting the city in doesn't restrict the search, it makes it
        // fail (`q=carrefour market flanches` → 0; `q=carrefour market` → 1907).
        //
        // And the result used to be `results.first` of a `withTaskGroup`
        // concatenation: "first" there meant the COMPLETION order of the network
        // tasks, with no check at all that the candidate matched the label's
        // location. Ranking is now a TOTAL order on explicit criteria.
        let input = MerchantQueryPlanner.Input(
            rawLabel: context.rawLabel,
            engineMerchantCandidate: context.canonicalName,
            engineCityCandidate: context.city,
            engineCountryCandidate: context.country,
            userCountry: context.country
        )
        let result = await MerchantQueryExecutor.shared.search(
            input: input,
            budget: .batch,
            knownNafPrefixes: nafMapper.knownPrefixes
        )
        guard let top = result.companies.first else { return nil }
        // Conversion through the SINGLE path shared with the UI (see `CompanyMatch.enrichment`).
        return top.enrichment(fallbackCity: context.city) { [self] naf in
            nafMapper.lookup(naf).flatMap { findCategoryId(byName: $0.category) }
        }
    }

    private func enrichViaLLM(_ context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        // AIEnrichmentBackend is @MainActor — the `await` handles the actor hop. It's the
        // single dispatch point (Foundation Models vs. a local server configured by
        // the user) shared with EnrichmentSheetView and PayeeCreationFormSheet —
        // don't go back to calling EnrichmentLLMService.shared directly here, that
        // would recreate the divergence AIEnrichmentBackend exists to eliminate.
        await AIEnrichmentBackend.identify(context: context)
    }

    private func enrichViaMapKit(_ context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        // MapKit is only useful if we have at least a name + ideally a city.
        let query = context.canonicalName ?? context.rawLabel
        guard !query.isEmpty else { return nil }
        return await MapKitSearchService.search(query: query, near: context.city)
    }

    // MARK: - Merge (weighted vote)

    private func merge(candidates: [MerchantEnrichment]) -> MerchantEnrichment {
        // Simple strategy: for each field, take the value of the candidate with
        // the highest score (confidence × weight). The merged result's source = .merged
        // unless there's only one candidate → keeps its source.
        if candidates.count == 1, let only = candidates.first {
            return resolvingCategoryHint(only)
        }

        func best<T: Equatable>(_ keyPath: KeyPath<MerchantEnrichment, T?>) -> T? {
            candidates
                .filter { $0[keyPath: keyPath] != nil }
                .max { a, b in score(a) < score(b) }?[keyPath: keyPath]
        }

        let topConfidence = candidates.map(score).max() ?? 0
        var merged = MerchantEnrichment(
            displayName: best(\.displayName),
            domain: best(\.domain),
            categoryId: best(\.categoryId),
            address: best(\.address),
            city: best(\.city),
            country: best(\.country),
            latitude: best(\.latitude),
            longitude: best(\.longitude),
            phone: best(\.phone),
            siret: best(\.siret),
            nafCode: best(\.nafCode),
            source: .merged,
            confidence: min(1.0, topConfidence),
            enrichedAt: Date()
        )
        // Fields not in the memberwise initializer (default values).
        // Forgetting them here makes them disappear as soon as there's more than one candidate —
        // that's exactly what used to happen to `searchHint`, the only usable
        // information the LLM produces when it doesn't recognize the merchant.
        merged.searchHint   = best(\.searchHint)
        merged.siren        = best(\.siren)
        merged.postalCode   = best(\.postalCode)
        merged.categoryHint = best(\.categoryHint)
        return resolvingCategoryHint(merged)
    }

    /// A source with no access to the reference data (the LLM) can only propose a category
    /// NAME — "Groceries", not `category_id = 7`. We resolve it here, where the repo
    /// is available. Without this, the category the AI guessed was decoded then discarded.
    /// Applied on BOTH paths of `merge`: a single LLM candidate is exactly
    /// the case where its category is the only one we have.
    private func resolvingCategoryHint(_ result: MerchantEnrichment) -> MerchantEnrichment {
        guard result.categoryId == nil, let hint = result.categoryHint else { return result }
        var out = result
        out.categoryId = findCategoryId(byName: hint)
        return out
    }

    private func score(_ r: MerchantEnrichment) -> Double {
        r.confidence * (Self.weights[r.source] ?? 1.0)
    }

    // MARK: - Category lookup

    private func findCategoryId(byName name: String) -> Int? {
        let cache = ensureCategoryCache()
        let normalized = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        // Exact match, otherwise contains
        if let id = cache[normalized] { return id }
        for (key, id) in cache where key.contains(normalized) || normalized.contains(key) {
            return id
        }
        return nil
    }

    private func ensureCategoryCache() -> [String: Int] {
        if let cache = categoryCache { return cache }
        let categories = txRepository.fetchCategories()
        var map: [String: Int] = [:]
        for c in categories {
            let key = c.name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
            map[key] = c.id
        }
        categoryCache = map
        return map
    }
}
