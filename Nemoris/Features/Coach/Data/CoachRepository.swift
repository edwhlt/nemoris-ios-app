import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - CoachRepository
//
// Access to the coach's 3 tables. Same style as the other repositories:
// direct SQLite3, one connection per call, no ORM.
//
// The lifecycles, which explain why these are 3 separate tables:
//  • `coach_profile`         — written by the user, SYNCED.
//  • `coach_analyses`        — derived, local.
//  • `coach_recommendations` — derived, local, but with a status to PRESERVE
//    from one analysis to the next (see `replaceRecommendations`).

final class CoachRepository: @unchecked Sendable {
    static let shared = CoachRepository()

    private let store: SQLiteStore

    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }

    // MARK: - Profile (goals)

    /// ONE domain's goals.
    ///
    /// `slot` carries the domain (`transactions` / `investments`) rather
    /// than `'default'`: a "diversify better" goal has no business in the
    /// spending analysis, and "spend less" none in the portfolio's.
    func fetchProfile(domain: CoachDomain) -> CoachProfile {
        guard let db = openDB() else { return .empty }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT objectives, updated_at FROM coach_profile WHERE slot = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .empty }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, domain.rawValue, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .empty }
        return CoachProfile(objectives: columnText(stmt, 0) ?? "",
                            updatedAt: parseDate(columnText(stmt, 1)))
    }

    /// All domains at once — a single connection for the store's load,
    /// instead of one per domain.
    func fetchProfiles() -> [CoachDomain: CoachProfile] {
        var result: [CoachDomain: CoachProfile] = [:]
        guard let db = openDB() else { return result }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT slot, objectives, updated_at FROM coach_profile;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            // A `slot = 'default'` row can reappear: a device still on an
            // earlier version keeps pushing it. Nobody reads it any more —
            // ignore it rather than resurrect it in the UI.
            guard let slot = columnText(stmt, 0), let domain = CoachDomain(rawValue: slot) else { continue }
            result[domain] = CoachProfile(objectives: columnText(stmt, 1) ?? "",
                                          updatedAt: parseDate(columnText(stmt, 2)))
        }
        return result
    }

    /// Writes a domain's goals. `uuid`/`updated_at` are left to the sync
    /// TRIGGERS (`SyncSchema.installTriggers`) — filling them in here would
    /// bypass change tracking, exactly what the triggers exist to prevent
    /// (they also catch the SQL console and batch writes).
    func saveObjectives(_ text: String, domain: CoachDomain) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        let sql = """
            INSERT INTO coach_profile (slot, objectives) VALUES (?, ?)
            ON CONFLICT(slot) DO UPDATE SET objectives = excluded.objectives;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, domain.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, text, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    // MARK: - Analyses

    func fetchAnalysis(domain: CoachDomain) -> CoachAnalysis {
        guard let db = openDB() else { return .empty(domain) }
        defer { sqlite3_close(db) }
        let sql = "SELECT profile_summary, generated_at, status, message, backend, raw_response FROM coach_analyses WHERE domain = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .empty(domain) }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, domain.rawValue, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .empty(domain) }
        return CoachAnalysis(
            domain: domain,
            profileSummary: columnText(stmt, 0),
            generatedAt: parseDate(columnText(stmt, 1)),
            isError: (columnText(stmt, 2) ?? "ok") == "error",
            message: columnText(stmt, 3),
            backend: columnText(stmt, 4),
            rawResponse: columnText(stmt, 5)
        )
    }

    func saveAnalysis(_ analysis: CoachAnalysis) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        let sql = """
            INSERT INTO coach_analyses (domain, profile_summary, generated_at, status, message, backend, raw_response)
            VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(domain) DO UPDATE SET
                profile_summary = excluded.profile_summary,
                generated_at    = excluded.generated_at,
                status          = excluded.status,
                message         = excluded.message,
                backend         = excluded.backend,
                raw_response    = excluded.raw_response;
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, analysis.domain.rawValue, -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 2, analysis.profileSummary)
        bindOptionalText(stmt, 3, analysis.generatedAt.map(isoString))
        sqlite3_bind_text(stmt, 4, analysis.isError ? "error" : "ok", -1, SQLITE_TRANSIENT)
        bindOptionalText(stmt, 5, analysis.message)
        bindOptionalText(stmt, 6, analysis.backend)
        bindOptionalText(stmt, 7, analysis.rawResponse)
        sqlite3_step(stmt)
    }

    // MARK: - Recommendations

    func fetchRecommendations(domain: CoachDomain? = nil) -> [CoachRecommendation] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }
        var sql = """
            SELECT id, domain, ref, title, detail, rationale, category,
                   annual_impact, effort, confidence, status, generated_at
            FROM coach_recommendations
            """
        if domain != nil { sql += " WHERE domain = ?" }
        sql += ";"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        if let domain { sqlite3_bind_text(stmt, 1, domain.rawValue, -1, SQLITE_TRANSIENT) }

        var result: [CoachRecommendation] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let rawDomain = columnText(stmt, 1),
                  let parsedDomain = CoachDomain(rawValue: rawDomain),
                  let ref = columnText(stmt, 2),
                  let title = columnText(stmt, 3) else { continue }
            result.append(CoachRecommendation(
                id: Int(sqlite3_column_int(stmt, 0)),
                domain: parsedDomain,
                ref: ref,
                title: title,
                detail: columnText(stmt, 4) ?? "",
                rationale: columnText(stmt, 5),
                category: columnText(stmt, 6),
                annualImpact: sqlite3_column_double(stmt, 7),
                effort: Int(sqlite3_column_int(stmt, 8)),
                confidence: sqlite3_column_double(stmt, 9),
                status: CoachRecommendationStatus(rawValue: columnText(stmt, 10) ?? "new") ?? .new,
                generatedAt: parseDate(columnText(stmt, 11)) ?? Date()
            ))
        }
        return result
    }

    /// Replaces a domain's recommendations with those of a new analysis.
    ///
    /// Three rules, each for a precise reason:
    ///  1. UPSERT by `(domain, ref)` while **keeping the `status`**: a
    ///     dismissed recommendation the model proposes again stays
    ///     dismissed. Without this, every analysis would resurrect
    ///     everything the user set aside — the surest way to make them
    ///     ignore the coach.
    ///  2. Rows absent from the new batch are deleted UNLESS they are
    ///     `dismissed`: those act as tombstones, so the dismissal survives a
    ///     temporary disappearance of the subject.
    ///  3. Tombstones older than 180 days are purged — past that delay the
    ///     situation has probably changed and the question deserves to be
    ///     asked again.
    func replaceRecommendations(domain: CoachDomain, drafts: [CoachRecommendationDraft], now: Date = Date()) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }

        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

        let generated = isoString(now)
        for draft in drafts {
            let sql = """
                INSERT INTO coach_recommendations
                    (domain, ref, title, detail, rationale, category,
                     annual_impact, effort, confidence, status, generated_at)
                VALUES (?,?,?,?,?,?,?,?,?, 'new', ?)
                ON CONFLICT(domain, ref) DO UPDATE SET
                    title         = excluded.title,
                    detail        = excluded.detail,
                    rationale     = excluded.rationale,
                    category      = excluded.category,
                    annual_impact = excluded.annual_impact,
                    effort        = excluded.effort,
                    confidence    = excluded.confidence,
                    generated_at  = excluded.generated_at;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(stmt, 1, domain.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, draft.ref, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, draft.title, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, draft.detail, -1, SQLITE_TRANSIENT)
            bindOptionalText(stmt, 5, draft.rationale)
            bindOptionalText(stmt, 6, draft.category)
            sqlite3_bind_double(stmt, 7, draft.annualImpact)
            sqlite3_bind_int(stmt, 8, Int32(draft.effort))
            sqlite3_bind_double(stmt, 9, draft.confidence)
            sqlite3_bind_text(stmt, 10, generated, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }

        // Clean up rows the new analysis no longer proposes.
        let keptRefs = drafts.map { "'" + $0.ref.replacingOccurrences(of: "'", with: "''") + "'" }
        let notIn = keptRefs.isEmpty ? "" : " AND ref NOT IN (\(keptRefs.joined(separator: ",")))"
        var deleteStmt: OpaquePointer?
        let deleteSQL = "DELETE FROM coach_recommendations WHERE domain = ? AND status != 'dismissed'\(notIn);"
        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(deleteStmt, 1, domain.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_step(deleteStmt)
        }
        sqlite3_finalize(deleteStmt)

        // Purge expired tombstones.
        let cutoff = isoString(now.addingTimeInterval(-180 * 24 * 3600))
        var purgeStmt: OpaquePointer?
        let purgeSQL = "DELETE FROM coach_recommendations WHERE domain = ? AND status = 'dismissed' AND generated_at < ?;"
        if sqlite3_prepare_v2(db, purgeSQL, -1, &purgeStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(purgeStmt, 1, domain.rawValue, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(purgeStmt, 2, cutoff, -1, SQLITE_TRANSIENT)
            sqlite3_step(purgeStmt)
        }
        sqlite3_finalize(purgeStmt)

        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }

    func updateStatus(id: Int, status: CoachRecommendationStatus) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE coach_recommendations SET status = ? WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(id))
        sqlite3_step(stmt)
    }

    // MARK: - SQLite helpers

    private func openDB() -> OpaquePointer? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ col: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, col, value, -1, SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, col) }
    }

    /// ISO 8601 WITH the time, unlike the business dates of the other
    /// repositories (`yyyy-MM-dd`): an analysis's staleness is counted in
    /// hours on the day it just ran, not in days.
    private func isoString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }

    private func parseDate(_ str: String?) -> Date? {
        guard let str else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.date(from: str)
    }
}
