import Foundation

/// App ↔ sync store bridge. Kept separate from SyncPayloadStore.swift so
/// that file stays free of any dependency on DatabaseManager or the rest
/// of the app target, and can be constructed against an arbitrary
/// database URL in tests.
extension SyncPayloadStore {
    /// Store bound to the app's current database.
    init() {
        self.init(databaseURL: DatabaseManager.shared.sqliteURL())
    }
}
