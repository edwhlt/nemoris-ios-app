import Foundation
import os

// MARK: - BackupService
//
// Service de sauvegarde locale + iCloud de la base SQLite. Stratégie : snapshots
// fichiers (.sqlite) copiés à un instant T — PAS de live-sync de la DB courante.
// La live-sync iCloud d'une base SQLite avec WAL est risquée (corruption,
// conflits multi-device), donc on en reste à des points de restauration discrets.
//
// **Emplacements** :
//   • Local  : Documents/Backups/nemoris-backup-YYYY-MM-DD-HHmmss.sqlite
//   • iCloud : <UbiquityContainer>/Documents/Backups/<même nom>
//
// Local est toujours dispo (cas iCloud absent / désactivé / hors-ligne).
// iCloud est best-effort : si le container est nil ou inaccessible, on continue
// en local uniquement avec un message d'erreur clair propagé via `lastSyncError`.
//
// **Rotation** : on conserve `maxSnapshots` snapshots (30 par défaut). Au-delà,
// le plus ancien est supprimé. Pruning identique côté local + iCloud.
//
// **Auto-backup** : `runAutoBackupIfDue()` à appeler au launch — crée un snapshot
// seulement si > 24h depuis le dernier. Pilotable via toggle UserDefaults.
//
// **Restore** : `restore(snapshot:)` fait une sauvegarde de sécurité de la DB
// actuelle (suffixée `-pre-restore`) avant de l'écraser. L'appelant doit ensuite
// invalider tous les VMs via `AppState.dataRefreshToken = UUID()`.

@MainActor
final class BackupService {

    static let shared = BackupService()

    /// Nombre max de snapshots conservés (local + iCloud séparément). 30 = un mois
    /// de backup quotidien — suffisant pour récupérer d'une corruption récente.
    var maxSnapshots: Int = 30

    /// Container iCloud par défaut — `nil` quand l'user n'a pas iCloud configuré
    /// ou que l'entitlement n'a pas été activé côté Xcode. Recalculé à chaque accès
    /// pour suivre les changements d'état (login/logout iCloud).
    private var iCloudContainerURL: URL? {
        // Container par défaut associé au bundle ID. Renvoie nil si :
        //   - L'user n'est pas connecté à iCloud
        //   - L'entitlement iCloud Documents n'est pas activé
        //   - L'app vient juste de lancer (le container met parfois quelques
        //     secondes à devenir disponible — d'où l'absence de cache)
        FileManager.default.url(forUbiquityContainerIdentifier: nil)
    }

    // MARK: - User-facing config (persistée UserDefaults)

