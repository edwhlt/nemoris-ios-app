import Foundation
import SQLite3

private let SQLITE_TRANSIENT_LIVESYNC = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - CRUD repository for investment_live_sync
//
// Stores only the links' non-sensitive metadata (provider_id, display_name,
// account_id, config_json, status). Credentials are handled separately by
// `InvestmentCredentialStore` (Keychain).

/// Swift model of a live sync link (one row of the investment_live_sync table).
struct InvestmentLiveSyncLink: Identifiable {
    let id: Int
    var providerId: String
    var displayName: String
    var accountId: Int?
    /// Raw JSON config (decoded by each provider as it needs).
    var configJSON: String?
    var enabled: Bool
    var lastSyncAt: Date?
    var lastSyncStatus: SyncStatus?
    var lastSyncMessage: LocalizedStringResource?
    var showTokensWithoutPrice: Bool
    var createdAt: Date

    enum SyncStatus: String, Hashable {
        case ok
        case error
        case pending // En cours de sync
    }

    /// Decodes `configJSON` into a convenient dictionary for the providers.
    var config: [String: String] {
        guard let json = configJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }
}

/// `@unchecked Sendable`: the class is stateless (each method opens/closes its
/// own SQLite connection). No shared mutable state.
final class LiveSyncRepository: @unchecked Sendable {

    static let shared = LiveSyncRepository()

    private let store: SQLiteStore

    /// `shared` remains the app's access point; the injectable init lets tests
    /// instantiate the repository on a temporary database.
    init(store: SQLiteStore = SQLiteStore()) {
        self.store = store
    }

    private let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Fetch

