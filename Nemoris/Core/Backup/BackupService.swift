import Foundation
import os

// MARK: - BackupService
//
// Local + iCloud backup service for the SQLite database. Strategy: file
// snapshots (.sqlite) copied at a point in time — NOT a live sync of the
// current DB. Live-syncing a WAL-mode SQLite database over iCloud is risky
// (corruption, multi-device conflicts), so this sticks to discrete restore points.
//
// **Locations**:
//   • Local  : Documents/Backups/nemoris-backup-YYYY-MM-DD-HHmmss.sqlite
//   • iCloud : <UbiquityContainer>/Documents/Backups/<same name>
//
// Local is always available (covers iCloud absent / disabled / offline).
// iCloud is best-effort: if the container is nil or inaccessible, the local
// copy still proceeds, with a clear error message surfaced via `lastSyncError`.
//
// **Rotation**: `maxSnapshots` snapshots are kept (30 by default). Beyond
// that, the oldest is deleted. Pruning is identical on the local and iCloud sides.
//
// **Auto-backup**: `runAutoBackupIfDue()` is called at launch — creates a
// snapshot only if > 24h since the last one. Controlled via a UserDefaults toggle.
//
// **Restore**: `restore(snapshot:)` makes a safety backup of the current DB
// (suffixed `-pre-restore`) before overwriting it. The caller must then
// invalidate all VMs via `AppState.dataRefreshToken = UUID()`.

@MainActor
final class BackupService {

    static let shared = BackupService()

    /// Max number of snapshots kept (local + iCloud counted separately). 30 =
    /// a month of daily backups — enough to recover from a recent corruption.
    var maxSnapshots: Int = 30

    /// Default iCloud container — `nil` when the user hasn't configured
    /// iCloud, or the entitlement hasn't been enabled in Xcode. Recomputed
    /// on every access to track state changes (iCloud login/logout).
    private var iCloudContainerURL: URL? {
        // Default container associated with the bundle ID. Returns nil if:
        //   - the user isn't signed into iCloud
        //   - the iCloud Documents entitlement isn't enabled
        //   - the app just launched (the container can take a few seconds
        //     to become available — hence no caching here)
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    // MARK: - User-facing config (persisted in UserDefaults)

    /// Whether auto-backup is enabled. Defaults to true (unless the user disables it).
    var autoBackupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "backupAutoEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "backupAutoEnabled") }
    }

