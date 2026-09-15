import Foundation
import SQLite3

private let SQLITE_TRANSIENT_APPLEPAY = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// An Apple Pay expense dropped off by the Shortcuts automation, awaiting
/// resolution — never created directly by the user.
struct PendingApplePayEntry: Identifiable {
    enum Status: String {
        /// Dropped off, not processed yet.
        case pending
        /// Matched against a transaction that arrived through bank import
        /// (CSV/PDF/OFX statement). Not implemented yet.
        case matched
        /// Dismissed by the user.
        case dismissed
    }

    let id: Int
    var card: String?
    /// Always negative (an expense) — see `PendingApplePayRepository.addEntry`.
    var amount: Double
    var merchant: String
    var status: Status
    var matchedTransactionId: Int?
    var createdAt: Date
}

/// CRUD for `pending_apple_pay_entries`.
///
/// Populated ONLY by `ImportTransactionApplePayEntityIntent` (a personal
/// "Apple Pay" Shortcuts automation, `openAppWhenRun = false` — it runs
/// without ever showing the app). A local table, never synced (see
/// `SyncSchema.swift`): each device receives its own Apple Pay
/// notifications, so there is nothing to reconcile between devices.
struct PendingApplePayRepository {

    private let store: SQLiteStore

    /// The default value targets the app's own database: existing call
    /// sites need no change.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }

    // An INSTANCE property, not `static`: `ISO8601DateFormatter` isn't
    // `Sendable`, and a `static let` would make it a shared mutable global,
    // rejected by Swift 6 strict concurrency (see LiveSyncRepository).
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Writing

