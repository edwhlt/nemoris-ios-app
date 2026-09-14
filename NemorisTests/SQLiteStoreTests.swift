import Foundation
import SQLite3
import Testing
@testable import Nemoris

/// The SQLite access layer: injection, lock timeout, and above all
/// surfacing errors.
@Suite("SQLiteStore")
struct SQLiteStoreTests {

    @Test("Une écriture réussie ne rend aucun échec")
    func ecritureReussie() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        let echec = db.store.writeSingleReportingFailure(
            sql: "INSERT INTO accounts (name, type) VALUES (?, ?);") { stmt in
                sqlite3_bind_text(stmt, 1, "Courant", -1, SQLITE_TRANSIENT_STORE)
                sqlite3_bind_text(stmt, 2, "COURANT", -1, SQLITE_TRANSIENT_STORE)
            }

        #expect(echec == nil)
        #expect(db.count("accounts") == 1)
    }

    @Test("Une violation de contrainte remonte son code et son message")
    func violationDeContrainte() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        // `uuid` carries a unique index: the second insert must be rejected.
        func insere() -> SQLiteFailure? {
            db.store.writeSingleReportingFailure(
                sql: "INSERT INTO accounts (name, type, uuid) VALUES (?, ?, 'meme-uuid');") { stmt in
                    sqlite3_bind_text(stmt, 1, "Courant", -1, SQLITE_TRANSIENT_STORE)
                    sqlite3_bind_text(stmt, 2, "COURANT", -1, SQLITE_TRANSIENT_STORE)
                }
        }

        #expect(insere() == nil)

        let echec = insere()
        #expect(echec != nil, "la seconde insertion aurait dû être refusée")
        #expect(echec?.stage == .execution)
        #expect(echec?.code == SQLITE_CONSTRAINT)
        // The extended code is what distinguishes a uniqueness violation from a
        // foreign-key one, where the base code is SQLITE_CONSTRAINT in both cases.
        // Swift's SQLite3 module doesn't expose the extended constants:
        // SQLITE_CONSTRAINT_UNIQUE equals SQLITE_CONSTRAINT | (8 << 8) = 2067.
        let contrainteUnique = SQLITE_CONSTRAINT | (8 << 8)
        #expect(echec?.extendedCode == contrainteUnique,
                "code étendu reçu : \(echec?.extendedCode ?? -1)")
        #expect(echec?.message.contains("UNIQUE") == true,
                "message reçu : \(echec?.message ?? "aucun")")
    }

    @Test("Un SQL invalide échoue à la préparation, pas à l'exécution")
    func sqlInvalide() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        let echec = db.store.writeSingleReportingFailure(
            sql: "INSERT INTO table_qui_nexiste_pas (x) VALUES (1);") { _ in }

        #expect(echec?.stage == .preparation)
        #expect(echec?.message.contains("no such table") == true,
                "message reçu : \(echec?.message ?? "aucun")")
    }

    @Test("Une base absente est signalée comme telle, sans planter")
    func baseAbsente() {
        let inexistante = SQLiteStore(
            databaseURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("nemoris-inexistante-\(UUID().uuidString).sqlite"))

        #expect(inexistante.databaseExists == false)
        #expect(inexistante.read { _ in 1 } == nil)
        #expect(inexistante.writeSingle(sql: "SELECT 1;") { _ in } == false)

        let echec = inexistante.writeSingleReportingFailure(sql: "SELECT 1;") { _ in }
        #expect(echec?.stage == .connexion)
    }

    @Test("Le résumé du SQL tient sur une ligne")
    func resumeDuSQL() throws {
        let db = try TestDatabase()
        defer { db.destroy() }

        let echec = db.store.writeSingleReportingFailure(sql: """

            INSERT INTO table_absente (colonne_une, colonne_deux)
            VALUES (?, ?);
            """) { _ in }

        #expect(echec?.sqlSummary.contains("\n") == false, "le résumé ne doit pas être multiligne")
        #expect(echec?.sqlSummary.hasPrefix("INSERT INTO table_absente") == true,
                "résumé reçu : \(echec?.sqlSummary ?? "aucun")")
    }
}