    /// Date of the last snapshot created (local or iCloud, either counts).
    /// `nil` on first launch.
    var lastBackupDate: Date? {
        get { UserDefaults.standard.object(forKey: "backupLastDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "backupLastDate") }
    }

    /// Last error encountered during an iCloud operation. Shown in Settings
    /// to inform the user without blocking the local operation.
    var lastSyncError: String? {
        get { UserDefaults.standard.string(forKey: "backupLastSyncError") }
        set { UserDefaults.standard.set(newValue, forKey: "backupLastSyncError") }
    }

    /// `true` if iCloud is currently available (container accessible).
    /// Computed on the fly — can change between 2 calls (network, login state).
    var isICloudAvailable: Bool { iCloudContainerURL != nil }

    // MARK: - Snapshot model

    /// A snapshot available for restoration. Comes from either the local
    /// folder or the iCloud container (the 2 sources are merged in the UI
    /// list, deduplicated by filename — the same name in both places means
    /// the same backup, propagated by iCloud).
    struct Snapshot: Identifiable, Hashable {
        let id: String       // = filename (unique since it includes the timestamp)
        let url: URL
        let createdAt: Date
        let sizeBytes: Int64
        let isICloud: Bool
        /// `true` for a safety backup auto-created right before a restore
        /// (prefix `nemoris-pre-restore-`) — not triggered by the user, but
        /// restorable/deletable like any other snapshot.
        let isPreRestore: Bool

        var displayName: String {
            let fmt = DateFormatter()
            fmt.locale = AppLocalization.locale
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return fmt.string(from: createdAt)
        }

        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    // MARK: - Public API

    /// Creates a local snapshot + (attempted) iCloud snapshot. Returns the
    /// list of locations where the write succeeded. Only throws if the
    /// local write fails (a critical case).
    @discardableResult
    func createSnapshot() throws -> [URL] {
        let dbURL = DatabaseManager.shared.sqliteURL()
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw BackupError.noDatabase
        }

        // Timestamped name — yyyy-MM-dd-HHmmss in POSIX so lexicographic
        // sorting follows chronological order.
        let filename = "nemoris-backup-\(Self.filenameTimestampFormatter.string(from: Date())).sqlite"

        var createdURLs: [URL] = []

        // 1) Local snapshot — mandatory. Throws if this write fails.
        let localDir = try ensureLocalBackupDir()
        let localDest = localDir.appendingPathComponent(filename)
        try copyDatabase(from: dbURL, to: localDest)
        createdURLs.append(localDest)

        // 2) iCloud snapshot — best-effort. On failure, the local copy is
        //    kept and the error is recorded for display in Settings.
        if let cloudDir = try? ensureICloudBackupDir() {
            let cloudDest = cloudDir.appendingPathComponent(filename)
            do {
                try copyDatabase(from: dbURL, to: cloudDest)
                createdURLs.append(cloudDest)
                lastSyncError = nil
            } catch {
                lastSyncError = "Sauvegarde iCloud échouée : \(error.localizedDescription)"
            }
        } else {
            // iCloud unavailable — not a fatal error, just a state to report.
            lastSyncError = "iCloud indisponible (pas connecté ou entitlement manquant)"
        }

        // Pruning: keep the N most recent, everything else goes.
        pruneOldSnapshots()

        lastBackupDate = Date()
        Self.log.info("Snapshot créé (\(createdURLs.count) emplacements)")
        return createdURLs
    }

    /// Lists all available snapshots (local + iCloud), deduplicated by
    /// filename, sorted from most to least recent.
    func listSnapshots() -> [Snapshot] {
        var byFilename: [String: Snapshot] = [:]

        // Local snapshots
        if let localDir = try? ensureLocalBackupDir() {
            for snap in snapshotsIn(directory: localDir, isICloud: false) {
                byFilename[snap.id] = snap
            }
        }

        // iCloud snapshots — may overwrite locals of the same name (they
        // represent the same content, propagated). The iCloud URL is
        // preferred since it survives an app reset on this device.
        if let cloudDir = try? ensureICloudBackupDir() {
            for snap in snapshotsIn(directory: cloudDir, isICloud: true) {
                byFilename[snap.id] = snap
            }
        }

        return byFilename.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Restores the given snapshot. First creates a safety backup of the
    /// current DB (suffix `-pre-restore-<timestamp>`) — the user can always
    /// roll back if the restore leaves them in an unwanted state. The
    /// caller must then invalidate all VMs (see AppState.dataRefreshToken).
    func restore(snapshot: Snapshot) throws {
        let dbURL = DatabaseManager.shared.sqliteURL()

        // 1) For iCloud: force the file to download if it isn't present
        //    locally yet — needed for the schema check below AND the copy.
        if snapshot.isICloud, !FileManager.default.fileExists(atPath: snapshot.url.path) {
            try FileManager.default.startDownloadingUbiquitousItem(at: snapshot.url)
            // Waits for the download to complete (30s timeout). This blocks
            // the main thread for a few seconds — acceptable since the user
            // explicitly tapped "Restore" and sees a spinner.
            try waitForFile(at: snapshot.url, timeout: 30)
        }

        // 2) Schema-drift check — refuse a file whose TABLE STRUCTURE was
        //    altered outside the versioned migration chain (e.g. by hand via
        //    the SQL console: an ALTER/DROP/CREATE never wrapped in a real
        //    migration). Row DATA differences are irrelevant here and never
        //    block the restore — only structure is compared. Runs on a
        //    DISPOSABLE scratch copy: `detectSchemaDrift` migrates it in
        //    place, and the snapshot file itself must never be mutated.
        //    Checked BEFORE anything else touches the live database, so a
        //    refusal here leaves the app exactly as it was.
        let scratchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemoris-restore-check-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: scratchURL) }
        try FileManager.default.copyItem(at: snapshot.url, to: scratchURL)
        // Backups are written read-only (cf. `copyDatabase`) and `copyItem`
        // preserves that mode — this scratch copy needs to be writable for
        // `detectSchemaDrift` to migrate it.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratchURL.path)
        if case .drifted(let missing, let extra, let changed) = DatabaseManager.detectSchemaDrift(at: scratchURL) {
            Self.log.error("Restauration refusée (dérive de schéma) : manquantes=\(missing), en trop=\(extra), modifiées=\(changed)")
            throw BackupError.schemaDrifted(missingTables: missing, extraTables: extra, changedTables: changed)
        }

        // 3) Safety backup of the current DB BEFORE any other operation.
        if FileManager.default.fileExists(atPath: dbURL.path) {
            let safetyDir = try ensureLocalBackupDir()
            let safetyName = "nemoris-pre-restore-\(Self.filenameTimestampFormatter.string(from: Date())).sqlite"
            let safetyURL = safetyDir.appendingPathComponent(safetyName)
            try copyDatabase(from: dbURL, to: safetyURL)
            Self.log.info("Sauvegarde de sécurité créée : \(safetyName)")
        }

        // 4) Replaces the current DB with the snapshot.
        try? FileManager.default.removeItem(at: dbURL)
        try FileManager.default.copyItem(at: snapshot.url, to: dbURL)
        // Snapshots are read-only (cf. `copyDatabase`) and `copyItem`
        // preserves that mode — without restoring write access here, the
        // LIVE database would come out read-only and the app couldn't
        // record another transaction until manually fixed.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)

        // 5) Re-applies migrations (covers a snapshot made on an older
        //    version). Migrations are idempotent by design.
        DatabaseManager.shared.migrateIfNeeded()

        Self.log.info("Restauration OK depuis \(snapshot.id)")
    }

    /// Deletes a snapshot (local or iCloud).
    func deleteSnapshot(_ snapshot: Snapshot) throws {
        try FileManager.default.removeItem(at: snapshot.url)
    }

    /// Creates a snapshot only if > 24h since the last one AND auto-backup
    /// is enabled. Called at launch — silent, never throws (logs only).
    func runAutoBackupIfDue() {
        guard autoBackupEnabled else { return }
        // Empty-database guard: never snapshot a database with no
        // transactions (freshly created / mid-onboarding / joined iCloud
        // but not yet synced down). Otherwise this near-empty backup would
        // occupy one of the 30 rotation slots and eventually push out a
        // real snapshot. Backups resume normally from the 1st transaction
        // (import, manual entry, or CloudKit sync).
        guard DatabaseManager.shared.transactionCount() > 0 else {
            Self.log.info("Auto-backup sauté : base sans transaction.")
            return
        }
        if let last = lastBackupDate, Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        do {
            try createSnapshot()
        } catch {
            Self.log.error("Auto-backup échoué : \(error.localizedDescription)")
        }
    }

    // MARK: - Internals

    private func ensureLocalBackupDir() throws -> URL {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let backupDir = docs.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        return backupDir
    }

    private func ensureICloudBackupDir() throws -> URL {
        guard let container = iCloudContainerURL else {
            throw BackupError.iCloudUnavailable
        }
        // The `Documents` subfolder is required inside an iCloud container
        // for it to be visible in the user's Files app.
        let documentsURL = container.appendingPathComponent("Documents", isDirectory: true)
        let backupDir = documentsURL.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        return backupDir
    }

    /// SQLite copy: the database uses on-demand connections rather than a
    /// persistent one, so no explicit WAL checkpoint is needed before
    /// copying — a plain file copy is used directly.
    ///
    /// The destination is set READ-ONLY once written: a snapshot is a
    /// restore point, never something the app (or the user, via Finder)
    /// should be able to edit or truncate in place. Deleting it during
    /// pruning still works — removing a file only needs write access to its
    /// PARENT directory, not the file itself.
    private func copyDatabase(from src: URL, to dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: dest.path)
    }

