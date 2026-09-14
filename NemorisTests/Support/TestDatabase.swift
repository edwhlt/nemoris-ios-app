import Foundation
import SQLite3
import Testing
@testable import Nemoris

/// A disposable SQLite database, at the current schema, in a temp directory.
///
/// Built by applying the real migration chain via
/// `DatabaseManager.migrate(at:)`: tests therefore run against the schema
/// the app actually produces, not a hand-copied schema that would
/// drift on the first forgotten migration.
///
/// The app's own database is never touched — that's the whole point of
/// injecting `SQLiteStore` into the repositories.
struct TestDatabase {

    let directory: URL
    let url: URL

    /// A store wired to this database, to pass to the repositories.
    var store: SQLiteStore { SQLiteStore(databaseURL: url) }

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nemoris-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        url = directory.appendingPathComponent("finance.sqlite")
        // An empty file is a valid, empty SQLite database: migrations
        // therefore start from user_version = 0 and create the whole schema.
        FileManager.default.createFile(atPath: url.path, contents: nil)

        if let errors = DatabaseManager.migrate(at: url) {
            throw TestDatabaseError.migrationFailed(errors)
        }
    }

    func destroy() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The schema version actually applied.
    var schemaVersion: Int {
        store.read { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        } ?? 0
    }

    /// The names of the tables present.
    var tables: Set<String> {
        store.read { db in
            var stmt: OpaquePointer?
            let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return Set<String>() }
            defer { sqlite3_finalize(stmt) }
            var names = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.insert(string(from: stmt, index: 0))
            }
            return names
        } ?? []
    }

    /// The row count of a table, `-1` if the table doesn't exist.
    func count(_ table: String) -> Int {
        store.read { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
        } ?? -1
    }
}

enum TestDatabaseError: Error, CustomStringConvertible {
    case migrationFailed(String)

    var description: String {
        switch self {
        case .migrationFailed(let details): return "Migration échouée : \(details)"
        }
    }
}

/// A date built from `yyyy-MM-dd`, for readable tests.
func date(_ iso: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: iso)!
}
