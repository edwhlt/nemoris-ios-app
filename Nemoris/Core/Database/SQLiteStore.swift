import Foundation
import SQLite3

/// Destructor pointer required by `sqlite3_bind_text` when the bound string
/// is temporary: SQLite then makes a copy instead of retaining the pointer.
let SQLITE_TRANSIENT_STORE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Low-level access to a SQLite database, independent of the application.
///
/// This type only knows a URL. It imports neither `DatabaseManager` nor
/// anything else from the rest of the app, which enables two things:
///
/// - wiring it to a temporary database in tests, whereas repositories used
///   to hard-code `DatabaseManager.shared.sqliteURL()` and were therefore
///   untestable without touching the real database;
/// - compiling it standalone in a `swiftc` harness, without the rest of the target.
///
/// The wiring to the app's current database lives separately, in
/// `SQLiteLive.swift` — the same split used for `SyncPayloadStore` and `SyncLive`.
///
/// Each call opens and closes its own connection. This is the behavior that
/// was already in place in the repositories; centralizing it here makes it
/// possible to change it in a single place if the need arises.
struct SQLiteStore: Sendable {

    let databaseURL: URL

    /// Wait time on a lock before returning `SQLITE_BUSY`.
    ///
    /// Without this setting, the slightest collision between a writer and a
    /// reader fails immediately. This is what caused the UI to freeze on
    /// macOS during sync activity: the fix had only been applied to
    /// `SyncPayloadStore`, leaving every repository connection unguarded.
    let busyTimeoutMs: Int32

    init(databaseURL: URL, busyTimeoutMs: Int32 = 3000) {
        self.databaseURL = databaseURL
        self.busyTimeoutMs = busyTimeoutMs
    }

    /// `false` if the file doesn't exist yet — the normal case before onboarding.
    var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    // MARK: - Connections

    /// Opens read-only and executes `block`. Returns `nil` if the database
    /// is absent or fails to open — never an error, callers fall back to a
    /// default value.
    func read<T>(_ block: (OpaquePointer) -> T) -> T? {
        connect(flags: SQLITE_OPEN_READONLY, block)
    }

    /// Opens read-write and executes `block`.
    func write<T>(_ block: (OpaquePointer) -> T) -> T? {
        connect(flags: SQLITE_OPEN_READWRITE, block)
    }

    private func connect<T>(flags: Int32, _ block: (OpaquePointer) -> T) -> T? {
        guard databaseExists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, busyTimeoutMs)
        return block(db)
    }

    // MARK: - Writing

    /// Prepares, binds and executes a single statement. `true` if SQLite
    /// returned `SQLITE_DONE`.
    ///
    /// On failure, the detail is written to the console. The boolean alone
    /// isn't enough to diagnose problems: a trigger bypass once made a
    /// creditor reassignment fail silently this way, and it took a dedicated
    /// test probe to get the one-line message that revealed the cause. Use
    /// `writeSingleReportingFailure` to retrieve that detail in code instead
    /// of on the console.
    @discardableResult
    func writeSingle(sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        guard let failure = writeSingleReportingFailure(sql: sql, bind: bind) else { return true }
        print("[SQLiteStore] \(failure)")
        return false
    }

    /// Same thing, but returns the failure detail instead of logging it.
    /// `nil` means the write succeeded.
    func writeSingleReportingFailure(sql: String,
                                     bind: (OpaquePointer) -> Void) -> SQLiteFailure? {
        guard databaseExists else {
            return SQLiteFailure(stage: .connexion, code: 0, extendedCode: 0,
                                 message: "base absente : \(databaseURL.lastPathComponent)", sql: sql)
        }
        return write { db -> SQLiteFailure? in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                defer { sqlite3_finalize(stmt) }
                return SQLiteFailure(db: db, stage: .preparation, sql: sql)
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                return SQLiteFailure(db: db, stage: .execution, sql: sql)
            }
            return nil
        } ?? SQLiteFailure(stage: .connexion, code: 0, extendedCode: 0,
                           message: "ouverture en écriture impossible", sql: sql)
    }
}

// MARK: - Failure detail

/// What SQLite reported when a write failed.
///
/// The extended code is kept: it's what distinguishes, for instance, a
/// uniqueness violation (`SQLITE_CONSTRAINT_UNIQUE`) from a foreign-key
/// violation, whereas the base code is `SQLITE_CONSTRAINT` in both cases.
struct SQLiteFailure: Error, CustomStringConvertible, Sendable {

    enum Stage: String, Sendable {
        case connexion   = "connexion"
        case preparation = "préparation"
        case execution   = "exécution"
    }

    let stage: Stage
    let code: Int32
    let extendedCode: Int32
    let message: String
    /// First meaningful line of the SQL, to give context without flooding the console.
    let sqlSummary: String

    init(stage: Stage, code: Int32, extendedCode: Int32, message: String, sql: String) {
        self.stage = stage
        self.code = code
        self.extendedCode = extendedCode
        self.message = message
        self.sqlSummary = Self.summarize(sql)
    }

    init(db: OpaquePointer, stage: Stage, sql: String) {
        self.init(stage: stage,
                  code: sqlite3_errcode(db),
                  extendedCode: sqlite3_extended_errcode(db),
                  message: String(cString: sqlite3_errmsg(db)),
                  sql: sql)
    }

    private static func summarize(_ sql: String) -> String {
        let ligne = sql
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? sql
        return ligne.count > 90 ? String(ligne.prefix(90)) + "…" : ligne
    }

    var description: String {
        "échec à la \(stage.rawValue) — code \(code)/\(extendedCode) : \(message) | \(sqlSummary)"
    }
}

// MARK: - Column reading

/// Reads a text column, empty string if `NULL`.
///
/// A free function rather than a method: repositories already called it
/// under this name via a private copy in each of them. Declaring it this
/// way removes five identical implementations without touching the hundreds
/// of call sites.
func string(from statement: OpaquePointer?, index: Int32) -> String {
    guard let cString = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: cString)
}
