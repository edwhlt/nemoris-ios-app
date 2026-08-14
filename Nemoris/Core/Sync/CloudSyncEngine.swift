import Foundation
import CloudKit
import SQLite3
#if canImport(UIKit)
import UIKit
#endif

extension Notification.Name {
    /// Postée (main thread) après qu'un batch de changements DISTANTS a été
    /// appliqué à la base locale — l'UI doit recharger ses données.
    /// Observée dans NemorisApp → bump de AppState.dataRefreshToken.
    static let nemorisSyncDidApplyRemoteChanges = Notification.Name("nemorisSyncDidApplyRemoteChanges")
}

/// Couche L.1 : moteur de synchronisation CloudKit.
///
/// Wrapper `CKSyncEngine` (iOS 17+) autour de la base SQLite :
///   • zone privée unique `NemorisZone` dans le container iCloud de l'app
///   • 1 record CloudKit = 1 row SQLite, recordName = "<table>_<uuid>",
///     recordType = nom de la table
///   • payload = blob JSON dans `encryptedValues["p"]` → chiffrement E2E,
///     clés dans le trousseau iCloud de l'utilisateur, Apple ne peut pas lire
///   • conflits résolus en last-writer-wins via `updated_at` (payload "t")
///   • state CKSyncEngine sérialisé dans `sync_meta['ck_state']`
///
/// La détection des changements locaux vient des triggers v40 (SyncSchema) :
/// `sync_pending` + `sync_tombstones` sont poussés vers le moteur au boot,
/// à l'activation et à chaque "Synchroniser maintenant".
///
/// Opt-in strict : rien ne tourne tant que `sync_meta['sync_enabled'] != '1'`.
actor CloudSyncEngine {

    static let shared = CloudSyncEngine()

    /// Doit matcher l'entitlement com.apple.developer.icloud-container-identifiers.
    private static let containerIdentifier = "iCloud.fr.hedwin.nemoris"
    private static let zoneID = CKRecordZone.ID(zoneName: "NemorisZone", ownerName: CKCurrentUserDefaultName)

    private let store = SyncPayloadStore()
    private var engine: CKSyncEngine?

    /// queued_at capturé au moment où la row part dans un batch d'upload —
    /// permet de ne PAS purger de sync_pending une row rééditée pendant
    /// l'envoi (sa nouvelle version doit repartir).
    private var inFlightQueuedAt: [String: String] = [:]   // recordName → queued_at

    /// Vrai dès qu'un batch du cycle courant a produit au moins un échec
    /// d'envoi — empêche `markSyncDone()` d'afficher un « Dernier sync »
    /// à jour alors que des records ont été refusés par le serveur.
    private var cycleHadSaveFailures = false

    private init() {}

    // MARK: - API publique

    struct Status: Sendable {
        var enabled: Bool
        var accountAvailable: Bool
        var pendingCount: Int
        var lastSyncAt: String?
        var lastError: String?
        /// Erreur PERMANENTE côté serveur (ex : schéma CloudKit non déployé
        /// en Production) — le sync est actif mais rien ne part tant qu'une
        /// action externe n'a pas été faite. Rien n'est perdu (sync_pending).
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

    /// Appelé au launch (NemorisApp init). No-op si la sync n'est pas activée.
    func bootIfEnabled() async {
        guard isEnabled, engine == nil else { return }
        startEngine()
        pushLocalChangesToEngine()
        await registerForPushes()
    }

    /// Enregistre l'app auprès d'APNs pour les pushes silencieux CloudKit.
    /// CKSyncEngine gère lui-même sa subscription et le traitement des pushes
    /// entrants — notre seul travail est l'enregistrement système. Aucun
    /// prompt utilisateur : les notifications silencieuses ne demandent pas
    /// de permission (convention §6.7 respectée). Appelé uniquement quand la
    /// sync est active (opt-in strict).
    private func registerForPushes() async {
        #if canImport(UIKit)
        await MainActor.run {
            UIApplication.shared.registerForRemoteNotifications()
        }
        #endif
    }

    /// Activation opt-in depuis les Settings. Vérifie le compte iCloud,
    /// crée la zone, queue TOUTES les rows (scan initial) et lance un
    /// premier cycle envoi + réception.
    func enable() async throws {
        let account = try await CKContainer(identifier: Self.containerIdentifier).accountStatus()
        guard account == .available else { throw SyncError.iCloudUnavailable(account) }

        // Doctrine : snapshot de sécurité AVANT la première fusion — si la
        // descente initiale tourne mal (merge inattendu), l'utilisateur peut restaurer
        // l'état exact d'avant l'activation. Best-effort (échec non bloquant).
        _ = try? await MainActor.run { try BackupService.shared.createSnapshot() }

        store.setMeta("sync_enabled", "1")
        store.deleteMeta("last_sync_error")
        store.deleteMeta("last_sync_error_permanent")
        cycleHadSaveFailures = false
        startEngine()

        guard let engine else { return }
        engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
        // ⚠️ PAS de purge du seed ici : un PREMIER appareil (coffre vide) qui
        // active la sync perdrait ses catégories par défaut sans rien recevoir
        // en retour. La fusion des seeds entre appareils est garantie par
        // l'adoption déterministe par nom à l'application des records
        // (SyncPayloadStore.nameAdoptionTables — le plus petit uuid gagne).
        // Le flux "Rejoindre via iCloud" crée de toute façon une base SANS
        // seed (createNewDatabase(seedDefaults: false)).
        store.enqueueAllRows()
        pushLocalChangesToEngine()
        try await engine.sendChanges()
        try await engine.fetchChanges()
        if !cycleHadSaveFailures { markSyncDone() }
        await registerForPushes()
    }

    /// Désactivation : stoppe le moteur et purge l'état sync local.
    /// Les données métier et les records serveur restent intacts —
    /// une réactivation refait un scan initial + merge LWW.
    func disable() {
        engine = nil
        inFlightQueuedAt = [:]
        store.setMeta("sync_enabled", "0")
        store.clearAllSyncState()
    }

    /// Cycle manuel : pousse la queue locale, envoie, récupère.
    /// `markSyncDone()` seulement si aucun record n'a été refusé — les
    /// événements `sentRecordZoneChanges` (et donc `handleFailedSave`) sont
    /// délivrés avant le retour de `sendChanges()`, tout est actor-isolé.
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

    /// Auto-sync léger déclenché sur les transitions d'app (background /
    /// foreground). Transfère les écritures locales accumulées via triggers
    /// (sync_pending) vers le state CKSyncEngine, qui les enverra tout seul
    /// en arrière-plan selon son propre scheduling. No-op si sync désactivée.
    ///
    /// C'est le pont manquant entre l'écriture SQLite (captée par les triggers
    /// hors couche Swift) et le moteur : sans lui, une transaction créée en
    /// cours de session n'était poussée qu'au prochain boot ou "Sync Now".
    func notifyLocalChanges() {
        guard isEnabled else { return }
        if engine == nil { startEngine() }
        pushLocalChangesToEngine()
    }

    // MARK: - Moteur

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

    /// Transfère sync_pending + sync_tombstones vers le state CKSyncEngine.
    /// On pousse la TOTALITÉ de la queue (pas de cap) — CKSyncEngine gère
    /// lui-même le découpage en batchs réseau via nextRecordZoneChangeBatch.
    /// Un cap ici ferait stagner le scan initial (base entière) à 400/sync.
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

    /// Erreur PERMANENTE : le serveur refuse le record et retenter ne changera
    /// rien tant qu'une action externe (déploiement du schéma CloudKit en
    /// Production, typiquement) n'a pas été faite. Les rows restent en
    /// sync_pending — elles repartiront d'elles-mêmes une fois l'action faite.
    private func recordBlockingError(_ message: String) {
        store.setMeta("last_sync_error", message)
        store.setMeta("last_sync_error_permanent", "1")
        print("[CloudSyncEngine] Erreur bloquante : \(message)")
    }

    /// Message actionnable pour un refus serveur définitif. Le cas connu est
    /// « Cannot create new type <table> in production schema » : les builds
    /// TestFlight/App Store tapent l'environnement CloudKit Production, où la
    /// création JIT des record types est interdite — il faut déployer le
    /// schéma Development → Production dans la console CloudKit (checklist
    /// CLAUDE.md §AXE L). Le texte exact n'étant pas contractuel côté Apple,
    /// un fallback générique couvre les autres refus.
    private static func rejectionMessage(for error: CKError, table: String) -> String {
        let raw = String(describing: error).lowercased()
        if raw.contains("production schema") || raw.contains("cannot create new type") {
            return "Le schéma CloudKit n'est pas déployé en production. Vos données restent en attente sur cet appareil — rien n'est perdu. Action requise : déployer le schéma dans la console CloudKit (icloud.developer.apple.com)."
        }
        return "Envoi refusé par iCloud (\(table)) : \(error.localizedDescription). Les données restent en attente sur cet appareil."
    }

    // MARK: - Identité record ↔ row

    /// recordName = "<table>_<uuid 32 hex>". Le uuid faisant exactement
    /// 32 chars, le parsing par suffixe est non-ambigu même si le nom de
    /// table contient des underscores.
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

    // MARK: - Construction des CKRecords

    private nonisolated func makeRecord(for recordID: CKRecord.ID) -> CKRecord? {
        guard let (table, uuid) = Self.parseRecordName(recordID.recordName) else { return nil }
        guard let payload = store.payloadJSON(table: table, uuid: uuid) else {
            // Row supprimée depuis le queue → plus rien à uploader.
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

    // MARK: - Application des changements distants

    /// Applique un batch fetché. Le flag suppress_triggers englobe tout le
    /// batch : les écritures venues du serveur ne doivent PAS repartir en
    /// upload (boucle d'écho). Fenêtre connue : une écriture app concurrente
    /// pendant l'application du batch ne serait pas trackée — fenêtre courte,
    /// et le scan initial de réactivation rattraperait le cas échéant.
    private func applyFetchedChanges(modifications: [CKRecord], deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)]) {
        // Tables référencées d'abord (accounts → … → transactions), puis
        // TOUT le batch part dans UNE transaction SQLite (perf : la version
        // par-record ouvrait ~1 connexion/row et affamait les lectures UI).
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

        // Une adoption d'identité pendant ce batch a pu créer des tombstones
        // (ancien uuid → doublon serveur à supprimer) : on les transfère au
        // moteur tout de suite plutôt qu'au prochain cycle manuel.
        pushLocalChangesToEngine()

        // Réveille l'UI : des données ont changé sous ses pieds (push
        // silencieux ou fetch pendant que l'app est au premier plan).
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
                // Nouveau compte dispo : re-scan complet pour peupler le coffre.
                store.enqueueAllRows()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
                pushLocalChangesToEngine()
            case .signOut, .switchAccounts:
                // Compte parti/changé : on coupe. Les données LOCALES restent.
                disable()
                recordError("Compte iCloud déconnecté — synchronisation désactivée.")
            @unknown default:
                break
            }

        case .fetchedDatabaseChanges(let changes):
            for deletion in changes.deletions where deletion.zoneID == Self.zoneID {
                // Zone supprimée côté serveur (reset user ou autre appareil).
                disable()
                recordError("Le coffre iCloud a été supprimé — synchronisation désactivée.")
            }

        case .fetchedRecordZoneChanges(let changes):
            applyFetchedChanges(
                modifications: changes.modifications.map(\.record),
                deletions: changes.deletions.map { ($0.recordID, $0.recordType) }
            )

        case .sentRecordZoneChanges(let sent):
            // Auto-guérison : un batch entièrement accepté efface l'état
            // « bloqué » (ex : le schéma vient d'être déployé en Production —
            // le premier envoi qui passe remet le statut au vert sans action
            // manuelle).
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
                    // Le record n'existe pas/plus côté serveur — mission
                    // accomplie, on solde la tombstone (sinon retry infini,
                    // cas fréquent post-adoption : l'ancien uuid n'a parfois
                    // jamais été uploadé).
                    store.clearTombstone(table: table, uuid: uuid)
                    store.deleteRecordSystemFields(table: table, uuid: uuid)
                case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
                    // Transitoire : retry au prochain cycle.
                    syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(Self.recordID(table: table, uuid: uuid))])
                case .invalidArguments, .serverRejectedRequest:
                    // Refus définitif (ex : schéma non déployé en Production) :
                    // la tombstone doit SURVIVRE — la suppression repartira
                    // après l'action externe. Ne pas solder.
                    cycleHadSaveFailures = true
                    recordBlockingError(Self.rejectionMessage(for: error, table: table))
                default:
                    // Erreur inattendue : on solde pour ne pas boucler, en la loggant.
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

        // Capture le queued_at courant de chaque row envoyée (cf. inFlightQueuedAt).
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
            // Row disparue depuis le queue : rien à envoyer.
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
        }
    }

    private func markInFlight(recordName: String, queuedAt: String) {
        inFlightQueuedAt[recordName] = queuedAt
    }

    /// Conflit d'upload : le serveur a une version plus récente que nos
    /// system fields. Résolution LWW sur le `updated_at` du payload.
    private func handleFailedSave(record: CKRecord, error: CKError, syncEngine: CKSyncEngine) {
        guard let (table, uuid) = Self.parseRecordName(record.recordID.recordName) else { return }

        switch error.code {
        case .serverRecordChanged:
            guard let serverRecord = error.serverRecord else { return }
            // On retient TOUJOURS les system fields du serveur (base du
            // prochain upload), puis LWW sur le contenu.
            store.setRecordSystemFields(table: table, uuid: uuid, data: Self.encodeSystemFields(serverRecord))
            if let payload = serverRecord.encryptedValues["p"] as? Data {
                store.setMeta("suppress_triggers", "1")
                let result = store.applyRemoteRecord(table: table, payloadData: payload)
                store.setMeta("suppress_triggers", "0")
                switch result {
                case .applied:
                    // Serveur plus récent : notre version est écrasée, plus
                    // rien à envoyer pour cette row.
                    store.clearPending(table: table, uuid: uuid, queuedAtNotAfter: "9999")
                case .skippedLocalNewer, .failed:
                    // Local gagne : re-upload par-dessus la version serveur.
                    syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                }
            }

        case .zoneNotFound:
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: Self.zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])

        case .unknownItem:
            // Record supprimé côté serveur : on repart d'un record neuf.
            store.deleteRecordSystemFields(table: table, uuid: uuid)
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])

        case .networkFailure, .networkUnavailable, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            // Transitoire : CKSyncEngine re-schedule tout seul, la row reste
            // en sync_pending.
            break

        case .invalidArguments, .serverRejectedRequest:
            // Refus DÉFINITIF côté serveur — le cas vécu : record type absent
            // du schéma Production (« Cannot create new type … in production
            // schema »). La row RESTE en sync_pending : elle repartira toute
            // seule après le déploiement du schéma (l'auto-guérison de
            // sentRecordZoneChanges remettra alors le statut au vert).
            cycleHadSaveFailures = true
            recordBlockingError(Self.rejectionMessage(for: error, table: table))

        case .batchRequestFailed:
            // Victime collatérale d'un batch atomique : l'erreur racine est
            // portée par un AUTRE record du même batch (qui passera par le cas
            // ci-dessus). Silencieux pour ne pas écraser le vrai message.
            cycleHadSaveFailures = true

        default:
            cycleHadSaveFailures = true
            recordError("Envoi échoué (\(table)) : \(error.localizedDescription)")
        }
    }
}