    /// Auto-backup activé. Par défaut : true (sauf si l'user désactive).
    var autoBackupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "backupAutoEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "backupAutoEnabled") }
    }

    /// Date du dernier snapshot créé (local ou iCloud, peu importe).
    /// `nil` au premier launch.
    var lastBackupDate: Date? {
        get { UserDefaults.standard.object(forKey: "backupLastDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "backupLastDate") }
    }

    /// Dernière erreur rencontrée lors d'une opération iCloud. Affichée dans
    /// Settings pour informer l'user sans bloquer l'opération locale.
    var lastSyncError: String? {
        get { UserDefaults.standard.string(forKey: "backupLastSyncError") }
        set { UserDefaults.standard.set(newValue, forKey: "backupLastSyncError") }
    }

    /// `true` si iCloud est actuellement disponible (container accessible).
    /// Calculé à la volée — peut changer entre 2 appels (réseau, login).
    var isICloudAvailable: Bool { iCloudContainerURL != nil }

    // MARK: - Snapshot model

    /// Un snapshot disponible pour restauration. Provient soit du dossier local,
    /// soit du container iCloud (les 2 sources sont mélangées dans la liste UI,
    /// dédupliquées par nom de fichier — un même nom dans les 2 endroits = même
    /// backup propagé par iCloud).
    struct Snapshot: Identifiable, Hashable {
        let id: String       // = filename (unique car timestamp inclus)
        let url: URL
        let createdAt: Date
        let sizeBytes: Int64
        let isICloud: Bool
        /// `true` pour une sauvegarde de sécurité auto-créée juste avant une
        /// restauration (préfixe `nemoris-pre-restore-`) — pas déclenchée par
        /// l'user, mais restaurable/supprimable comme n'importe quel snapshot.
        let isPreRestore: Bool

        var displayName: String {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "fr_FR")
            fmt.dateStyle = .medium
            fmt.timeStyle = .short
            return fmt.string(from: createdAt)
        }

        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
    }

    // MARK: - Public API

    /// Crée un snapshot local + (tentative) iCloud. Retourne la liste des emplacements
    /// où l'écriture a réussi. Throw uniquement si l'écriture locale échoue (cas critique).
    @discardableResult
    func createSnapshot() throws -> [URL] {
        let dbURL = DatabaseManager.shared.sqliteURL()
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            throw BackupError.noDatabase
        }

        // Nom timestampé — yyyy-MM-dd-HHmmss en POSIX pour un tri lexicographique
        // qui suit l'ordre chronologique.
        let filename = "nemoris-backup-\(Self.filenameTimestampFormatter.string(from: Date())).sqlite"

        var createdURLs: [URL] = []

        // 1) Snapshot local — obligatoire. Si on n'arrive pas à écrire ici, on throw.
        let localDir = try ensureLocalBackupDir()
        let localDest = localDir.appendingPathComponent(filename)
        try copyDatabase(from: dbURL, to: localDest)
        createdURLs.append(localDest)

        // 2) Snapshot iCloud — best-effort. Si échec, on garde le local mais on
        //    note l'erreur pour l'afficher dans Settings.
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
            // iCloud indisponible — pas une erreur fatale, juste un état à signaler.
            lastSyncError = "iCloud indisponible (pas connecté ou entitlement manquant)"
        }

        // Pruning : on garde les N plus récents, tout le reste dégage.
        pruneOldSnapshots()

        lastBackupDate = Date()
        Self.log.info("Snapshot créé (\(createdURLs.count) emplacements)")
        return createdURLs
    }

    /// Liste tous les snapshots disponibles (local + iCloud), dédupliqués par
    /// filename, triés du plus récent au plus ancien.
    func listSnapshots() -> [Snapshot] {
        var byFilename: [String: Snapshot] = [:]

        // Snapshots locaux
        if let localDir = try? ensureLocalBackupDir() {
            for snap in snapshotsIn(directory: localDir, isICloud: false) {
                byFilename[snap.id] = snap
            }
        }

        // Snapshots iCloud — peuvent écraser les locaux du même nom (ils représentent
        // le même contenu propagé). On préfère l'URL iCloud car elle survit au reset
        // de l'app sur ce device.
        if let cloudDir = try? ensureICloudBackupDir() {
            for snap in snapshotsIn(directory: cloudDir, isICloud: true) {
                byFilename[snap.id] = snap
            }
        }

        return byFilename.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Restaure le snapshot donné. Crée d'abord une sauvegarde de sécurité de la
    /// DB courante (suffixe `-pre-restore-<timestamp>`) — l'user peut toujours
    /// revenir en arrière si la restauration le laisse dans un état non-désiré.
    /// L'appelant doit ensuite invalider tous les VMs (cf. AppState.dataRefreshToken).
    func restore(snapshot: Snapshot) throws {
        let dbURL = DatabaseManager.shared.sqliteURL()

        // 1) Sauvegarde de sécurité de la DB courante AVANT toute opération.
        if FileManager.default.fileExists(atPath: dbURL.path) {
            let safetyDir = try ensureLocalBackupDir()
            let safetyName = "nemoris-pre-restore-\(Self.filenameTimestampFormatter.string(from: Date())).sqlite"
            let safetyURL = safetyDir.appendingPathComponent(safetyName)
            try copyDatabase(from: dbURL, to: safetyURL)
            Self.log.info("Sauvegarde de sécurité créée : \(safetyName)")
        }

        // 2) Pour iCloud : forcer le téléchargement du fichier si pas encore présent
        //    en local (sinon copyItem va échouer).
        if snapshot.isICloud, !FileManager.default.fileExists(atPath: snapshot.url.path) {
            try FileManager.default.startDownloadingUbiquitousItem(at: snapshot.url)
            // On attend que le téléchargement aboutisse (timeout 30s). Pour MVP
            // on bloque le main thread quelques secondes — acceptable car l'user
            // a explicitement tapé "Restaurer" et voit un spinner.
            try waitForFile(at: snapshot.url, timeout: 30)
        }

        // 3) Remplace la DB courante par le snapshot.
        try? FileManager.default.removeItem(at: dbURL)
        try FileManager.default.copyItem(at: snapshot.url, to: dbURL)

        // 4) Réapplique les migrations (cas snapshot fait avec version antérieure).
        //    Les migrations sont idempotentes par design.
        DatabaseManager.shared.migrateIfNeeded()

        Self.log.info("Restauration OK depuis \(snapshot.id)")
    }

    /// Supprime un snapshot (local ou iCloud).
    func deleteSnapshot(_ snapshot: Snapshot) throws {
        try FileManager.default.removeItem(at: snapshot.url)
    }

    /// Crée un snapshot uniquement si > 24h depuis le dernier ET auto-backup activé.
    /// Appelé au launch — silencieux, ne throw jamais (logué uniquement).
    func runAutoBackupIfDue() {
        guard autoBackupEnabled else { return }
        // Garde-fou base vide : ne jamais snapshoter une base sans transaction
        // (base fraîchement créée / en cours d'onboarding / rejoint iCloud pas
        // encore descendu). Sinon ce backup quasi-vide occupe un slot des 30 et
        // finit par pousser un vrai snapshot hors rotation. Dès la 1re
        // transaction (import, saisie, ou descente CloudKit), les backups
        // reprennent normalement.
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
        // Le sous-dossier `Documents` est obligatoire dans un container iCloud
        // pour être visible côté Files app de l'user.
        let documentsURL = container.appendingPathComponent("Documents", isDirectory: true)
        let backupDir = documentsURL.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        return backupDir
    }

    /// Copie SQLite : avant la copie on s'assure qu'aucun WAL/SHM n'est en cours
    /// d'écriture en faisant un checkpoint. Pour MVP on copie directement (l'app
    /// utilise des connexions à la demande, pas de connexion persistante).
    /// Si on rencontre des corruptions, on ajoutera un VACUUM INTO ici.
    private func copyDatabase(from src: URL, to dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
    }

    /// Format des noms de fichiers (`nemoris-backup-yyyy-MM-dd-HHmmss.sqlite`,
    /// `nemoris-pre-restore-yyyy-MM-dd-HHmmss.sqlite`) — partagé par la génération
    /// du nom ET le parsing pour l'affichage (cf. `dateFromFilename`).
    private static let filenameTimestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        return fmt
    }()

    /// Date réelle du snapshot, extraite du nom de fichier plutôt que de
    /// l'attribut `.creationDate` : `FileManager.copyItem` préserve le birthtime
    /// du fichier SOURCE (la base live, quasi jamais recréée en usage normal —
    /// écritures SQLite en place) au lieu de dater la copie. Sans ce fix, tous
    /// les snapshots héritent de la même date figée, ce qui fausse l'affichage,
    /// le tri chronologique ET la rotation des `maxSnapshots` plus récents.
    private static func dateFromFilename(_ filename: String) -> Date? {
        let name = (filename as NSString).deletingPathExtension
        guard name.count >= 17 else { return nil }
        return filenameTimestampFormatter.date(from: String(name.suffix(17)))
    }

    /// Énumère les fichiers `.sqlite` dans un dossier et les transforme en Snapshots.
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
            // iCloud fichiers pas encore téléchargés : `.fileSize` peut être 0 ou nil
            // mais la métadata système contient la vraie taille. On accepte 0 si rien
            // d'autre — l'user voit "0 octets" et comprend que c'est en attente.
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

    /// Supprime les snapshots au-delà de `maxSnapshots` (le plus ancien d'abord).
    /// Appliqué local + iCloud séparément.
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

    /// Attend que le fichier iCloud soit téléchargé localement (bloquant, timeout).
    /// Polling toutes les 0.3s — simple et suffisant pour des fichiers <50 MB.
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

    var errorDescription: String? {
        switch self {
        case .noDatabase:        return "Aucune base de données à sauvegarder."
        case .iCloudUnavailable: return "iCloud indisponible. La sauvegarde reste locale."
        case .downloadTimeout:   return "Téléchargement iCloud trop long. Réessayez avec une meilleure connexion."
        case .writeFailed(let m): return "Écriture impossible : \(m)"
        }
    }
}