    /// Filename format (`nemoris-backup-yyyy-MM-dd-HHmmss.sqlite`,
    /// `nemoris-pre-restore-yyyy-MM-dd-HHmmss.sqlite`) — shared by both name
    /// generation AND parsing for display (see `dateFromFilename`).
    private static let filenameTimestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return fmt
    }()

    /// Actual snapshot date, extracted from the filename rather than the
    /// `.creationDate` attribute: `FileManager.copyItem` preserves the
    /// SOURCE file's birthtime (the live database, almost never recreated
    /// in normal use since SQLite writes happen in place) instead of dating
    /// the copy. Relying on `.creationDate` would make every snapshot
    /// inherit the same frozen date, which would break the display, the
    /// chronological sort, AND the rotation of the `maxSnapshots` most recent ones.
    private static func dateFromFilename(_ filename: String) -> Date? {
        let name = (filename as NSString).deletingPathExtension
        guard name.count >= 17 else { return nil }
        return filenameTimestampFormatter.date(from: String(name.suffix(17)))
    }

    /// Enumerates `.sqlite` files in a folder and turns them into Snapshots.
    private func snapshotsIn(directory: URL, isICloud: Bool) -> [Snapshot] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isUbiquitousItemKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url -> Snapshot? in
            let name = url.lastPathComponent
            let isPreRestore = name.hasPrefix("nemoris-pre-restore-")
            guard url.pathExtension == "sqlite",
                  isPreRestore || name.hasPrefix("nemoris-backup-") else { return nil }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            // iCloud files not yet downloaded: `.fileSize` can be 0 or nil,
            // but the system metadata holds the real size. 0 is accepted as
            // a last resort — the user sees "0 bytes" and understands it's pending.
            let size = (attrs?[.size] as? Int64) ?? 0
            let date = Self.dateFromFilename(name) ?? (attrs?[.creationDate] as? Date) ?? Date()
            return Snapshot(
                id: name,
                url: url,
                createdAt: date,
                sizeBytes: size,
                isICloud: isICloud,
                isPreRestore: isPreRestore
            )
        }
    }

    /// Deletes snapshots beyond `maxSnapshots` (oldest first).
    /// Applied separately for local + iCloud.
    private func pruneOldSnapshots() {
        for dir in [try? ensureLocalBackupDir(), try? ensureICloudBackupDir()].compactMap({ $0 }) {
            let snaps = snapshotsIn(directory: dir, isICloud: false)
                .sorted { $0.createdAt > $1.createdAt }
            guard snaps.count > maxSnapshots else { continue }
            for snap in snaps.dropFirst(maxSnapshots) {
                try? FileManager.default.removeItem(at: snap.url)
            }
        }
    }

    /// Waits for the iCloud file to be downloaded locally (blocking, with a timeout).
    /// Polls every 0.3s — simple and sufficient for files <50 MB.
    private func waitForFile(at url: URL, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw BackupError.downloadTimeout
    }

    private static let log = Logger(subsystem: "fr.hedwin.nemoris", category: "Backup")
}

