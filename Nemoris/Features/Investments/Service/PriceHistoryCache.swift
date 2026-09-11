import Foundation

/// Granularity of a price series. The two are stored SEPARATELY because they
/// share neither deduplication semantics nor retention:
///   - `.daily`      : 1 point per day, long history (10 years) → ranges ≥ 1M
///   - `.intraday30m`: 1 point / 30 min over the last hours → ranges 1D / 1W
///
/// NEVER mix the two under the same key: the per-day deduplication of
/// `.daily` would crush every intraday point but one.
enum PriceResolution: String, Sendable {
    case daily
    case intraday30m

    /// Cache key suffix (daily keeps the bare key, so caches already on disk stay
    /// readable).
    var keySuffix: String {
        switch self {
        case .daily:       return ""
        case .intraday30m: return "#30M"
        }
    }

    /// Retention window. nil = no purge (daily is already bounded to 10 years by
    /// the source).
    ///
    /// 96 h, not 48 h: a 2-day retention empties the intraday cache over the
    /// weekend (last quote Friday 17:30 → by Sunday morning NOTHING is left), and
    /// the 1D view would then depend entirely on a successful network call. 96 h
    /// keeps the last session until Monday. Cost: ~200 points per asset instead
    /// of ~100, negligible.
    var retention: TimeInterval? {
        switch self {
        case .daily:       return nil
        case .intraday30m: return 96 * 3600
        }
    }
}

extension Array where Element == InvestmentPricePoint {
    /// Window of the 1D view, anchored on the LAST AVAILABLE POINT — never on
    /// `Date()`.
    ///
    /// A rolling window pinned to the present instant is empty as soon as it's
    /// viewed outside trading hours: a Paris ETF trades until 17:30, so viewed at
    /// 19:00 there are still points, but on Saturday, Sunday, or Monday before
    /// 9:00, the WHOLE last session is more than 24 h old → 0 intraday points →
    /// silent fallback to the daily series, which itself has only one or two
    /// points over 24 h. The result would be a 2-point curve, every time, outside
    /// market hours.
    ///
    /// Anchoring on the last known point gives the last 24 TRADED hours: the full
    /// session for a traditional security, a true rolling 24 h for a crypto
    /// (which trades continuously, so its last point is recent anyway).
    func lastQuotedWindow(hours: Double = 24) -> [InvestmentPricePoint] {
        guard let anchor = self.map(\.date).max() else { return [] }
        let cutoff = anchor.addingTimeInterval(-hours * 3600)
        return self.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }
}

/// Disk cache dedicated to investment assets' price history.
///
/// Stores `[InvestmentPricePoint]` per identifier (ticker or ISIN, uppercased).
/// Prices are NOT user data: they can be refetched from the Yahoo/Stooq/
/// CoinGecko APIs, so they don't belong in the user's SQLite database, which
/// only holds what the user created or imported (accounts, positions, orders,
/// transactions…).
///
/// Storage: `Library/Caches/nemoris/investment_price_history.json` (purged by
/// iOS when space runs low → the desired behavior for a cache).
@MainActor
final class PriceHistoryCache {
    static let shared = PriceHistoryCache()

    private let store = JSONFileCache<[InvestmentPricePoint]>(name: "investment_price_history")

    private init() {}

    /// Always stored under the UPPERCASED identifier (case-insensitive lookups).
    /// The resolution suffix isolates intraday series from daily ones.
    private func normalize(_ identifier: String, _ resolution: PriceResolution = .daily) -> String {
        identifier.uppercased() + resolution.keySuffix
    }

    /// Deduplication + cleanup according to the resolution:
    ///   - `.daily`      : a single value per calendar day
    ///   - `.intraday30m`: a single value per timestamp (EVERY point of the day
    ///                     is wanted), + purge beyond the retention
    ///
    /// A daily price = ONE point per calendar day. Deduplication is on the start
    /// of the day (not the exact timestamp) because sources don't timestamp their
    /// points at the same hour: the same day can arrive at 09:05Z from one source
    /// and at 15:30Z from another. Two points on the same day would draw a
    /// vertical segment in the chart — a "barcode" rendering that only appears
    /// after a sync introduces a timestamp different from the cached one. On a
    /// duplicate, the most recently written point wins.
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

    /// Fetches the points sorted by ascending date, limited to `limit`.
    /// Deduplicates on read, so caches holding duplicate days are repaired
    /// immediately, without waiting for a resync.
    func fetch(identifier: String,
               limit: Int = 365,
               resolution: PriceResolution = .daily) -> [InvestmentPricePoint] {
        let points = cleaned(store.get(normalize(identifier, resolution)) ?? [], resolution)
        // Take the N most recent points, then sort ascending.
        let sortedDesc = points.sorted { $0.date > $1.date }
        let limited = Array(sortedDesc.prefix(limit))
        return limited.sorted { $0.date < $1.date }
    }

    /// Last known price for `identifier`, or `nil` if absent.
    func latestClose(identifier: String, resolution: PriceResolution = .daily) -> Double? {
        let points = store.get(normalize(identifier, resolution)) ?? []
        return points.max(by: { $0.date < $1.date })?.close
    }

    /// Date of the last cached point for `identifier`, or `nil` if absent.
    /// Lets syncs skip an API call when today's data is already there (the past
    /// being immutable, no need to refetch). For intraday, it drives the
    /// "freshness < 25 min" skip.
    func latestDate(identifier: String, resolution: PriceResolution = .daily) -> Date? {
        let points = store.get(normalize(identifier, resolution)) ?? []
        return points.max(by: { $0.date < $1.date })?.date
    }

    /// Merges new points into the cache. Semantics = UPSERT per time step of the
    /// resolution (calendar day for `.daily`, exact timestamp for `.intraday30m`).
    /// The resolution's retention is applied along the way (intraday points
    /// beyond the retention are purged).
    /// Returns the number of points actually written.
    @discardableResult
    func save(identifier: String,
              points: [InvestmentPricePoint],
              resolution: PriceResolution = .daily) -> Int {
        guard !points.isEmpty else { return 0 }
        let key = normalize(identifier, resolution)
        // Existing points first, new ones after → the new ones win.
        let merged = (store.get(key) ?? []) + points
        let result = cleaned(merged, resolution)
        store.set(key, value: result)
        return points.count
    }

    /// Removes all history for this identifier (EVERY resolution). Used by
    /// `purgeCorruptedCryptoData` for cryptos polluted by Yahoo stocks — the
    /// intraday inherited from the wrong instrument must go too.
    func remove(identifier: String) {
        store.remove(normalize(identifier, .daily))
        store.remove(normalize(identifier, .intraday30m))
    }

    /// All cached keys.
    func allIdentifiers() -> [String] {
        store.allKeys()
    }

    /// Clears the whole cache (read + disk write).
    func clearAll() {
        store.clear()
    }
}
