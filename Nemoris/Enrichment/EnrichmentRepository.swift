import Foundation

/// AXE B — Persistance du cache d'enrichissement (Sirene / MapKit / LLM / merged).
///
/// Depuis v36, ce cache vit sur disque (`Library/Caches/nemoris/enrichment_cache.json`)
/// via `JSONFileCache`, plus dans SQLite. Raison :
///   - Ces données viennent d'APIs externes (Sirene, MapKit, Apple Foundation Models)
///     → toujours récupérables, donc pas de valeur "user data".
///   - La base SQLite de l'utilisateur ne doit contenir QUE ses données saisies
///     ou importées (transactions, payees, accounts, etc.).
///   - Le cache peut être purgé par iOS sans risque.
///   - Backup user / sync iCloud plus léger.
///
/// Le store est `@MainActor` (cf. `JSONFileCache`), donc les méthodes sont async :
/// l'orchestrator (actor) `await` pour faire un hop vers MainActor.
struct EnrichmentRepository {

    @MainActor private static let store = JSONFileCache<MerchantEnrichment>(name: "enrichment_cache")

    func fetch(cacheKey: String) async -> MerchantEnrichment? {
        await Self.store.get(cacheKey)
    }

    /// Sémantique UPSERT identique à l'ancien SQL (COALESCE par champ, MAX(confidence)) :
    /// les valeurs non-nil du nouveau résultat écrasent l'existant, sinon on garde l'ancien.
    /// La confidence stockée est le max des deux.
    @discardableResult
    func save(cacheKey: String, result: MerchantEnrichment) async -> Bool {
        await MainActor.run {
            let merged: MerchantEnrichment
            if let existing = Self.store.get(cacheKey) {
                merged = MerchantEnrichment(
                    displayName: result.displayName ?? existing.displayName,
                    domain:      result.domain      ?? existing.domain,
                    categoryId:  result.categoryId  ?? existing.categoryId,
                    address:     result.address     ?? existing.address,
                    city:        result.city        ?? existing.city,
                    country:     result.country     ?? existing.country,
                    latitude:    result.latitude    ?? existing.latitude,
                    longitude:   result.longitude   ?? existing.longitude,
                    phone:       result.phone       ?? existing.phone,
                    siret:       result.siret       ?? existing.siret,
                    nafCode:     result.nafCode     ?? existing.nafCode,
                    source:      result.source,
                    confidence:  max(result.confidence, existing.confidence),
                    enrichedAt:  result.enrichedAt
                )
            } else {
                merged = result
            }
            Self.store.set(cacheKey, value: merged)
            return true
        }
    }
}
