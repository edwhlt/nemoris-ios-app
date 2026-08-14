import Foundation

/// Orchestrateur qui lance Sirene + Apple Foundation Models + MapKit en parallèle
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
        .sirene:   1.0,   // données officielles, fiables
        .mapkit:   0.7,   // bon pour POI physiques mais bruité
        .llm:      0.6,   // utile pour catégoriser mais peut halluciner
        .localLLM: 0.6,   // même niveau de confiance que .llm — une IA a deviné, peut halluciner
        .merged:   1.0,
        .manual:   2.0    // user prime sur tout
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
        // passe par le planificateur + l'exécuteur de cascade au lieu d'envoyer le
        // libellé entier dans `q=`.
        //
        // Avant : `q = canonicalName ?? rawLabel`, c'est-à-dire nom + ville + bruit mélangés.
        // Or l'API matche `q` contre la raison sociale et les enseignes, JAMAIS contre
        // l'adresse : mettre la ville dedans ne restreint pas la recherche, elle la fait
        // échouer (`q=carrefour market flanches` → 0 ; `q=carrefour market` → 1907).
        //
        // Et le résultat était `results.first` d'une concaténation de `withTaskGroup` :
        // « premier » y désignait l'ordre d'ACHÈVEMENT des tâches réseau, sans la moindre
        // vérification que le candidat correspondait au lieu du libellé. Le classement est
        // désormais un ordre TOTAL sur des critères explicites.
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
        // Conversion par le chemin UNIQUE partagé avec l'UI (cf. `CompanyMatch.enrichment`).
        return top.enrichment(fallbackCity: context.city) { [self] naf in
            nafMapper.lookup(naf).flatMap { findCategoryId(byName: $0.category) }
        }
    }

    private func enrichViaLLM(_ context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        // AIEnrichmentBackend est @MainActor — le `await` gère le hop d'actor. C'est le
        // point de dispatch unique (Foundation Models vs serveur local configuré par
        // l'utilisateur) partagé avec EnrichmentSheetView et PayeeCreationFormSheet —
        // ne pas revenir à un appel direct à EnrichmentLLMService.shared ici, ça
        // recréerait la divergence que AIEnrichmentBackend existe pour éliminer.
        await AIEnrichmentBackend.identify(context: context)
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
        // Champs qui ne sont pas dans l'initialiseur mémberwise (valeurs par défaut).
        // Les oublier ici les fait disparaître dès qu'il y a plus d'un candidat —
        // c'est précisément ce qui arrivait à `searchHint`, la seule information
        // exploitable produite par le LLM quand il ne reconnaît pas le marchand.
        merged.searchHint   = best(\.searchHint)
        merged.siren        = best(\.siren)
        merged.postalCode   = best(\.postalCode)
        merged.categoryHint = best(\.categoryHint)
        return resolvingCategoryHint(merged)
    }

    /// Une source sans accès au référentiel (le LLM) ne peut proposer qu'un NOM de
    /// catégorie — "Alimentation", pas `category_id = 7`. On le résout ici, où le repo
    /// est disponible. Sans ça la catégorie devinée par l'IA était décodée puis jetée.
    /// Appliqué sur les DEUX chemins de `merge` : un LLM seul candidat est justement
    /// le cas où sa catégorie est la seule qu'on ait.
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
