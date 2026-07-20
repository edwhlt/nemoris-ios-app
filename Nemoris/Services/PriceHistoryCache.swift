import Foundation

/// Cache disque dédié à l'historique de prix des actifs investissements.
///
/// Stocke `[InvestmentPricePoint]` par identifiant (ticker ou ISIN, casse uppercase).
/// Remplace l'ancienne table SQLite `investment_price_history` (DROP en v33) :
/// les prix ne sont PAS des données utilisateur — ce sont des données récupérables
/// via les APIs Yahoo/Stooq/CoinGecko, donc ils n'ont pas à polluer la base SQLite
/// de l'utilisateur (qui doit ne contenir que ses comptes, positions, ordres,
/// transactions, etc. — bref tout ce qu'il a créé ou importé).
///
/// Stockage : `Library/Caches/nemoris/investment_price_history.json`
/// (auto-purgé par iOS si manque d'espace → comportement souhaité pour du cache).
@MainActor
final class PriceHistoryCache {
    static let shared = PriceHistoryCache()

    private let store = JSONFileCache<[InvestmentPricePoint]>(name: "investment_price_history")

    private init() {}

    /// Toujours store par identifier UPPER pour matcher la sémantique de l'ancien
    /// `WHERE UPPER(identifier) = UPPER(?)` du SQL.
    private func normalize(_ identifier: String) -> String {
        identifier.uppercased()
    }

    /// Un cours quotidien = UN point par jour calendaire. On déduplique sur le
    /// début de journée (et pas sur le timestamp exact) car les sources ne
    /// datent pas leurs points à la même heure : un même jour peut arriver à
    /// 09:05Z depuis une source et à 15:30Z depuis une autre.
    ///
    /// ⚠️ C'est LA cause du rendu en "code-barres" : deux points le même jour
    /// créent un segment vertical dans le chart. Le symptôme est intermittent
    /// (« parfois oui, parfois non ») car il n'apparaît qu'après une sync qui
    /// a introduit un horodatage différent de celui déjà en cache.
    /// En cas de doublon, le point le plus récemment écrit gagne.
    private func dedupedByDay(_ points: [InvestmentPricePoint]) -> [InvestmentPricePoint] {
        let cal = Calendar.current
        var byDay: [Date: InvestmentPricePoint] = [:]
        for p in points where p.close.isFinite && p.close > 0 {
            byDay[cal.startOfDay(for: p.date)] = p
        }
        return byDay.values.sorted { $0.date < $1.date }
    }

    /// Récupère les points sortés par date croissante, limité à `limit`.
    /// Déduplique par jour à la lecture : soigne immédiatement les caches déjà
    /// pollués par l'ancienne écriture (pas besoin d'attendre une resync).
    func fetch(identifier: String, limit: Int = 365) -> [InvestmentPricePoint] {
        let points = dedupedByDay(store.get(normalize(identifier)) ?? [])
        // L'ancien SELECT faisait ORDER BY price_date DESC LIMIT N puis retournait
        // sorted ASC. On reproduit : prend les N plus récents puis trie ASC.
        let sortedDesc = points.sorted { $0.date > $1.date }
        let limited = Array(sortedDesc.prefix(limit))
        return limited.sorted { $0.date < $1.date }
    }

    /// Dernier prix connu pour `identifier`, ou `nil` si absent.
    func latestClose(identifier: String) -> Double? {
        let points = store.get(normalize(identifier)) ?? []
        return points.max(by: { $0.date < $1.date })?.close
    }

    /// Date du dernier point connu en cache pour `identifier`, ou `nil` si absent.
    /// Permet aux syncs de skip un appel API si on a déjà la donnée du jour
    /// (le passé étant immuable, pas besoin de re-fetcher).
    func latestDate(identifier: String) -> Date? {
        let points = store.get(normalize(identifier)) ?? []
        return points.max(by: { $0.date < $1.date })?.date
    }

    /// Merge des nouveaux points dans le cache. Sémantique = UPSERT par JOUR
    /// calendaire (cf. `dedupedByDay`) : un même jour déjà présent voit son
    /// point remplacé par le nouveau, même si l'horodatage diffère.
    /// Renvoie le nombre de points effectivement écrits.
    @discardableResult
    func save(identifier: String, points: [InvestmentPricePoint]) -> Int {
        guard !points.isEmpty else { return 0 }
        let key = normalize(identifier)
        let cal = Calendar.current
        var byDay: [Date: InvestmentPricePoint] = [:]
        // L'existant d'abord, les nouveaux ensuite → les nouveaux gagnent.
        for p in (store.get(key) ?? []) where p.close.isFinite && p.close > 0 {
            byDay[cal.startOfDay(for: p.date)] = p
        }
        var written = 0
        for p in points where p.close.isFinite && p.close > 0 {
            byDay[cal.startOfDay(for: p.date)] = p
            written += 1
        }
        store.set(key, value: byDay.values.sorted { $0.date < $1.date })
        return written
    }

    /// Retire tout l'historique de cet identifier. Utilisé par
    /// `purgeCorruptedCryptoData` pour les cryptos polluées par des actions Yahoo.
    func remove(identifier: String) {
        store.remove(normalize(identifier))
    }

    /// Toutes les clés en cache.
    func allIdentifiers() -> [String] {
        store.allKeys()
    }

    /// Vide tout le cache (lecture + écriture disque).
    func clearAll() {
        store.clear()
    }
}
