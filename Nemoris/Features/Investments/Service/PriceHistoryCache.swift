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
/// Granularité d'une série de cours. On stocke les deux SÉPARÉMENT car elles
/// n'ont ni la même sémantique de déduplication ni la même rétention :
///   - `.daily`      : 1 point par jour, historique long (10 ans) → plages ≥ 1M
///   - `.intraday30m`: 1 point / 30 min sur les dernières 48 h → plages 1J / 1S
///
/// ⚠️ Ne JAMAIS mélanger les deux sous la même clé : la déduplication par jour
/// du mode `.daily` écraserait tous les points intraday sauf un.
enum PriceResolution: String, Sendable {
    case daily
    case intraday30m

    /// Suffixe de clé de cache (le quotidien garde la clé nue pour rester
    /// rétro-compatible avec les caches déjà sur disque).
    var keySuffix: String {
        switch self {
        case .daily:       return ""
        case .intraday30m: return "#30M"
        }
    }

    /// Fenêtre de rétention. nil = pas de purge (le quotidien est déjà borné
    /// par la source à 10 ans).
    ///
    /// ⚠️ 96 h et non 48 h : une rétention de 2 jours vide le cache intraday
    /// dès le week-end (dernière cotation vendredi 17 h 30 → dimanche matin il
    /// ne reste RIEN), et la vue 1J devenait alors entièrement dépendante d'un
    /// appel réseau réussi. 96 h fait tenir la dernière séance jusqu'au lundi.
    /// Coût : ~200 points par actif au lieu de ~100, négligeable.
    var retention: TimeInterval? {
        switch self {
        case .daily:       return nil
        case .intraday30m: return 96 * 3600
        }
    }
}

extension Array where Element == InvestmentPricePoint {
    /// Fenêtre de la vue 1J, ancrée sur le DERNIER POINT DISPONIBLE — jamais
    /// sur `Date()`.
    ///
    /// ⚠️ C'est LA cause du « 1J n'affiche que 2 points ». Une fenêtre glissante
    /// calée sur l'instant présent est vide dès qu'on regarde hors séance : un
    /// ETF de Paris cote jusqu'à 17 h 30, donc consulté le soir à 19 h il reste
    /// des points, mais samedi, dimanche, ou lundi avant 9 h, TOUTE la dernière
    /// séance est à plus de 24 h → 0 point intraday → repli silencieux sur la
    /// série quotidienne, qui n'a elle-même qu'un ou deux points sur 24 h.
    /// D'où une courbe à 2 points, systématiquement, hors heures de marché.
    ///
    /// En ancrant sur le dernier point connu on obtient les dernières 24 h
    /// COTÉES : la séance complète pour un titre traditionnel, un vrai 24 h
    /// glissant pour une crypto (qui cote en continu, donc son dernier point
    /// est de toute façon récent).
    func lastQuotedWindow(hours: Double = 24) -> [InvestmentPricePoint] {
        guard let anchor = self.map(\.date).max() else { return [] }
        let cutoff = anchor.addingTimeInterval(-hours * 3600)
        return self.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }
}

@MainActor
final class PriceHistoryCache {
    static let shared = PriceHistoryCache()

    private let store = JSONFileCache<[InvestmentPricePoint]>(name: "investment_price_history")

    private init() {}

    /// Toujours store par identifier UPPER pour matcher la sémantique de l'ancien
    /// `WHERE UPPER(identifier) = UPPER(?)` du SQL. Le suffixe de résolution
    /// isole les séries intraday des séries quotidiennes.
    private func normalize(_ identifier: String, _ resolution: PriceResolution = .daily) -> String {
        identifier.uppercased() + resolution.keySuffix
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
    /// Déduplication + nettoyage selon la résolution :
    ///   - `.daily`      : une seule valeur par jour calendaire
    ///   - `.intraday30m`: une seule valeur par horodatage (on veut TOUS les
    ///                     points de la journée), + purge au-delà de la rétention
    private func cleaned(_ points: [InvestmentPricePoint],
                         _ resolution: PriceResolution) -> [InvestmentPricePoint] {
        let usable = points.filter { $0.close.isFinite && $0.close > 0 }
        var byKey: [Date: InvestmentPricePoint] = [:]
        switch resolution {
        case .daily:
            let cal = Calendar.current
            for p in usable { byKey[cal.startOfDay(for: p.date)] = p }
        case .intraday30m:
            for p in usable { byKey[p.date] = p }
        }
        var result = byKey.values.sorted { $0.date < $1.date }
        if let retention = resolution.retention {
            let cutoff = Date().addingTimeInterval(-retention)
            result = result.filter { $0.date >= cutoff }
        }
        return result
    }

    /// Récupère les points sortés par date croissante, limité à `limit`.
    /// Déduplique à la lecture : soigne immédiatement les caches déjà pollués
    /// par l'ancienne écriture (pas besoin d'attendre une resync).
    func fetch(identifier: String,
               limit: Int = 365,
               resolution: PriceResolution = .daily) -> [InvestmentPricePoint] {
        let points = cleaned(store.get(normalize(identifier, resolution)) ?? [], resolution)
        // L'ancien SELECT faisait ORDER BY price_date DESC LIMIT N puis retournait
        // sorted ASC. On reproduit : prend les N plus récents puis trie ASC.
        let sortedDesc = points.sorted { $0.date > $1.date }
        let limited = Array(sortedDesc.prefix(limit))
        return limited.sorted { $0.date < $1.date }
    }

    /// Dernier prix connu pour `identifier`, ou `nil` si absent.
    func latestClose(identifier: String, resolution: PriceResolution = .daily) -> Double? {
        let points = store.get(normalize(identifier, resolution)) ?? []
        return points.max(by: { $0.date < $1.date })?.close
    }

    /// Date du dernier point connu en cache pour `identifier`, ou `nil` si absent.
    /// Permet aux syncs de skip un appel API si on a déjà la donnée du jour
    /// (le passé étant immuable, pas besoin de re-fetcher). En intraday, sert
    /// au skip "fraîcheur < 25 min".
    func latestDate(identifier: String, resolution: PriceResolution = .daily) -> Date? {
        let points = store.get(normalize(identifier, resolution)) ?? []
        return points.max(by: { $0.date < $1.date })?.date
    }

    /// Merge des nouveaux points dans le cache. Sémantique = UPSERT par pas de
    /// temps de la résolution (jour calendaire en `.daily`, horodatage exact en
    /// `.intraday30m`). La rétention de la résolution est appliquée au passage
    /// (auto-purge des points intraday > 48 h).
    /// Renvoie le nombre de points effectivement écrits.
    @discardableResult
    func save(identifier: String,
              points: [InvestmentPricePoint],
              resolution: PriceResolution = .daily) -> Int {
        guard !points.isEmpty else { return 0 }
        let key = normalize(identifier, resolution)
        // L'existant d'abord, les nouveaux ensuite → les nouveaux gagnent.
        let merged = (store.get(key) ?? []) + points
        let result = cleaned(merged, resolution)
        store.set(key, value: result)
        return points.count
    }

    /// Retire tout l'historique de cet identifier (TOUTES résolutions). Utilisé
    /// par `purgeCorruptedCryptoData` pour les cryptos polluées par des actions
    /// Yahoo — l'intraday hérité du mauvais instrument doit partir aussi.
    func remove(identifier: String) {
        store.remove(normalize(identifier, .daily))
        store.remove(normalize(identifier, .intraday30m))
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
