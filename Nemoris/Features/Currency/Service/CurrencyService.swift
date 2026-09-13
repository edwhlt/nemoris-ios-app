import Foundation
import SQLite3
import os

// MARK: - CurrencyService
//
// A currency-conversion service — an isolated actor to manage a thread-safe cache.
// A free provider: fawazahmed0/currency-api via the jsDelivr CDN (no key), with a
// pages.dev fallback — the same provider as `CurrencyRateService` (Tricount).
// ⚠️ exchangerate.host (the old provider) now requires a paid key
// (`missing_access_key`): every request failed silently, hence
// "Unable to fetch the rate" for 100% of conversions.
//
// **Cache strategy**: 3 levels to minimize network use:
//   1. RAM (an in-memory `Dictionary` on the actor) — reloaded on every cold start
//   2. SQLite `currency_rates` (an existing v6 table) — survives relaunches
//   3. Network (fawazahmed0/currency-api) — the ultimate fallback
//
// Lookup: looks for TODAY's rate. If absent, falls back to the last 30
// days (the rate doesn't move much over 1 month — acceptable for the
// MVP's "ad-hoc conversion" use case). Beyond that → a network fetch.

private let SQLITE_TRANSIENT_CURRENCY = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor CurrencyService {

    static let shared = CurrencyService()

    private static let log = Logger(subsystem: "fr.hedwin.nemoris", category: "Currency")

    /// Cache RAM : key = "FROM_TO_yyyy-MM-dd", value = rate.
    private var ramCache: [String: Double] = [:]

    /// The list of supported currencies (the top 15 in the FX market — enough
    /// for 99% of user cases).
    nonisolated static let supportedCurrencies: [Currency] = [
        Currency(code: "EUR", symbol: "€",  name: "Euro"),
        Currency(code: "USD", symbol: "$",  name: "Dollar US"),
        Currency(code: "GBP", symbol: "£",  name: "Livre sterling"),
        Currency(code: "CHF", symbol: "CHF", name: "Franc suisse"),
        Currency(code: "JPY", symbol: "¥",  name: "Yen japonais"),
        Currency(code: "CAD", symbol: "C$", name: "Dollar canadien"),
        Currency(code: "AUD", symbol: "A$", name: "Dollar australien"),
        Currency(code: "CNY", symbol: "¥",  name: "Yuan chinois"),
        Currency(code: "INR", symbol: "₹",  name: "Roupie indienne"),
        Currency(code: "BRL", symbol: "R$", name: "Real brésilien"),
        Currency(code: "MXN", symbol: "$",  name: "Peso mexicain"),
        Currency(code: "SEK", symbol: "kr", name: "Couronne suédoise"),
        Currency(code: "NOK", symbol: "kr", name: "Couronne norvégienne"),
        Currency(code: "DKK", symbol: "kr", name: "Couronne danoise"),
        Currency(code: "PLN", symbol: "zł", name: "Zloty polonais"),
    ]

    struct Currency: Identifiable, Hashable {
        let code: String
        let symbol: String
        let name: String
        var id: String { code }
    }

    /// Converts an amount. Returns `nil` if the rate can't be found
    /// (the network is down + the cache is empty for this pair).
    func convert(_ amount: Double, from: String, to: String, date: Date = Date()) async -> Double? {
        if from == to { return amount }
        guard let rate = await rate(from: from, to: to, date: date) else { return nil }
        return amount * rate
    }

    /// Looks up a rate across the 3 caches (RAM → SQL → network).
    func rate(from: String, to: String, date: Date) async -> Double? {
        let dayKey = dayKey(date: date)
        let key = "\(from)_\(to)_\(dayKey)"

        // 1) RAM
        if let cached = ramCache[key] { return cached }

        // 2) SQLite — looks for today's rate, falling back up to 30 days back
        if let stored = readFromSQLite(from: from, to: to, date: date) {
            ramCache[key] = stored
            return stored
        }

        // 3) Network
        if let fetched = await fetchFromNetwork(from: from, to: to, date: date) {
            ramCache[key] = fetched
            writeToSQLite(from: from, to: to, date: date, rate: fetched)
            return fetched
        }

        return nil
    }

    // MARK: - SQLite layer

    private func readFromSQLite(from: String, to: String, date: Date) -> Double? {
        guard DatabaseManager.shared.hasDatabaseCopy() else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        // Looks for the most recent rate within a 30-day window around
        // the requested date. Tolerates unquoted days (weekends,
        // holidays) without breaking the conversion.
        let dayStr = dayKey(date: date)
        let cal = Calendar.current
        guard let from30 = cal.date(byAdding: .day, value: -30, to: date) else { return nil }
        let from30Str = dayKey(date: from30)
        let sql = """
        SELECT rate FROM currency_rates
        WHERE from_currency = ? AND to_currency = ? AND date <= ? AND date >= ?
        ORDER BY date DESC LIMIT 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, from, -1, SQLITE_TRANSIENT_CURRENCY)
        sqlite3_bind_text(stmt, 2, to, -1, SQLITE_TRANSIENT_CURRENCY)
        sqlite3_bind_text(stmt, 3, dayStr, -1, SQLITE_TRANSIENT_CURRENCY)
        sqlite3_bind_text(stmt, 4, from30Str, -1, SQLITE_TRANSIENT_CURRENCY)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0)
        }
        return nil
    }

    private func writeToSQLite(from: String, to: String, date: Date, rate: Double) {
        guard DatabaseManager.shared.hasDatabaseCopy() else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = """
        INSERT INTO currency_rates (from_currency, to_currency, date, rate)
        VALUES (?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, from, -1, SQLITE_TRANSIENT_CURRENCY)
        sqlite3_bind_text(stmt, 2, to, -1, SQLITE_TRANSIENT_CURRENCY)
        sqlite3_bind_text(stmt, 3, dayKey(date: date), -1, SQLITE_TRANSIENT_CURRENCY)
        sqlite3_bind_double(stmt, 4, rate)
        _ = sqlite3_step(stmt)
    }

    // MARK: - Network layer

    /// Fetches the rate via fawazahmed0/currency-api (free, no key, ~170 currencies).
    /// Tries the jsDelivr CDN first (historical dates available), then the
    /// pages.dev fallback (today's rate only) — the same strategy as
    /// `CurrencyRateService.fetchRate` (Tricount).
    /// Response: `{ "date": "…", "{fromKey}": { "{toKey}": 0.93 } }`.
    private func fetchFromNetwork(from: String, to: String, date: Date) async -> Double? {
        let fromKey = from.lowercased()
        let toKey = to.lowercased()
        let datePath = Calendar.current.isDateInToday(date) ? "latest" : dayKey(date: date)
        let primary = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@\(datePath)/v1/currencies/\(fromKey).json"
        let fallback = "https://latest.currency-api.pages.dev/v1/currencies/\(fromKey).json"

        if let rate = await decodeRate(urlString: primary, fromKey: fromKey, toKey: toKey) {
            return rate
        }
        return await decodeRate(urlString: fallback, fromKey: fromKey, toKey: toKey)
    }

    private func decodeRate(urlString: String, fromKey: String, toKey: String) async -> Double? {
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Self.log.warning("Currency fetch HTTP error : \(url)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ratesDict = json[fromKey] as? [String: Any],
                  let rate = ratesDict[toKey] as? Double else {
                Self.log.warning("Currency fetch parse error : \(String(data: data, encoding: .utf8) ?? "?")")
                return nil
            }
            return rate
        } catch {
            Self.log.warning("Currency fetch network error : \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    private nonisolated func dayKey(date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
