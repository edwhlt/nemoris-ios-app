import Foundation
import CloudKit
import SQLite3
#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
    /// Posted (main thread) after a batch of REMOTE changes has been applied
    /// to the local database — the UI should reload its data.
    /// Observed in NemorisApp → bumps AppState.dataRefreshToken.
    static let nemorisSyncDidApplyRemoteChanges = Notification.Name("nemorisSyncDidApplyRemoteChanges")
}

/// CloudKit synchronization engine.
///
/// `CKSyncEngine` (iOS 17+) wrapper around the SQLite database:
///   • single private zone `NemorisZone` in the app's iCloud container
///   • 1 CloudKit record = 1 SQLite row, recordName = "<table>_<uuid>",
///     recordType = table name
///   • payload = JSON blob in `encryptedValues["p"]` → E2E encryption, keys
///     in the user's iCloud keychain, Apple cannot read it
///   • conflicts resolved last-writer-wins via `updated_at` (payload "t")
///   • CKSyncEngine state serialized in `sync_meta['ck_state']`
///
/// Local change detection comes from the SyncSchema triggers:
/// `sync_pending` + `sync_tombstones` are pushed to the engine at boot, on
/// activation, and on every "Sync now".
///
/// Strict opt-in: nothing runs while `sync_meta['sync_enabled'] != '1'`.
actor CloudSyncEngine {

    static let shared = CloudSyncEngine()

    /// Must match the com.apple.developer.icloud-container-identifiers entitlement.
    private static let containerIdentifier = "iCloud.fr.hedwin.nemoris"
    private static let zoneID = CKRecordZone.ID(zoneName: "NemorisZone", ownerName: CKCurrentUserDefaultName)

    private let store = SyncPayloadStore()
    private var engine: CKSyncEngine?

    /// queued_at captured at the moment a row goes into an upload batch —
    /// lets a row re-edited during the send NOT be purged from sync_pending
    /// (its new version needs to go out again).
    private var inFlightQueuedAt: [String: String] = [:]   // recordName → queued_at

    /// True as soon as a batch in the current cycle produced at least one
    /// send failure — prevents `markSyncDone()` from showing an up-to-date
    /// "Last sync" while some records were rejected by the server.
    private var cycleHadSaveFailures = false

    private init() {}

    // MARK: - Public API

    struct Status: Sendable {
        var enabled: Bool
        var accountAvailable: Bool
        var pendingCount: Int
        var lastSyncAt: String?
        var lastError: String?
        /// PERMANENT server-side error (e.g. CloudKit schema not deployed
        /// to Production) — sync is active but nothing goes out until an
        /// external action is taken. Nothing is lost (sync_pending).
        var isBlocked: Bool
    }

    enum SyncError: LocalizedError {
        case iCloudUnavailable(CKAccountStatus)
        case notEnabled

        var errorDescription: String? {
            switch self {
            case .iCloudUnavailable(let status):
                switch status {
                case .noAccount: return "Aucun compte iCloud connecté sur cet appareil."
                case .restricted: return "L'accès iCloud est restreint (contrôle parental ou MDM)."
                case .temporarilyUnavailable: return "iCloud est temporairement indisponible. Réessaie dans quelques instants."
                default: return "iCloud indisponible."
                }
            case .notEnabled:
                return "La synchronisation iCloud n'est pas activée."
            }
        }
    }

    var isEnabled: Bool { store.metaValue("sync_enabled") == "1" }

    func status() async -> Status {
        let account = (try? await CKContainer(identifier: Self.containerIdentifier).accountStatus()) ?? .couldNotDetermine
        return Status(
            enabled: isEnabled,
            accountAvailable: account == .available,
            pendingCount: store.pendingCount(),
            lastSyncAt: store.metaValue("last_sync_at"),
            lastError: store.metaValue("last_sync_error"),
            isBlocked: store.metaValue("last_sync_error_permanent") == "1"
        )
    }

    /// Called at launch (NemorisApp init). No-op if sync isn't enabled.
    func bootIfEnabled() async {
        guard isEnabled, engine == nil else { return }
        startEngine()
        pushLocalChangesToEngine()
        await registerForPushes()
    }

    /// Registers the app with APNs for silent CloudKit pushes.
    /// CKSyncEngine manages its own subscription and incoming push
    /// processing — the only job here is the system registration. No user
    /// prompt: silent notifications don't require permission. Only called
    /// while sync is active (strict opt-in).
    private func registerForPushes() async {
        #if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
        #endif
    }

    /// Opt-in activation from Settings. Checks the iCloud account, creates
    /// the zone, queues ALL rows (initial scan), and runs a first
    /// send+fetch cycle.
    func enable() async throws {
        let account = try await CKContainer(identifier: Self.containerIdentifier).accountStatus()
        guard account == .available else { throw SyncError.iCloudUnavailable(account) }

        // Safety snapshot BEFORE the first merge — if the initial sync-down
        // goes wrong (unexpected merge), the user can restore the exact
        // state from before activation. Best-effort (failure non-blocking).
        _ = try? await MainActor.run { try BackupService.shared.createSnapshot() }

        store.setMeta("sync_enabled", "1")
        store.deleteMeta("last_sync_error")
        store.deleteMeta("last_sync_error_permanent")
        cycleHadSaveFailures = false
        startEngine()

        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        // ⚠️ The seed is NOT purged here: a FIRST device (empty vault) that
        // enables sync would lose its default categories without receiving
        // anything back. Merging seeds across devices is guaranteed by
        // deterministic adoption by name when records are applied
        // (SyncPayloadStore.nameAdoptionTables — the smallest uuid wins).
        // The "Join via iCloud" flow creates a database WITHOUT a seed in
        // the first place (createNewDatabase(seedDefaults: false)).
        store.enqueueAllRows()
        pushLocalChangesToEngine()
        try await engine.sendChanges()
        try await engine.fetchChanges()
        if !cycleHadSaveFailures { markSyncDone() }
        await registerForPushes()
    }

    /// Disable: stops the engine and clears the local sync state.
    /// Business data and server records remain intact — re-enabling redoes
    /// an initial scan + LWW merge.
    func disable() {
        engine = nil
        inFlightQueuedAt = [:]
        store.setMeta("sync_enabled", "0")
        store.clearAllSyncState()
    }

    /// Manual cycle: pushes the local queue, sends, fetches.
    /// `markSyncDone()` only if no record was rejected — the
    /// `sentRecordZoneChanges` events (and thus `handleFailedSave`) are
    /// delivered before `sendChanges()` returns, everything being actor-isolated.
    func syncNow() async throws {
        guard isEnabled else { throw SyncError.notEnabled }
        if engine == nil { startEngine() }
        guard let engine else { return }
        store.deleteMeta("last_sync_error")
        store.deleteMeta("last_sync_error_permanent")
        cycleHadSaveFailures = false
        pushLocalChangesToEngine()
        try await engine.sendChanges()
        try await engine.fetchChanges()
        if !cycleHadSaveFailures { markSyncDone() }
    }

    /// Lightweight auto-sync triggered on app transitions (background /
    /// foreground). Transfers local writes accumulated via triggers
    /// (sync_pending) into the CKSyncEngine state, which sends them on its
    /// own in the background according to its own scheduling. No-op if
    /// sync is disabled.
    ///
    /// This is the bridge between the SQLite write (captured by triggers
    /// outside the Swift layer) and the engine: without it, a transaction
    /// created mid-session would only be pushed on the next boot or manual "Sync now".
    func notifyLocalChanges() {
        guard isEnabled else { return }
        if engine == nil { startEngine() }
        pushLocalChangesToEngine()
    }

    // MARK: - Engine

    private func startEngine() {
        let stateSerialization: CKSyncEngine.State.Serialization? = store.metaValue("ck_state")
            .flatMap { Data(base64Encoded: $0) }
            .flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }

        let configuration = CKSyncEngine.Configuration(
            database: CKContainer(identifier: Self.containerIdentifier).privateCloudDatabase,
            stateSerialization: stateSerialization,
            delegate: self
        )
        engine = CKSyncEngine(configuration)
        print("[CloudSyncEngine] Moteur démarré (state restauré : \(stateSerialization != nil))")
    }

    /// Transfers sync_pending + sync_tombstones into the CKSyncEngine state.
    /// The ENTIRE queue is pushed (no cap) — CKSyncEngine handles the
    /// network batching itself via nextRecordZoneChangeBatch. A cap here
    /// would make the initial scan (the whole database) stall at 400/sync.
    private func pushLocalChangesToEngine() {
        guard let engine else { return }
        let saves: [CKSyncEngine.PendingRecordZoneChange] = store.pendingRows(limit: .max).map {
            .saveRecord(Self.recordID(table: $0.table, uuid: $0.uuid))
        }
        let deletes: [CKSyncEngine.PendingRecordZoneChange] = store.tombstoneRows(limit: .max).map {
            .deleteRecord(Self.recordID(table: $0.table, uuid: $0.uuid))
        }
        if !saves.isEmpty || !deletes.isEmpty {
            engine.state.add(pendingRecordZoneChanges: saves + deletes)
        }
    }

    private func markSyncDone() {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        store.setMeta("last_sync_at", fmt.string(from: Date()))
    }

    private func recordError(_ message: String) {
        store.setMeta("last_sync_error", message)
        print("[CloudSyncEngine] Erreur : \(message)")
    }

    /// PERMANENT error: the server refuses the record and retrying won't
    /// change anything until an external action is taken (typically
    /// deploying the CloudKit schema to Production). Rows stay in
    /// sync_pending — they go out again on their own once that's done.
    private func recordBlockingError(_ message: String) {
        store.setMeta("last_sync_error", message)
        store.setMeta("last_sync_error_permanent", "1")
        print("[CloudSyncEngine] Erreur bloquante : \(message)")
    }

    /// Actionable message for a definitive server rejection. The known case
    /// is "Cannot create new type <table> in production schema": TestFlight/
    /// App Store builds hit the CloudKit Production environment, where JIT
    /// creation of record types is forbidden — the schema must be deployed
    /// from Development to Production via the CloudKit console. Apple's
    /// exact error text isn't contractual, so a generic fallback covers
    /// other rejections.
    private static func rejectionMessage(for error: CKError, table: String) -> String {
        let raw = String(describing: error).lowercased()
        if raw.contains("production schema") || raw.contains("cannot create new type") {
            return "Le schéma CloudKit n'est pas déployé en production. Vos données restent en attente sur cet appareil — rien n'est perdu. Action requise : déployer le schéma dans la console CloudKit (icloud.developer.apple.com)."
        }
        return "Envoi refusé par iCloud (\(table)) : \(error.localizedDescription). Les données restent en attente sur cet appareil."
    }

    // MARK: - Record ↔ row identity

    /// recordName = "<table>_<uuid 32 hex>". The uuid is exactly 32 chars,
    /// so parsing by suffix is unambiguous even when the table name itself
    /// contains underscores.
    static func recordID(table: String, uuid: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(table)_\(uuid)", zoneID: zoneID)
    }

    static func parseRecordName(_ name: String) -> (table: String, uuid: String)? {
        guard name.count > 33 else { return nil }
        let uuid = String(name.suffix(32))
        let table = String(name.dropLast(33))
        guard SyncPayloadStore.tableOrder.contains(table) else { return nil }
        return (table, uuid)
    }

    // MARK: - Building CKRecords

    private nonisolated func makeRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard let (table, uuid) = Self.parseRecordName(recordID.recordName) else { return nil }
        guard let payload = store.payloadJSON(table: table, uuid: uuid) else {
            // Row removed from the queue since — nothing left to upload.
            return nil
        }

        let record: CKRecord
        if let archived = store.recordSystemFields(table: table, uuid: uuid),
           let restored = Self.decodeSystemFields(archived) {
            record = restored
        } else {
            record = CKRecord(recordType: table, recordID: recordID)
        }
        record.encryptedValues["p"] = payload
        return record
    }

    private static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        return CKRecord(coder: unarchiver)
    }

    private static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    // MARK: - Applying remote changes

    /// Applies a fetched batch. The suppress_triggers flag spans the entire
    /// batch: writes coming from the server must NOT go back out for upload
    /// (echo loop). Known gap: a concurrent app write during batch
    /// application wouldn't be tracked — a short window, and the next
    /// reactivation scan would catch up on it.
    private func applyFetchedChanges(modifications: [CKRecord], deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)]) {
        // Referenced tables first (accounts → … → transactions), then the
        // WHOLE batch runs in ONE SQLite transaction (the per-record version
        // opened ~1 connection/row and starved UI reads).
        let order = SyncPayloadStore.tableOrder
        let mods: [SyncPayloadStore.RemoteModification] = modifications
            .sorted { a, b in
                let ia = order.firstIndex(of: a.recordType) ?? order.count
                let ib = order.firstIndex(of: b.recordType) ?? order.count
                return ia < ib
            }
            .compactMap { record in
                guard let (table, uuid) = Self.parseRecordName(record.recordID.recordName),
                      let payload = record.encryptedValues["p"] as? Data else { return nil }
                return SyncPayloadStore.RemoteModification(
                    table: table, uuid: uuid, payloadData: payload,
                    systemFields: Self.encodeSystemFields(record)
                )
            }
        let dels: [SyncPayloadStore.RemoteDeletion] = deletions.compactMap { deletion in
            guard let (table, uuid) = Self.parseRecordName(deletion.recordID.recordName) else { return nil }
            return SyncPayloadStore.RemoteDeletion(table: table, uuid: uuid)
        }

        store.applyRemoteBatch(modifications: mods, deletions: dels)

        // An identity adoption during this batch may have created tombstones
        // (old uuid → server duplicate to remove): push them to the engine
        // right away instead of waiting for the next manual cycle.
        pushLocalChangesToEngine()

        // Wakes the UI: data changed underneath it (silent push or fetch
        // while the app is in the foreground).
        if !modifications.isEmpty || !deletions.isEmpty {
            NotificationCenter.default.post(name: .nemorisSyncDidApplyRemoteChanges, object: nil)
        }
    }
}

