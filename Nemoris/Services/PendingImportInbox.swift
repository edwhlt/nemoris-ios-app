import Foundation

/// Chantier D — boîte de réception des documents d'investissement déposés par un
/// App Intent / raccourci Siri (`ImportInvestmentDocumentIntent`).
///
/// Le raccourci n'importe RIEN silencieusement : il copie le fichier reçu dans le
/// conteneur partagé App Group (`PendingImports/<uuid>.<ext>`) et pose une clé
/// pointant dessus. L'app, à son prochain passage au premier plan, consomme la
/// clé, ouvre l'écran d'import intelligent pré-rempli et laisse l'utilisateur
/// relire puis valider (aucun commit automatique).
///
/// Le conteneur App Group est partagé entre l'app et l'extension d'intent (même
/// suite name que `WidgetDataStore.appGroupID`).
@MainActor
enum PendingImportInbox {

    static let appGroupID = "group.fr.hedwin.nemoris"
    /// Clé UserDefaults (suite App Group) → chemin du fichier en attente.
    static let pendingPathKey = "nemoris.pendingInvestmentImportPath"
    private static let folderName = "PendingImports"
    /// Durée de vie max d'un fichier en attente avant purge (fichier jamais consommé).
    private static let maxAge: TimeInterval = 24 * 3600

    /// Répertoire `PendingImports/` dans le conteneur App Group, créé si absent.
    private static func inboxDirectory() -> URL? {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        else {
            print("[PendingImportInbox] Conteneur App Group introuvable")
            return nil
        }
        let dir = container.appendingPathComponent(folderName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Dépose des données de document en attente. Appelée par l'App Intent.
    /// Retourne `true` si l'écriture + la pose de clé ont réussi.
    @discardableResult
    static func stash(data: Data, fileExtension: String) -> Bool {
        purgeStale()
        guard let dir = inboxDirectory() else { return false }
        let ext = fileExtension.isEmpty ? "dat" : fileExtension.lowercased()
        let fileURL = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[PendingImportInbox] Échec écriture : \(error.localizedDescription)")
            return false
        }
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return false }
        defaults.set(fileURL.path, forKey: pendingPathKey)
        print("[PendingImportInbox] Document en attente : \(fileURL.lastPathComponent)")
        return true
    }

    /// Consomme le document en attente (s'il existe et existe encore sur disque).
    /// Efface la clé (one-shot). Appelée par l'app au passage au premier plan.
    static func consumePendingInvestmentImport() -> URL? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let path = defaults.string(forKey: pendingPathKey)
        else { return nil }

        // Clé effacée dans tous les cas : one-shot, on ne re-propose pas un
        // fichier disparu au prochain foreground.
        defaults.removeObject(forKey: pendingPathKey)

        guard FileManager.default.fileExists(atPath: path) else {
            print("[PendingImportInbox] Fichier en attente introuvable : \(path)")
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Supprime les fichiers en attente plus vieux que `maxAge` (jamais consommés).
    static func purgeStale() {
        guard let dir = inboxDirectory() else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
