import Foundation

/// Pont app ↔ store de sync. Séparé de SyncPayloadStore.swift pour que ce
/// dernier reste compilable standalone (harness de tests NemorisApp/Tests/
/// via swiftc, sans tirer DatabaseManager ni le reste du target).
extension SyncPayloadStore {
    /// Store branché sur la base courante de l'app.
    init() {
        self.init(databaseURL: DatabaseManager.shared.sqliteURL())
    }
}
