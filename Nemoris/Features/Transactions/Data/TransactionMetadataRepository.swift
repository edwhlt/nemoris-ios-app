import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Modèles

/// Une clé de métadonnée définie par l'utilisateur (« Mode de paiement »,
/// « Projet », « Pro / Perso »…).
///
/// ⚠️ AUCUNE clé n'existe par défaut dans une base neuve. C'est le cœur du
/// changement : l'app n'impose plus « mode de paiement » à qui n'en a pas
/// l'usage. Les bases existantes conservent la leur, recréée à l'identique par
/// la migration v46 à partir de leurs données.
struct TransactionMetadataKey: Identifiable, Hashable, Sendable {
    var id: Int
    var name: String
    /// SF Symbol optionnel.
    var icon: String?
    var sortOrder: Int
    /// Rôle fonctionnel, `nil` pour une clé purement libre.
    var role: MetadataKeyRole?

    var displayIcon: String { icon ?? "tag" }
}

/// Rôles reconnus par l'app. Volontairement minimal : un seul aujourd'hui.
///
/// Une clé sans rôle est une étiquette libre, que rien ne remplit
/// automatiquement — c'est le cas par défaut et de loin le plus courant.
enum MetadataKeyRole: String, Hashable, Sendable, CaseIterable {
    /// L'import y écrit ce qu'il déduit du libellé (CB, VIREMENT, PRÉLÈVEMENT…).
    ///
    /// ⚠️ Sans clé portant ce rôle, l'indice d'import est simplement IGNORÉ —
    /// on ne crée pas une clé dans le dos de l'utilisateur. C'est ce qui permet
    /// à une base neuve de n'avoir aucune métadonnée tant qu'il n'en veut pas,
    /// tout en préservant le comportement des bases migrées.
    case paymentMethod = "payment_method"

    var displayName: String {
        switch self {
        case .paymentMethod: return "Renseignée par l'import (mode de paiement)"
        }
    }
}

/// Une valeur posée sur une transaction.
struct TransactionMetadataValue: Identifiable, Hashable, Sendable {
    var id: Int
    var transactionId: Int
    var keyId: Int
    var value: String
    /// Nom de la clé, joint pour l'affichage.
    var keyName: String = ""
    var keyIcon: String?
}

// MARK: - Repository

/// Seul point d'accès aux métadonnées de transaction (migration v46).
struct TransactionMetadataRepository {

