import Foundation

/// AXE B.1 — Orchestrateur qui lance Sirene + Apple Foundation Models + MapKit en parallèle
/// et fusionne les résultats par vote pondéré (confidence × source_weight).
///
/// Stratégie cache :
///   1. Lookup `enrichment_cache` par cacheKey → return immédiat si présent.
///   2. Sinon, lance les 3 sources en parallèle (`async let`), fusionne, persiste.
///
/// Limites :
///   - Sirene : ~7 req/s côté API (gov.fr). Le caller est responsable du rate-limiting
///     pour les imports en batch (`Task.sleep(150ms)` entre appels).
///   - MapKit : lent (500ms-2s par requête). Limites Apple non documentées.
///   - LLM : seulement iOS 18.1+ avec Foundation Models. Sinon no-op.
actor EnrichmentOrchestrator {

    static let shared = EnrichmentOrchestrator()

    private let nafMapper = NAFCategoryMapper.shared
    private let repository = EnrichmentRepository()
    private let txRepository = TransactionRepository()
    private var categoryCache: [String: Int]? = nil  // categoryName lowercased → category_id

    /// Pondération par source pour le vote (somme libre, on normalise pas).
    private static let weights: [MerchantEnrichmentSource: Double] = [
        .sirene: 1.0,   // données officielles, fiables
        .mapkit: 0.7,   // bon pour POI physiques mais bruité
        .llm:    0.6,   // utile pour catégoriser mais peut halluciner
        .merged: 1.0,
        .manual: 2.0    // user prime sur tout
    ]

    // MARK: - Public API

    /// Enrichit un contexte. Cache-first, sinon lance les sources et persiste le résultat fusionné.
    /// Renvoie `nil` si aucune source n'a produit de signal exploitable.
    func enrich(_ context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        let key = context.cacheKey
        // Le cache vit côté MainActor (`Library/Caches` via JSONFileCache),
        // d'où le hop d'actor pour fetch/save.
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
        // Dispatch via le registry de sources entreprises (Sirene FR, Companies House UK,
        // Zefix CH, etc.) — le registry filtre automatiquement par pays.
        let query = context.canonicalName ?? context.rawLabel
        let results = await CompanyDataSourcesRegistry.shared.search(
            query: query,
            country: context.country,
            postalCode: nil
        )
        guard var best = results.first else { return nil }
        // Post-process NAF → categoryId (utile seulement pour Sirene FR)
        if best.categoryId == nil, let naf = best.nafCode,
           let cat = nafMapper.lookup(naf) {
            best.categoryId = findCategoryId(byName: cat.category)
        }
        // Fallback city si la source n'en a pas mais le contexte en a une
        if best.city == nil { best.city = context.city }
        return best
    }

    private func enrichViaLLM(_ context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        // EnrichmentLLMService est @MainActor — le `await` gère le hop d'actor.
        let isAvail = await EnrichmentLLMService.shared.isAvailable
        guard isAvail else { return nil }
        return await EnrichmentLLMService.shared.identify(context: context)
    }

    private func enrichViaMapKit(_ context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        // MapKit ne sert que si on a au moins un nom + idéalement une ville.
        let query = context.canonicalName ?? context.rawLabel
        guard !query.isEmpty else { return nil }
        return await MapKitSearchService.search(query: query, near: context.city)
    }

    // MARK: - Merge (vote pondéré)

    private func merge(candidates: [MerchantEnrichment]) -> MerchantEnrichment {
        // Stratégie simple : pour chaque champ, on prend la valeur du candidat avec
        // le plus haut score (confidence × weight). Source du merged = .merged
        // sauf si un seul candidat → garde sa source.
        if candidates.count == 1, let only = candidates.first { return only }

        func best<T: Equatable>(_ keyPath: KeyPath<MerchantEnrichment, T?>) -> T? {
            candidates
                .filter { $0[keyPath: keyPath] != nil }
                .max { a, b in score(a) < score(b) }?[keyPath: keyPath]
        }

        let topConfidence = candidates.map(score).max() ?? 0
        return MerchantEnrichment(
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
    }

    private func score(_ r: MerchantEnrichment) -> Double {
        r.confidence * (Self.weights[r.source] ?? 1.0)
    }

    // MARK: - Category lookup

    private func findCategoryId(byName name: String) -> Int? {
        let cache = ensureCategoryCache()
        let normalized = name.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        // Match exact, sinon contains
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