// MARK: - Errors

enum BackupError: LocalizedError {
    case noDatabase
    case iCloudUnavailable
    case downloadTimeout
    case writeFailed(String)
    /// The snapshot's table structure doesn't match what the app's
    /// migration chain alone would produce — refused rather than risk
    /// loading a file the app isn't guaranteed to work with.
    case schemaDrifted(missingTables: [String], extraTables: [String], changedTables: [String])

    var errorDescription: String? {
        switch self {
        case .noDatabase:        return "Aucune base de données à sauvegarder."
        case .iCloudUnavailable: return "iCloud indisponible. La sauvegarde reste locale."
        case .downloadTimeout:   return "Téléchargement iCloud trop long. Réessayez avec une meilleure connexion."
        case .writeFailed(let m): return "Écriture impossible : \(m)"
        case .schemaDrifted(let missing, let extra, let changed):
            var parts: [String] = []
            if !missing.isEmpty { parts.append("tables manquantes : \(missing.joined(separator: ", "))") }
            if !extra.isEmpty   { parts.append("tables en trop : \(extra.joined(separator: ", "))") }
            if !changed.isEmpty { parts.append("tables modifiées : \(changed.joined(separator: ", "))") }
            let detail = parts.joined(separator: " · ")
            return "Ce fichier a un schéma qui ne correspond pas à celui attendu par l'app (probablement modifié en dehors d'une migration versionnée) — restauration refusée par sécurité. \(detail)"
        }
    }
}