// MARK: - CKSyncEngineDelegate

extension CloudSyncEngine: CKSyncEngineDelegate {

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {

        case .stateUpdate(let stateUpdate):
            if let data = try? JSONEncoder().encode(stateUpdate.stateSerialization) {
                store.setMeta("ck_state", data.base64EncodedString())
            }

        case .accountChange(let accountChange):
            switch accountChange.changeType {
            case .signIn:
                // New account available: full re-scan to populate the vault.
                store.enqueueAllRows()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                pushLocalChangesToEngine()
            case .signOut, .switchAccounts:
                // Account gone/changed: cut the connection. LOCAL data stays intact.
                disable()
                recordError("Compte iCloud déconnecté — synchronisation désactivée.")
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == Self.zoneID {
                // Zone deleted server-side (user reset, or another device).
                disable()
                recordError("Le coffre iCloud a été supprimé — synchronisation désactivée.")
            }

        case .fetchedRecordZoneChanges(let changes):
            applyFetchedChanges(
                modifications: changes.modifications.map(\.record),
                deletions: changes.deletions.map { ($0.recordID, $0.recordType) }
            )

        case .sentRecordZoneChanges(let sent):
            // Self-healing: a fully accepted batch clears the "blocked"
            // state (e.g. the schema was just deployed to Production — the
            // first successful send turns the status green again with no
            // manual action).
            if sent.failedRecordSaves.isEmpty, sent.failedRecordDeletes.isEmpty,
               !sent.savedRecords.isEmpty || !sent.deletedRecordIDs.isEmpty {
                store.deleteMeta("last_sync_error")
                store.deleteMeta("last_sync_error_permanent")
            }
            for record in sent.savedRecords {
                guard let (table, uuid) = Self.parseRecordName(record.recordID.recordName) else { continue }
                store.setRecordSystemFields(table: table, uuid: uuid, data: Self.encodeSystemFields(record))
                let queuedAt = inFlightQueuedAt.removeValue(forKey: record.recordID.recordName) ?? "9999"
                store.clearPending(table: table, uuid: uuid, queuedAtNotAfter: queuedAt)
            }
            for recordID in sent.deletedRecordIDs {
                guard let (table, uuid) = Self.parseRecordName(recordID.recordName) else { continue }
                store.clearTombstone(table: table, uuid: uuid)
                store.deleteRecordSystemFields(table: table, uuid: uuid)
            }
            for failure in sent.failedRecordSaves {
                handleFailedSave(record: failure.record, error: failure.error, syncEngine: syncEngine)
            }
            for (recordID, error) in sent.failedRecordDeletes {
                guard let (table, uuid) = Self.parseRecordName(recordID.recordName) else { continue }
                switch error.code {
                case .unknownItem, .zoneNotFound:
                    // Record no longer exists server-side — job done, clear
                    // the tombstone (otherwise an infinite retry; a frequent
                    // case post-adoption, where the old uuid was sometimes
                    // never uploaded in the first place).
                    store.clearTombstone(table: table, uuid: uuid)
                    store.deleteRecordSystemFields(table: table, uuid: uuid)
                case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                    // Transient: retry on the next cycle.
                    syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(Self.recordID(table: table, uuid: uuid))])
                case .invalidArguments, .serverRejectedRequest:
                    // Definitive rejection (e.g. schema not deployed to
                    // Production): the tombstone must SURVIVE — the deletion
                    // will go out again after the external action. Don't clear it.
                    cycleHadSaveFailures = true
                    recordBlockingError(Self.rejectionMessage(for: error, table: table))
                default:
                    // Unexpected error: clear it to avoid looping, log it instead.
                    recordError("Suppression échouée (\(table)) : \(error.localizedDescription)")
                    store.clearTombstone(table: table, uuid: uuid)
                }
            }

