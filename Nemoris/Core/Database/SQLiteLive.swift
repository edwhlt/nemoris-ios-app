import Foundation

/// Bridge between `SQLiteStore` and the app's current database.
///
/// Kept separate from `SQLiteStore.swift` so the latter stays independently
/// compilable, without pulling in `DatabaseManager` or the rest of the
/// target — this is what lets test harnesses compile it with `swiftc`. Same
/// split as `SyncPayloadStore` and `SyncLive`.
extension SQLiteStore {
    /// Store wired to the app's database.
    init() {
        self.init(databaseURL: DatabaseManager.shared.sqliteURL())
    }
}
