import Foundation
import SQLite3

struct PayeeSuggestion: Hashable {
    let displayName: String          // "Carrefour Market — Oullins"
    let canonicalName: String        // "carrefour market" (technique côté engine)
    let engineMerchantId: String     // "carrefour_market"
    let city: String?
    let country: String?
    let existingGroup: ResolvedPayeeGroup?
    let suggestedGroupName: String?  // si pas de groupe et plusieurs payees similaires existent
}

struct ResolvedPayeeGroup: Hashable {
    let id: Int
    let displayName: String
    let engineMerchantId: String?
}

/// Écriture des payees dans `finance.sqlite` une fois qu'une suggestion a été
/// validée par l'utilisateur (via `ImportSessionViewModel.commit()`).
///
/// La RÉSOLUTION (libellé brut → décision) ne vit plus ici : elle est faite
/// directement par `engine.resolve()` + `ImportSessionViewModel.snapshot(from:allTiers:)`,
/// qui reste la seule source de vérité pour le routage `.matched`/`.suggestCreate`/etc.
/// (cf. `TierResolutionSnapshot`). Cette classe ne fait plus que le dernier kilomètre :
/// transformer une `PayeeSuggestion` déjà décidée en INSERT SQL.
@MainActor
final class TierResolver {

    private let dbPath: String

    init(dbPath: String) {
        self.dbPath = dbPath
    }

    // MARK: - Création (appelée depuis l'UI après confirmation user)

    /// Crée un payee (et son groupe si demandé) et retourne son id. À appeler depuis l'UI
    /// après que l'utilisateur a validé la suggestion.
    @discardableResult
    func commitNewPayee(_ suggestion: PayeeSuggestion, useGroup: Bool) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        var groupId: Int? = suggestion.existingGroup?.id
        if useGroup, groupId == nil, let groupName = suggestion.suggestedGroupName {
            groupId = insertGroup(db: db, displayName: groupName, engineMerchantId: suggestion.engineMerchantId)
        }

        return insertPayee(db: db, suggestion: suggestion, groupId: groupId)
    }

    /// Crée un payee "personne" (contact P2P) sans lien engine.
    @discardableResult
    func commitContactPayee(name: String) -> Int? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        let sql = "INSERT INTO payees (name, custom) VALUES (?, 1)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    // MARK: - SQLite helpers

    private func insertGroup(db: OpaquePointer, displayName: String, engineMerchantId: String) -> Int? {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO payee_groups (display_name, engine_merchant_id) VALUES (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, displayName, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, engineMerchantId, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    private func insertPayee(db: OpaquePointer, suggestion: PayeeSuggestion, groupId: Int?) -> Int? {
        let sql = """
            INSERT INTO payees (name, city, country, engine_merchant_id, group_id, custom)
            VALUES (?, ?, ?, ?, ?, 0)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, suggestion.displayName, -1, sqliteTransient)
        bindOptionalText(stmt, 2, suggestion.city)
        bindOptionalText(stmt, 3, suggestion.country)
        sqlite3_bind_text(stmt, 4, suggestion.engineMerchantId, -1, sqliteTransient)
        if let gid = groupId {
            sqlite3_bind_int(stmt, 5, Int32(gid))
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return Int(sqlite3_last_insert_rowid(db))
    }

    private func bindOptionalText(_ stmt: OpaquePointer, _ idx: Int32, _ value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }
}

/// SQLITE_TRANSIENT pour bind_text : oblige SQLite à copier la string Swift en interne.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
