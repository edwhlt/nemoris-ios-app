import Foundation

/// Persistence for the enrichment cache (Sirene / MapKit / LLM / merged).
///
/// Since v36, this cache has lived on disk (`Library/Caches/nemoris/enrichment_cache.json`)
/// via `JSONFileCache`, not in SQLite. Reason:
///   - This data comes from external APIs (Sirene, MapKit, Apple Foundation Models)
///     → always re-fetchable, so no "user data" value.
///   - The user's SQLite database must contain ONLY data they entered
///     or imported (transactions, payees, accounts, etc.).
///   - The cache can be purged by iOS with no risk.
///   - Lighter user backup / iCloud sync.
///
/// The store is `@MainActor` (see `JSONFileCache`), so the methods are async:
/// the orchestrator (an actor) `await`s to hop to the MainActor.
struct EnrichmentRepository {

    /// ⚠️ This repository does NOT touch the user's database: its content is a
    /// cache of external APIs, always re-fetchable, and deliberately kept out
    /// of entered data (see the explanation above). It therefore has no
    /// SQLite connection to receive, unlike the other repositories.
    @MainActor private static let store = JSONFileCache<MerchantEnrichment>(name: "enrichment_cache")

    func fetch(cacheKey: String) async -> MerchantEnrichment? {
        await Self.store.get(cacheKey)
    }

    /// Same UPSERT semantics as the old SQL (per-field COALESCE, MAX(confidence)):
    /// non-nil values from the new result overwrite the existing ones, otherwise the old
    /// value is kept. The stored confidence is the max of the two.
    ///
    /// ⚠️ Written as an **overlay onto the existing value**, not by re-listing each
    /// field in an initializer. The previous version rebuilt a `MerchantEnrichment` field by
    /// field and had therefore silently lost `searchHint` the day it was added.
    /// With the overlay, a new optional field is kept by default: there's no
    /// list to maintain anymore, so nothing left to forget.
    @discardableResult
    func save(cacheKey: String, result: MerchantEnrichment) async -> Bool {
        await MainActor.run {
            var merged = result
            if let existing = Self.store.get(cacheKey) {
                merged.displayName  = result.displayName  ?? existing.displayName
                merged.domain       = result.domain       ?? existing.domain
                merged.categoryId   = result.categoryId   ?? existing.categoryId
                merged.address      = result.address      ?? existing.address
                merged.city         = result.city         ?? existing.city
                merged.country      = result.country      ?? existing.country
                merged.latitude     = result.latitude     ?? existing.latitude
                merged.longitude    = result.longitude    ?? existing.longitude
                merged.phone        = result.phone        ?? existing.phone
                merged.siret        = result.siret        ?? existing.siret
                merged.nafCode      = result.nafCode      ?? existing.nafCode
                merged.searchHint   = result.searchHint   ?? existing.searchHint
                merged.siren        = result.siren        ?? existing.siren
                merged.postalCode   = result.postalCode   ?? existing.postalCode
                merged.categoryHint = result.categoryHint ?? existing.categoryHint
                merged.confidence   = max(result.confidence, existing.confidence)
            }
            Self.store.set(cacheKey, value: merged)
            return true
        }
    }
}
