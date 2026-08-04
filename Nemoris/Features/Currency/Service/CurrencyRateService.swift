import Foundation
import SQLite3

private let SQLITE_TRANSIENT_CR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Service de taux de change historiques.
///
/// Source principale : API fawazahmed0 (jsDelivr CDN, gratuite, ~170 devises, pas de clé).
/// URL : https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@{date}/v1/currencies/{from}.json
/// Fallback : https://latest.currency-api.pages.dev/v1/currencies/{from}.json
///
/// Utilisation : await CurrencyRateService.syncRates(groupId: gid)
struct CurrencyRateService {

    // MARK: - Public

    /// Synchronise les taux pour tous les groupes Tricount existants en base.
    /// Utile au premier chargement d'une vue qui affiche des montants convertis.
    @discardableResult
    static func syncAllGroups() async -> Int {
        guard DatabaseManager.shared.hasDatabase() else { return 0 }
        let groupIds = fetchAllGroupIds()
        var total = 0
        for gid in groupIds {
            total += await syncRates(groupId: gid)
        }
        return total
    }

    private static func fetchAllGroupIds() -> [Int] {
        guard DatabaseManager.shared.hasDatabase() else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM tricount_groups;", -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        var ids: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.append(Int(sqlite3_column_int(stmt, 0)))
        }
        return ids
    }

    /// Synchronise les taux manquants pour toutes les entrées d'un groupe Tricount.
    /// Étape 1 : dérive les taux depuis local_total/local_currency déjà stockés (sans réseau).
    /// Étape 2 : pour les paires (devise, date) encore sans taux, appelle l'API.
    @discardableResult
    static func syncRates(groupId: Int) async -> Int {
        guard DatabaseManager.shared.hasDatabase() else { return 0 }

        // 1. Dériver les taux implicites depuis les données Tricount déjà en DB
        let derivedCount = persistRatesFromLocalData(groupId: groupId)

        // 2. Paires encore manquantes → appel API
        let missing = fetchMissingPairs(groupId: groupId)
        guard !missing.isEmpty else { return derivedCount }

        var fetchedCount = 0
        for pair in missing {
            if let rate = try? await fetchRate(from: pair.currency, date: pair.date) {
                storeRate(from: pair.currency, date: pair.date, rate: rate)
                fetchedCount += 1
            }
        }
        return derivedCount + fetchedCount
    }

    // MARK: - Dérivation depuis local_total

    /// Calcule et persiste les taux implicites depuis local_total/local_currency.
    /// Exemple : entry VND, total=1_000_000, local_total=40 EUR
    ///           → rate = 40 / 1_000_000 = 0.00004 (VND → EUR)
    @discardableResult
    static func persistRatesFromLocalData(groupId: Int) -> Int {
        guard DatabaseManager.shared.hasDatabase() else { return 0 }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return 0
        }
        defer { sqlite3_close(db) }

        // Récupère les paires (devise, date, taux dérivé) pour le groupe
        let selectSQL = """
        SELECT DISTINCT te.currency, te.date,
                        te.local_total / te.total AS rate
        FROM tricount_entries te
        WHERE te.group_id = ?
          AND te.currency != 'EUR'
          AND te.currency != ''
          AND te.local_currency = 'EUR'
          AND te.local_total IS NOT NULL
          AND te.local_total > 0
          AND te.total > 0;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK,
              let stmt else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(groupId))

        var rows: [(currency: String, date: String, rate: Double)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let currency = String(cString: sqlite3_column_text(stmt, 0))
            let date     = String(cString: sqlite3_column_text(stmt, 1))
            let rate     = sqlite3_column_double(stmt, 2)
            if rate > 0 { rows.append((currency, date, rate)) }
        }

        var count = 0
        let insertSQL = "INSERT OR REPLACE INTO currency_rates (from_currency, to_currency, date, rate) VALUES (?, 'EUR', ?, ?);"
        for row in rows {
            var ins: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &ins, nil) == SQLITE_OK,
                  let ins else { continue }
            defer { sqlite3_finalize(ins) }
            sqlite3_bind_text(ins, 1, row.currency, -1, SQLITE_TRANSIENT_CR)
            sqlite3_bind_text(ins, 2, row.date,     -1, SQLITE_TRANSIENT_CR)
            sqlite3_bind_double(ins, 3, row.rate)
            if sqlite3_step(ins) == SQLITE_DONE { count += 1 }
        }
        return count
    }

    // MARK: - Paires manquantes

    private struct CurrencyDatePair {
        let currency: String
        let date: String
    }

    private static func fetchMissingPairs(groupId: Int) -> [CurrencyDatePair] {
        guard DatabaseManager.shared.hasDatabase() else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT DISTINCT te.currency, te.date
        FROM tricount_entries te
        WHERE te.group_id = ?
          AND te.currency != 'EUR'
          AND te.currency != ''
          AND NOT EXISTS (
              SELECT 1 FROM currency_rates cr
              WHERE cr.from_currency = te.currency
                AND cr.to_currency   = 'EUR'
                AND cr.date          = te.date
          );
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(groupId))

        var pairs: [CurrencyDatePair] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            pairs.append(CurrencyDatePair(
                currency: String(cString: sqlite3_column_text(stmt, 0)),
                date:     String(cString: sqlite3_column_text(stmt, 1))
            ))
        }
        return pairs
    }

    // MARK: - Appel API

    /// Récupère le taux `from → EUR` pour une date (yyyy-MM-dd).
    /// Essaie d'abord jsDelivr, puis le fallback pages.dev.
    static func fetchRate(from: String, to: String = "EUR", date: String) async throws -> Double {
        let fromLower = from.lowercased()
        let toLower   = to.lowercased()
        let primary   = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@\(date)/v1/currencies/\(fromLower).json"
        let fallback  = "https://latest.currency-api.pages.dev/v1/currencies/\(fromLower).json"

        if let rate = try? await decodeRate(urlString: primary, fromKey: fromLower, toKey: toLower) {
            return rate
        }
        return try await decodeRate(urlString: fallback, fromKey: fromLower, toKey: toLower)
    }

    private static func decodeRate(urlString: String, fromKey: String, toKey: String) async throws -> Double {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await URLSession.shared.data(from: url)
        // Réponse : { "date": "…", "{fromKey}": { "{toKey}": 0.000038 } }
        guard let json      = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ratesDict = json[fromKey] as? [String: Any],
              let rate      = ratesDict[toKey] as? Double else {
            throw URLError(.cannotParseResponse)
        }
        return rate
    }

    // MARK: - Stockage

    static func storeRate(from: String, to: String = "EUR", date: String, rate: Double) {
        guard DatabaseManager.shared.hasDatabase() else { return }
        var db: OpaquePointer?
        guard sqlite3_open_v2(DatabaseManager.shared.sqliteURL().path, &db,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return
        }
        defer { sqlite3_close(db) }
        let sql = "INSERT OR REPLACE INTO currency_rates (from_currency, to_currency, date, rate) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, from, -1, SQLITE_TRANSIENT_CR)
        sqlite3_bind_text(stmt, 2, to,   -1, SQLITE_TRANSIENT_CR)
        sqlite3_bind_text(stmt, 3, date, -1, SQLITE_TRANSIENT_CR)
        sqlite3_bind_double(stmt, 4, rate)
        sqlite3_step(stmt)
    }
}