    private let store: SQLiteStore

    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }

    // MARK: - Clés

    func fetchKeys() -> [TransactionMetadataKey] {
        readOnly { db in
            var out: [TransactionMetadataKey] = []
            let sql = """
                SELECT id, name, icon, sort_order, role
                FROM transaction_metadata_keys
                ORDER BY sort_order, name COLLATE NOCASE;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(TransactionMetadataKey(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    name: text(stmt, 1) ?? "",
                    icon: text(stmt, 2),
                    sortOrder: Int(sqlite3_column_int(stmt, 3)),
                    role: text(stmt, 4).flatMap(MetadataKeyRole.init(rawValue:))))
            }
            return out
        } ?? []
    }

    /// La clé portant un rôle donné, s'il en existe une.
    func key(withRole role: MetadataKeyRole) -> TransactionMetadataKey? {
        fetchKeys().first { $0.role == role }
    }

    /// Crée une clé. `nil` si le nom est vide ou déjà pris.
    @discardableResult
    func addKey(name: String, icon: String?, role: MetadataKeyRole?) -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return readWrite { db in
            // ⚠️ Un rôle est EXCLUSIF (index UNIQUE partiel) : on libère le
            // précédent porteur plutôt que de laisser l'INSERT échouer sur une
            // contrainte que l'utilisateur ne peut pas comprendre.
            if let role { releaseRole(db, role) }
            let sql = """
                INSERT INTO transaction_metadata_keys (name, icon, sort_order, role, created_at, uuid, updated_at)
                VALUES (?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM transaction_metadata_keys),
                        ?, ?, lower(hex(randomblob(16))), ?);
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            let now = Self.timestamp()
            sqlite3_bind_text(stmt, 1, trimmed, -1, SQLITE_TRANSIENT)
            bindOptText(stmt, 2, icon)
            bindOptText(stmt, 3, role?.rawValue)
            sqlite3_bind_text(stmt, 4, now, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, now, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            return Int(sqlite3_last_insert_rowid(db))
        } ?? nil
    }

    @discardableResult
    func updateKey(_ key: TransactionMetadataKey) -> Bool {
        readWrite { db in
            if let role = key.role { releaseRole(db, role, except: key.id) }
            let sql = """
                UPDATE transaction_metadata_keys
                SET name = ?, icon = ?, sort_order = ?, role = ?, updated_at = ?
                WHERE id = ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, key.name, -1, SQLITE_TRANSIENT)
            bindOptText(stmt, 2, key.icon)
            sqlite3_bind_int(stmt, 3, Int32(key.sortOrder))
            bindOptText(stmt, 4, key.role?.rawValue)
            sqlite3_bind_text(stmt, 5, Self.timestamp(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, Int32(key.id))
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
    }

    /// Supprime une clé ET toutes ses valeurs (ON DELETE CASCADE).
    @discardableResult
    func deleteKey(id: Int) -> Bool {
        readWrite { db in
            // ⚠️ Le CASCADE dépend de `PRAGMA foreign_keys` : on l'active
            // explicitement, il est OFF par défaut sur chaque connexion SQLite.
            sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM transaction_metadata_keys WHERE id = ?;",
                                     -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(id))
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
    }

    /// Retire le rôle à la clé qui le portait, pour préserver son exclusivité.
    private func releaseRole(_ db: OpaquePointer, _ role: MetadataKeyRole, except keyId: Int? = nil) {
        let sql = "UPDATE transaction_metadata_keys SET role = NULL, updated_at = ? WHERE role = ? AND id <> ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, Self.timestamp(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, role.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(keyId ?? -1))
        sqlite3_step(stmt)
    }

    // MARK: - Valeurs

    func fetchValues(transactionId: Int) -> [TransactionMetadataValue] {
        readOnly { db in
            let sql = """
                SELECT v.id, v.transaction_id, v.key_id, v.value, k.name, k.icon
                FROM transaction_metadata_values v
                JOIN transaction_metadata_keys k ON k.id = v.key_id
                WHERE v.transaction_id = ?
                ORDER BY k.sort_order, k.name COLLATE NOCASE;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(transactionId))
            var out: [TransactionMetadataValue] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(TransactionMetadataValue(
                    id: Int(sqlite3_column_int(stmt, 0)),
                    transactionId: Int(sqlite3_column_int(stmt, 1)),
                    keyId: Int(sqlite3_column_int(stmt, 2)),
                    value: text(stmt, 3) ?? "",
                    keyName: text(stmt, 4) ?? "",
                    keyIcon: text(stmt, 5)))
            }
            return out
        } ?? []
    }

    /// Toutes les valeurs déjà employées pour une clé, les plus fréquentes
    /// d'abord — ce qui alimente les suggestions de saisie.
    ///
    /// ⚠️ Suggestions seulement : aucune contrainte en base. Une métadonnée
    /// reste du texte libre, sinon ce serait une seconde table de référence
    /// déguisée, exactement ce qu'on vient de retirer.
    func distinctValues(keyId: Int, limit: Int = 20) -> [String] {
        readOnly { db in
            let sql = """
                SELECT value, COUNT(*) AS n
                FROM transaction_metadata_values
                WHERE key_id = ?
                GROUP BY value COLLATE NOCASE
                ORDER BY n DESC, value COLLATE NOCASE
                LIMIT ?;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(keyId))
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var out: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let value = text(stmt, 0), !value.isEmpty { out.append(value) }
            }
            return out
        } ?? []
    }

    /// Pose (ou remplace) la valeur d'une clé sur une transaction. Une valeur
    /// vide RETIRE la métadonnée — c'est ainsi que l'utilisateur l'efface.
    @discardableResult
    func setValue(_ value: String, keyId: Int, transactionId: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return removeValue(keyId: keyId, transactionId: transactionId) }
        return readWrite { db in
            let sql = """
                INSERT INTO transaction_metadata_values (transaction_id, key_id, value, uuid, updated_at)
                VALUES (?, ?, ?, lower(hex(randomblob(16))), ?)
                ON CONFLICT(transaction_id, key_id) DO UPDATE SET
                    value = excluded.value,
                    updated_at = excluded.updated_at;
                """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(transactionId))
            sqlite3_bind_int(stmt, 2, Int32(keyId))
            sqlite3_bind_text(stmt, 3, trimmed, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, Self.timestamp(), -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
    }

    @discardableResult
    func removeValue(keyId: Int, transactionId: Int) -> Bool {
        readWrite { db in
            let sql = "DELETE FROM transaction_metadata_values WHERE transaction_id = ? AND key_id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return false }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(transactionId))
            sqlite3_bind_int(stmt, 2, Int32(keyId))
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
    }

    /// Écrit l'indice déduit par l'import sur la clé qui porte le rôle
    /// correspondant. No-op s'il n'y en a pas — cf. `MetadataKeyRole`.
    @discardableResult
    func applyImportHint(_ hint: String?, transactionId: Int,
                         paymentMethodKeyId: Int?) -> Bool {
        guard let hint, !hint.isEmpty, let keyId = paymentMethodKeyId else { return false }
        return setValue(hint, keyId: keyId, transactionId: transactionId)
    }

    /// Identifiants des transactions portant une valeur donnée — alimente le
    /// filtre des listes, sur le modèle du filtre par tag.
    func transactionIds(keyId: Int, value: String?) -> Set<Int> {
        readOnly { db in
            var sql = "SELECT transaction_id FROM transaction_metadata_values WHERE key_id = ?"
            if value != nil { sql += " AND value = ? COLLATE NOCASE" }
            sql += ";"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(keyId))
            if let value { sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT) }
            var out: Set<Int> = []
            while sqlite3_step(stmt) == SQLITE_ROW { out.insert(Int(sqlite3_column_int(stmt, 0))) }
            return out
        } ?? []
    }

    // MARK: - Plomberie

    private func readOnly<T>(_ body: (OpaquePointer) -> T) -> T? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        return body(db)
    }

    private func readWrite<T>(_ body: (OpaquePointer) -> T) -> T? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.databaseURL.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        return body(db)
    }

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }

    private func bindOptText(_ stmt: OpaquePointer, _ index: Int32, _ value: String?) {
        if let value, !value.isEmpty {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
