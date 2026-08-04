import Foundation
import SQLite3

/// Pointeur de destructeur exigé par `sqlite3_bind_text` quand la chaîne liée est
/// temporaire : SQLite en fait alors une copie au lieu de conserver le pointeur.
let SQLITE_TRANSIENT_STORE = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Accès bas niveau à une base SQLite, indépendant de l'application.
///
/// Ce type ne connaît qu'une URL. Il n'importe ni `DatabaseManager` ni quoi que
/// ce soit du reste de l'app, ce qui permet deux choses :
///
/// - le brancher sur une base temporaire dans les tests, alors que les
///   repositories ouvraient jusqu'ici `DatabaseManager.shared.sqliteURL()` en
///   dur et n'étaient donc pas testables sans toucher la base réelle ;
/// - le compiler seul dans un harnais `swiftc`, sans le reste de la cible.
///
/// Le branchement sur la base courante de l'application vit à part, dans
/// `SQLiteLive.swift` — même séparation que `SyncPayloadStore` et `SyncLive`.
///
/// Chaque appel ouvre et referme sa connexion. C'est le comportement qui était
/// déjà en place dans les repositories ; le mutualiser ici permettra de le
/// changer en un seul endroit si le besoin s'en fait sentir.
struct SQLiteStore: Sendable {

    let databaseURL: URL

    /// Délai d'attente sur un verrou avant de renvoyer `SQLITE_BUSY`.
    ///
    /// Sans ce réglage, la moindre collision entre un écrivain et un lecteur
    /// échoue immédiatement. C'est ce qui provoquait les gels de l'interface sur
    /// macOS pendant l'activité de synchronisation : le correctif n'avait été
    /// appliqué qu'à `SyncPayloadStore`, laissant sans garde les connexions de
    /// tous les repositories.
    let busyTimeoutMs: Int32

    init(databaseURL: URL, busyTimeoutMs: Int32 = 3000) {
        self.databaseURL = databaseURL
        self.busyTimeoutMs = busyTimeoutMs
    }

    /// `false` si le fichier n'existe pas encore — cas normal avant l'onboarding.
    var databaseExists: Bool {
        FileManager.default.fileExists(atPath: databaseURL.path)
    }

    // MARK: - Connexions

    /// Ouvre en lecture seule et exécute `block`. Renvoie `nil` si la base est
    /// absente ou impossible à ouvrir — jamais une erreur, les appelants
    /// retombent sur une valeur par défaut.
    func read<T>(_ block: (OpaquePointer) -> T) -> T? {
        connect(flags: SQLITE_OPEN_READONLY, block)
    }

    /// Ouvre en lecture-écriture et exécute `block`.
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

    // MARK: - Écriture

    /// Prépare, lie et exécute un unique statement. `true` si SQLite a répondu
    /// `SQLITE_DONE`.
    @discardableResult
    func writeSingle(sql: String, bind: (OpaquePointer) -> Void) -> Bool {
        write { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)
            return sqlite3_step(stmt) == SQLITE_DONE
        } ?? false
    }
}

// MARK: - Lecture de colonnes

/// Lecture d'une colonne texte, chaîne vide si `NULL`.
///
/// Fonction libre et non méthode : les repositories l'appelaient déjà sous ce
/// nom via une copie privée dans chacun d'eux. La déclarer ainsi supprime cinq
/// implémentations identiques sans toucher aux centaines de sites d'appel.
func string(from statement: OpaquePointer?, index: Int32) -> String {
    guard let cString = sqlite3_column_text(statement, index) else { return "" }
    return String(cString: cString)
}