    /// Drops off a pending entry. `amount` can arrive positive (the raw
    /// value supplied by the "Apple Pay" Shortcuts trigger): it is
    /// normalized to negative here, once and for all, to stay compatible
    /// with the rest of the app's convention (`transactions.amount < 0` = an
    /// expense) without every future reader (budget, notifications) having
    /// to think about it.
    ///
    /// The "Apple Pay Transaction" personal automation can fire more than
    /// once for the SAME real-world purchase — typically once while the
    /// transaction is still pending (amount not yet known by Apple Pay,
    /// stored as 0 by `ImportTransactionApplePayEntityIntent`) and again
    /// once it settles with the final amount. Without a merge step here,
    /// that produces two rows at the same minute for one purchase: an "à
    /// saisir" placeholder next to the real one. `findRecentDuplicate`
    /// collapses that into a single row.
    @discardableResult
    func addEntry(card: String?, amount: Double, merchant: String) -> Bool {
        let now = Date()
        let normalizedAmount = -abs(amount)

        if let duplicate = findRecentDuplicate(card: card, merchant: merchant, on: now) {
            // The earlier firing had no amount yet: complete it with this
            // one instead of leaving a stray "à saisir" row beside it.
            if duplicate.amount == 0 && normalizedAmount != 0 {
                return updateAmount(id: duplicate.id, amount: amount)
            }
            // This firing has no amount but the earlier one already does:
            // the good data is already stored, drop this one silently.
            if duplicate.amount != 0 && normalizedAmount == 0 {
                return true
            }
            // Both sides already carry the same known amount: an exact
            // duplicate firing, nothing to merge or insert.
            if abs(duplicate.amount - normalizedAmount) < 0.005 {
                return true
            }
            // Both known but different amounts: a genuinely separate
            // purchase at the same merchant/card the same day — fall
            // through and insert it as its own row.
        }

        let iso = isoFormatter.string(from: now)
        return store.writeSingle(sql: """
            INSERT INTO pending_apple_pay_entries (card, amount, merchant, status, created_at)
            VALUES (?, ?, ?, 'pending', ?);
            """) { stmt in
            if let card, !card.isEmpty {
                sqlite3_bind_text(stmt, 1, card, -1, SQLITE_TRANSIENT_APPLEPAY)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_double(stmt, 2, normalizedAmount)
            sqlite3_bind_text(stmt, 3, merchant, -1, SQLITE_TRANSIENT_APPLEPAY)
            sqlite3_bind_text(stmt, 4, iso, -1, SQLITE_TRANSIENT_APPLEPAY)
        }
    }

    /// A still-`pending` entry, dropped off the same calendar day, matching
    /// `card` and `merchant` (case/whitespace-insensitive) — the signature
    /// of the Shortcuts automation firing more than once for the same
    /// purchase (see `addEntry`). `card IS ?` (not `= ?`) so two entries
    /// with no card at all still match each other.
    ///
    /// Intentionally scoped to `pending` only and to the current day, not a
    /// short rolling time window: an Apple Pay pre-authorization can settle
    /// hours later (restaurants, gas stations), and comparing calendar days
    /// avoids hardcoding a duration that would either miss slow settlements
    /// or risk merging two unrelated purchases made minutes apart.
    private func findRecentDuplicate(card: String?, merchant: String, on date: Date) -> (id: Int, amount: Double)? {
        let dayString = isoFormatter.string(from: date)
        let sentinel = (id: 0, amount: 0.0)
        let result = store.read { db -> (id: Int, amount: Double) in
            var stmt: OpaquePointer?
            let sql = """
                SELECT id, amount FROM pending_apple_pay_entries
                WHERE status = 'pending'
                  AND lower(trim(merchant)) = lower(trim(?))
                  AND card IS ?
                  AND date(created_at) = date(?)
                ORDER BY created_at DESC
                LIMIT 1;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return sentinel }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, merchant, -1, SQLITE_TRANSIENT_APPLEPAY)
            if let card, !card.isEmpty {
                sqlite3_bind_text(stmt, 2, card, -1, SQLITE_TRANSIENT_APPLEPAY)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, dayString, -1, SQLITE_TRANSIENT_APPLEPAY)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return sentinel }
            return (Int(sqlite3_column_int(stmt, 0)), sqlite3_column_double(stmt, 1))
        } ?? sentinel
        return result.id > 0 ? result : nil
    }

    // MARK: - Updating

    /// Changes an entry's status (manual dismissal from the list).
    @discardableResult
    func updateStatus(id: Int, to status: PendingApplePayEntry.Status) -> Bool {
        store.writeSingle(sql: "UPDATE pending_apple_pay_entries SET status = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT_APPLEPAY)
            sqlite3_bind_int(stmt, 2, Int32(id))
        }
    }

    /// Fixes the amount of an entry dropped off without a known amount (see
    /// `ImportTransactionApplePayEntityIntent` — stored as 0 until the user
    /// corrects it from `PendingApplePayListView`). Normalized to negative
    /// like `addEntry`, same convention.
    @discardableResult
    func updateAmount(id: Int, amount: Double) -> Bool {
        store.writeSingle(sql: "UPDATE pending_apple_pay_entries SET amount = ? WHERE id = ?;") { stmt in
            sqlite3_bind_double(stmt, 1, -abs(amount))
            sqlite3_bind_int(stmt, 2, Int32(id))
        }
    }

    // MARK: - Deletion

    /// Permanently deletes entries dropped off before `cutoff`, whatever
    /// their status (`pending` as well as `dismissed` — nothing else ever
    /// removes them, so they would otherwise accumulate indefinitely). A
    /// manual gesture, triggered by the user from settings. Returns the
    /// number of rows deleted, for UI feedback.
    @discardableResult
    func purgeEntries(olderThan cutoff: Date) -> Int {
        store.write { db -> Int in
            var stmt: OpaquePointer?
            let sql = "DELETE FROM pending_apple_pay_entries WHERE created_at < ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, isoFormatter.string(from: cutoff), -1, SQLITE_TRANSIENT_APPLEPAY)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return Int(sqlite3_changes(db))
        } ?? 0
    }

    // MARK: - Reading

    /// Entries with the given status (all when `nil`), most recent first.
    func fetchEntries(status: PendingApplePayEntry.Status? = nil) -> [PendingApplePayEntry] {
        store.read { db -> [PendingApplePayEntry] in
            let sql = status != nil
                ? "SELECT id, card, amount, merchant, status, matched_transaction_id, created_at FROM pending_apple_pay_entries WHERE status = ? ORDER BY created_at DESC;"
                : "SELECT id, card, amount, merchant, status, matched_transaction_id, created_at FROM pending_apple_pay_entries ORDER BY created_at DESC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            if let status {
                sqlite3_bind_text(stmt, 1, status.rawValue, -1, SQLITE_TRANSIENT_APPLEPAY)
            }

            var out: [PendingApplePayEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let entry = self.row(from: stmt) else { continue }
                out.append(entry)
            }
            return out
        } ?? []
    }

    /// Sum of the amounts still `pending` since `since` — the direct
    /// support for a per-period alert ("€X of uncategorized Apple Pay this
    /// week"). Negative (the expense convention); the caller applies
    /// `abs(...)` for display.
    func pendingTotal(since: Date) -> Double {
        store.read { db -> Double in
            var stmt: OpaquePointer?
            let sql = "SELECT COALESCE(SUM(amount), 0) FROM pending_apple_pay_entries WHERE status = 'pending' AND created_at >= ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, isoFormatter.string(from: since), -1, SQLITE_TRANSIENT_APPLEPAY)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_double(stmt, 0)
        } ?? 0
    }

    private func row(from stmt: OpaquePointer?) -> PendingApplePayEntry? {
        guard let stmt else { return nil }
        let id = Int(sqlite3_column_int(stmt, 0))
        let card = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : string(from: stmt, index: 1)
        let amount = sqlite3_column_double(stmt, 2)
        let merchant = string(from: stmt, index: 3)
        guard let status = PendingApplePayEntry.Status(rawValue: string(from: stmt, index: 4)) else { return nil }
        let matchedTransactionId = sqlite3_column_type(stmt, 5) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int(stmt, 5))
        let createdAt = isoFormatter.date(from: string(from: stmt, index: 6)) ?? Date()
        return PendingApplePayEntry(
            id: id, card: card, amount: amount, merchant: merchant,
            status: status, matchedTransactionId: matchedTransactionId, createdAt: createdAt
        )
    }
}