        case .sentDatabaseChanges, .willFetchChanges, .willFetchRecordZoneChanges,
             .didFetchRecordZoneChanges, .didFetchChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let scope = context.options.scope
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        guard !changes.isEmpty else { return nil }

        // Captures the current queued_at of each row being sent (see inFlightQueuedAt).
        let queuedByRecordName = Dictionary(
            store.pendingRows(limit: 10_000).map { ("\($0.table)_\($0.uuid)", $0.queuedAt) },
            uniquingKeysWith: { a, _ in a }
        )

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { recordID in
            if let record = self.makeRecord(for: recordID) {
                if let queuedAt = queuedByRecordName[recordID.recordName] {
                    await self.markInFlight(recordName: recordID.recordName, queuedAt: queuedAt)
                }
                return record
            }
            // Row gone from the queue: nothing to send.
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
    }

    private func markInFlight(recordName: String, queuedAt: String) {
        inFlightQueuedAt[recordName] = queuedAt
    }

    /// Upload conflict: the server has a version newer than our system
    /// fields. Resolved with LWW on the payload's `updated_at`.
    private func handleFailedSave(record: CKRecord, error: CKError, syncEngine: CKSyncEngine) {
        guard let (table, uuid) = Self.parseRecordName(record.recordID.recordName) else { return }

        switch error.code {
        case .serverRecordChanged:
            guard let serverRecord = error.serverRecord else { return }
            // ALWAYS keep the server's system fields (basis for the next
            // upload), then LWW on the content.
            store.setRecordSystemFields(table: table, uuid: uuid, data: Self.encodeSystemFields(serverRecord))
            if let payload = serverRecord.encryptedValues["p"] as? Data {
                store.setMeta("suppress_triggers", "1")
                let result = store.applyRemoteRecord(table: table, payloadData: payload)
                store.setMeta("suppress_triggers", "0")
                switch result {
                case .applied:
                    // Server is newer: our version is overwritten, nothing
                    // left to send for this row.
                    store.clearPending(table: table, uuid: uuid, queuedAtNotAfter: "9999")
                case .skippedLocalNewer, .failed:
                    // Local wins: re-upload over the server version.
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                }
            }

        case .zoneNotFound:
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])

        case .unknownItem:
            // Record deleted server-side: start over with a fresh record.
            store.deleteRecordSystemFields(table: table, uuid: uuid)
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])

        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            // Transient: CKSyncEngine reschedules on its own, the row stays
            // in sync_pending.
            break

        case .invalidArguments, .serverRejectedRequest:
            // DEFINITIVE server-side rejection — e.g. record type missing
            // from the Production schema ("Cannot create new type … in
            // production schema"). The row STAYS in sync_pending: it goes
            // out again on its own once the schema is deployed (the
            // self-healing in sentRecordZoneChanges then turns the status
            // green again).
            cycleHadSaveFailures = true
            recordBlockingError(Self.rejectionMessage(for: error, table: table))

        case .batchRequestFailed:
            // Collateral damage of an atomic batch: the root error is
            // carried by ANOTHER record in the same batch (handled by the
            // case above). Silent here so it doesn't overwrite the real message.
            cycleHadSaveFailures = true

        default:
            cycleHadSaveFailures = true
            recordError("Envoi échoué (\(table)) : \(error.localizedDescription)")
        }
    }
}
