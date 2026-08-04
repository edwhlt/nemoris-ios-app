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

    private let store: SQLiteStore

    /// La valeur par défaut vise la base de l'application : les sites d'appel
    /// existants n'ont pas à changer.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }


    @MainActor private static let store = JSONFileCache<MerchantEnrichment>(name: "enrichment_cache")

    func fetch(cacheKey: String) async -> MerchantEnrichment? {
        await Self.store.get(cacheKey)
    }

    /// Sémantique UPSERT identique à l'ancien SQL (COALESCE par champ, MAX(confidence)) :
    /// les valeurs non-nil du nouveau résultat écrasent l'existant, sinon on garde l'ancien.
    /// La confidence stockée est le max des deux.
    ///
    /// ⚠️ Écrit par **overlay sur l'existant**, pas en ré-énumérant chaque champ dans un
    /// initialiseur. La version précédente reconstruisait un `MerchantEnrichment` champ par
    /// champ et avait donc silencieusement perdu `searchHint` le jour où il a été ajouté.
    /// Avec l'overlay, un nouveau champ optionnel est conservé par défaut : il n'y a plus
    /// de liste à tenir à jour, donc plus rien à oublier.
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
