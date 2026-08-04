import Foundation
import SQLite3
import Testing
@testable import Nemoris

/// Base SQLite jetable, au schéma courant, dans un dossier temporaire.
///
/// Fabriquée en appliquant la vraie chaîne de migrations via
/// `DatabaseManager.migrate(at:)` : les tests portent donc sur le schéma que
/// l'application produit réellement, et non sur un schéma recopié à la main qui
/// dériverait à la première migration oubliée.
///
/// La base de l'application n'est jamais touchée — c'est tout l'objet de
/// l'injection de `SQLiteStore` dans les repositories.
struct TestDatabase {

    let directory: URL
    let url: URL

    /// Store branché sur cette base, à passer aux repositories.
    var store: SQLiteStore { SQLiteStore(databaseURL: url) }

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nemoris-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        url = directory.appendingPathComponent("finance.sqlite")
        // Un fichier vide est une base SQLite valide et vide : les migrations
        // partent donc de user_version = 0 et créent tout le schéma.
        FileManager.default.createFile(atPath: url.path, contents: nil)

        if let errors = DatabaseManager.migrate(at: url) {
            throw TestDatabaseError.migrationFailed(errors)
        }
    }

    func destroy() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Version du schéma effectivement appliquée.
    var schemaVersion: Int {
        store.read { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        } ?? 0
    }

    /// Noms des tables présentes.
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

    /// Nombre de lignes d'une table, `-1` si la table est absente.
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

/// Date construite à partir d'un `yyyy-MM-dd`, pour des tests lisibles.
func date(_ iso: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: iso)!
}
