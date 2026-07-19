import Foundation
import SQLite3
import os

// MARK: - CurrencyService
//
// Service de conversion de devises — actor isolé pour gérer le cache thread-safe.
// Provider gratuit : exchangerate.host (sans clé, données BCE quotidiennes).
//
// **Stratégie de cache** : 3 niveaux pour minimiser le réseau :
//   1. RAM (`Dictionary` en mémoire de l'actor) — recharge à chaque cold start
//   2. SQLite `currency_rates` (table v6 existante) — survit aux relaunches
//   3. Réseau (`exchangerate.host`) — fallback ultime
//
// Lookup : on cherche un taux du JOUR. Si absent, on fallback sur les 30
// derniers jours (le taux ne bouge pas trop sur 1 mois — acceptable pour
// l'usage "conversion ad-hoc" du MVP). Au-delà → fetch réseau.

private let SQLITE_TRANSIENT_CURRENCY = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor CurrencyService {

    static let shared = CurrencyService()

    private static let log = Logger(subsystem: "fr.hedwin.nemoris", category: "Currency")

    /// Cache RAM : key = "FROM_TO_yyyy-MM-dd", value = rate.
    private var ramCache: [String: Double] = [:]

    /// Liste des devises supportées (top 15 du marché des changes — suffisant
    /// pour 99 % des cas user).
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

    /// Convertit un montant. Retourne `nil` si le taux n'est pas trouvable
    /// (réseau down + cache vide pour cette paire).
    func convert(_ amount: Double, from: String, to: String, date: Date = Date()) async -> Double? {
        if from == to { return amount }
        guard let rate = await rate(from: from, to: to, date: date) else { return nil }
        return amount * rate
    }

    /// Cherche un taux dans les 3 caches (RAM → SQL → réseau).
    func rate(from: String, to: String, date: Date) async -> Double? {
        let dayKey = dayKey(date: date)
        let key = "\(from)_\(to)_\(dayKey)"

        // 1) RAM
        if let cached = ramCache[key] { return cached }

        // 2) SQLite — chercher le taux du jour, fallback 30j en arrière
        if let stored = readFromSQLite(from: from, to: to, date: date) {
            ramCache[key] = stored
            return stored
        }

        // 3) Réseau
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

        // Cherche le taux le plus récent dans une fenêtre de 30 jours autour
        // de la date demandée. Permet de tolérer les jours non cotés (week-end,
        // jours fériés) sans casser la conversion.
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

    /// Fetch le taux via exchangerate.host (gratuit, sans clé, données BCE).
    /// Endpoint : `https://api.exchangerate.host/latest?base=XXX&symbols=YYY`
    /// pour les taux du jour ; pour les dates historiques : `/YYYY-MM-DD`.
    private func fetchFromNetwork(from: String, to: String, date: Date) async -> Double? {
        let today = Calendar.current.isDateInToday(date)
        let datePath = today ? "latest" : dayKey(date: date)
        guard let url = URL(string: "https://api.exchangerate.host/\(datePath)?base=\(from)&symbols=\(to)") else {
            return nil
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                Self.log.warning("Currency fetch HTTP error : \(url)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rates = json["rates"] as? [String: Double],
                  let rate = rates[to] else {
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