    func fetchLinks() -> [InvestmentLiveSyncLink] {
        var results: [InvestmentLiveSyncLink] = []
        let sql = """
            SELECT id, provider_id, display_name, account_id, config_json,
                   enabled, last_sync_at, last_sync_status, last_sync_message,
                   show_tokens_without_price, created_at
            FROM investment_live_sync
            -- `created_at` est horodaté à la seconde : deux liens créés dans la
            -- même seconde auraient un ordre indéfini. L'identifiant, croissant
            -- avec l'insertion, tranche l'égalité dans le bon sens.
            ORDER BY created_at DESC, id DESC;
            """
        executeQuery(sql) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let link = self.row(from: stmt) {
                    results.append(link)
                }
            }
        }
        return results
    }

    func fetchLink(id: Int) -> InvestmentLiveSyncLink? {
        var link: InvestmentLiveSyncLink?
        executeQuery("""
            SELECT id, provider_id, display_name, account_id, config_json,
                   enabled, last_sync_at, last_sync_status, last_sync_message,
                   show_tokens_without_price, created_at
            FROM investment_live_sync WHERE id = ?
            """) { stmt in
            sqlite3_bind_int(stmt, 1, Int32(id))
            if sqlite3_step(stmt) == SQLITE_ROW {
                link = self.row(from: stmt)
            }
        }
        return link
    }

    // MARK: - Mutations

    /// Creates a new link and returns its ID. Credentials must be stored
    /// separately via `InvestmentCredentialStore.store(linkId:..., providerId:..., credentials:...)`.
    @discardableResult
    func addLink(providerId: String,
                 displayName: String,
                 accountId: Int?,
                 config: [String: String],
                 showTokensWithoutPrice: Bool = true) -> Int? {
        let configJSON: String? = {
            guard let data = try? JSONEncoder().encode(config) else { return nil }
            return String(data: data, encoding: .utf8)
        }()

        var insertedId: Int?
        executeWrite("""
            INSERT INTO investment_live_sync
                (provider_id, display_name, account_id, config_json, enabled,
                 show_tokens_without_price, created_at)
            VALUES (?, ?, ?, ?, 1, ?, ?)
            """) { stmt, db in
            sqlite3_bind_text(stmt, 1, providerId, -1, SQLITE_TRANSIENT_LIVESYNC)
            sqlite3_bind_text(stmt, 2, displayName, -1, SQLITE_TRANSIENT_LIVESYNC)
            if let accountId {
                sqlite3_bind_int(stmt, 3, Int32(accountId))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let configJSON {
                sqlite3_bind_text(stmt, 4, configJSON, -1, SQLITE_TRANSIENT_LIVESYNC)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int(stmt, 5, showTokensWithoutPrice ? 1 : 0)
            sqlite3_bind_text(stmt, 6, self.dateFormatter.string(from: Date()), -1, SQLITE_TRANSIENT_LIVESYNC)

            if sqlite3_step(stmt) == SQLITE_DONE {
                insertedId = Int(sqlite3_last_insert_rowid(db))
            }
        }
        return insertedId
    }

    @discardableResult
    func updateLink(_ link: InvestmentLiveSyncLink) -> Bool {
        executeWrite("""
            UPDATE investment_live_sync SET
                provider_id = ?, display_name = ?, account_id = ?, config_json = ?,
                enabled = ?, show_tokens_without_price = ?
            WHERE id = ?
            """) { stmt, _ in
            sqlite3_bind_text(stmt, 1, link.providerId, -1, SQLITE_TRANSIENT_LIVESYNC)
            sqlite3_bind_text(stmt, 2, link.displayName, -1, SQLITE_TRANSIENT_LIVESYNC)
            if let acc = link.accountId {
                sqlite3_bind_int(stmt, 3, Int32(acc))
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            if let json = link.configJSON {
                sqlite3_bind_text(stmt, 4, json, -1, SQLITE_TRANSIENT_LIVESYNC)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            sqlite3_bind_int(stmt, 5, link.enabled ? 1 : 0)
            sqlite3_bind_int(stmt, 6, link.showTokensWithoutPrice ? 1 : 0)
            sqlite3_bind_int(stmt, 7, Int32(link.id))
        } != nil
    }

    /// Updates only the status columns (useful after a sync).
    func updateSyncStatus(linkId: Int,
                          status: InvestmentLiveSyncLink.SyncStatus,
                          message: LocalizedStringResource?,
                          syncedAt: Date = Date()) {
        executeWrite("""
            UPDATE investment_live_sync SET
                last_sync_at = ?, last_sync_status = ?, last_sync_message = ?
            WHERE id = ?
            """) { stmt, _ in
            sqlite3_bind_text(stmt, 1, self.dateFormatter.string(from: syncedAt), -1, SQLITE_TRANSIENT_LIVESYNC)
            sqlite3_bind_text(stmt, 2, status.rawValue, -1, SQLITE_TRANSIENT_LIVESYNC)
            if let msg = message, let json = Self.encodeMessage(msg) {
                sqlite3_bind_text(stmt, 3, json, -1, SQLITE_TRANSIENT_LIVESYNC)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int(stmt, 4, Int32(linkId))
        }
    }

    /// `last_sync_message` remains a `TEXT` column — the `LocalizedStringResource`
    /// is encoded there as JSON (it's `Codable`) rather than through a column
    /// migration. `decodeMessage` falls back to the RAW text (`stringLiteral:`,
    /// verbatim, non-reactive) if the content isn't valid JSON — which covers
    /// rows holding a plain `String`, without ever making the read fail.
    private static func encodeMessage(_ resource: LocalizedStringResource) -> String? {
        guard let data = try? JSONEncoder().encode(resource) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeMessage(_ raw: String) -> LocalizedStringResource {
        if let data = raw.data(using: .utf8),
           let resource = try? JSONDecoder().decode(LocalizedStringResource.self, from: data) {
            return resource
        }
        return LocalizedStringResource(stringLiteral: raw)
    }

    /// Deletes a link. The caller must ALSO delete the Keychain credentials via
    /// `InvestmentCredentialStore.delete(linkId:..., providerId:...)`.
    @discardableResult
    func deleteLink(id: Int) -> Bool {
        executeWrite("DELETE FROM investment_live_sync WHERE id = ?") { stmt, _ in
            sqlite3_bind_int(stmt, 1, Int32(id))
        } != nil
    }

    // MARK: - SQLite helpers

    private func row(from stmt: OpaquePointer?) -> InvestmentLiveSyncLink? {
        guard let stmt else { return nil }
        let id = Int(sqlite3_column_int(stmt, 0))
        guard let providerCStr = sqlite3_column_text(stmt, 1),
              let displayCStr = sqlite3_column_text(stmt, 2) else { return nil }
        let provider = String(cString: providerCStr)
        let display = String(cString: displayCStr)
        let accountId: Int? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
            ? nil : Int(sqlite3_column_int(stmt, 3))
        let configJSON: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 4))
        let enabled = sqlite3_column_int(stmt, 5) != 0
        let lastSyncAt: Date? = sqlite3_column_type(stmt, 6) == SQLITE_NULL
            ? nil : dateFormatter.date(from: String(cString: sqlite3_column_text(stmt, 6)))
        let lastStatus: InvestmentLiveSyncLink.SyncStatus? = sqlite3_column_type(stmt, 7) == SQLITE_NULL
            ? nil : InvestmentLiveSyncLink.SyncStatus(rawValue: String(cString: sqlite3_column_text(stmt, 7)))
        let lastMessage: LocalizedStringResource? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? nil : Self.decodeMessage(String(cString: sqlite3_column_text(stmt, 8)))
        let showTokens = sqlite3_column_int(stmt, 9) != 0
        let createdAt = sqlite3_column_type(stmt, 10) == SQLITE_NULL
            ? Date() : (dateFormatter.date(from: String(cString: sqlite3_column_text(stmt, 10))) ?? Date())

        return InvestmentLiveSyncLink(
            id: id, providerId: provider, displayName: display, accountId: accountId,
            configJSON: configJSON, enabled: enabled, lastSyncAt: lastSyncAt,
            lastSyncStatus: lastStatus, lastSyncMessage: lastMessage,
            showTokensWithoutPrice: showTokens, createdAt: createdAt
        )
    }

    private func executeQuery(_ sql: String, _ bind: (OpaquePointer?) -> Void) {
        guard store.databaseExists else { return }
        var db: OpaquePointer?
        let url = store.databaseURL
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db else { sqlite3_close(db); return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
    }

    /// Returns nil if execution failed, otherwise a Void marker (used by
    /// updateLink/deleteLink to produce a Bool).
    @discardableResult
    private func executeWrite(_ sql: String,
                              _ bind: (OpaquePointer?, OpaquePointer?) -> Void) -> Void? {
        guard store.databaseExists else { return nil }
        var db: OpaquePointer?
        let url = store.databaseURL
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, db)
        return sqlite3_step(stmt) == SQLITE_DONE ? () : nil
    }
}
