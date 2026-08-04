import Foundation

/// Pont entre `SQLiteStore` et la base courante de l'application.
///
/// Séparé de `SQLiteStore.swift` pour que ce dernier reste compilable seul, sans
/// tirer `DatabaseManager` ni le reste de la cible — c'est ce qui permet aux
/// harnais de tests de le compiler avec `swiftc`. Même découpage que
/// `SyncPayloadStore` et `SyncLive`.
extension SQLiteStore {
    /// Store branché sur la base de l'application.
    init() {
        self.init(databaseURL: DatabaseManager.shared.sqliteURL())
    }
}
