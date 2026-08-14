import Foundation

/// boîte de réception des documents déposés par un App
/// Intent / raccourci Siri (`ImportInvestmentDocumentIntent`, `ImportFileIntent`)
/// ou par les share extensions (`NemorisShareInvest`, `NemorisShareTransactions`).
///
/// Le déposant n'importe RIEN silencieusement : il copie le fichier reçu dans le
/// conteneur partagé App Group (`PendingImports/<uuid>.<ext>`) et pose une clé
/// pointant dessus (une clé PAR type d'import). L'app, à son prochain passage au
/// premier plan, consomme la clé, ouvre l'écran d'import pré-rempli et laisse
/// l'utilisateur relire puis valider (aucun commit automatique).
///
/// Le conteneur App Group est partagé entre l'app, l'extension d'intent et les
/// share extensions (même suite name que `WidgetDataStore.appGroupID`).
/// ⚠️ Les share extensions embarquent un MIROIR de la logique d'écriture
/// (`ShareInboxWriter` dans NemorisShareTransactions/ et NemorisShareInvest/,
/// même convention que les modèles mirrorés du widget) — garder les clés,
/// le nom de dossier et le format de fichier synchronisés.
@MainActor
enum PendingImportInbox {

    /// Type d'import en attente. Chaque kind a sa propre clé → un dépôt
    /// investissement n'écrase jamais un dépôt transactions (et inversement).
    enum Kind {
        /// Relevé/capture de portefeuille → `InvestmentPDFImportView` pré-rempli.
        case investment
        /// Relevé bancaire CSV → `ImportEntryView` pré-rempli.
        case transactions

        var pendingPathKey: String {
            switch self {
            case .investment:   return "nemoris.pendingInvestmentImportPath"
            case .transactions: return "nemoris.pendingTransactionImportPath"
            }
        }
    }

    static let appGroupID = "group.fr.hedwin.nemoris"
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

    /// Dépose UN document en attente.
    @discardableResult
    static func stash(data: Data, fileExtension: String, kind: Kind) -> Bool {
        stash(files: [(data: data, fileExtension: fileExtension)], kind: kind)
    }

    /// Dépose N documents en attente. Appelée par les App Intents et les share
    /// extensions (via leur miroir `ShareInboxWriter`).
    ///
    /// Sémantique d'AJOUT : les chemins déjà en attente sont conservés. Deux
    /// partages successifs avant le retour dans l'app s'accumulent au lieu que
    /// le second efface le premier — le fichier écrasé restait sur disque sans
    /// que rien ne pointe plus dessus.
    @discardableResult
    static func stash(files: [(data: Data, fileExtension: String)], kind: Kind) -> Bool {
        guard !files.isEmpty else { return false }
        purgeStale()
        guard let dir = inboxDirectory(),
              let defaults = UserDefaults(suiteName: appGroupID) else { return false }

        var paths = storedPaths(defaults: defaults, kind: kind)
        for file in files {
            // Les octets font foi (même règle que les share extensions) : un
            // `IntentFile` fourni par Raccourcis porte souvent un type abstrait
            // sans extension exploitable, et un fichier `.dat` était ensuite
            // traité comme du texte brut par l'import — le binaire passait pour
            // un relevé.
            let declared = file.fileExtension.lowercased()
            let ext = InvestmentPDFParser.sniffFileExtension(data: file.data)
                ?? (declared.isEmpty || declared == "dat" ? "txt" : declared)
            let fileURL = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
            do {
                try file.data.write(to: fileURL, options: .atomic)
                paths.append(fileURL.path)
            } catch {
                print("[PendingImportInbox] Échec écriture : \(error.localizedDescription)")
            }
        }
        guard !paths.isEmpty else { return false }
        write(paths: paths, defaults: defaults, kind: kind)
        print("[PendingImportInbox] \(paths.count) document(s) en attente (\(kind))")
        return true
    }

    /// Consomme les documents d'investissement en attente. Appelée par l'app au
    /// passage au premier plan.
    static func consumePendingInvestmentImports() -> [URL] {
        consume(kind: .investment)
    }

    /// Consomme les relevés de transactions en attente.
    static func consumePendingTransactionImports() -> [URL] {
        consume(kind: .transactions)
    }

    /// Consomme les documents en attente du kind donné (ceux qui existent
    /// encore sur disque). Efface la clé (one-shot).
    private static func consume(kind: Kind) -> [URL] {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return [] }
        let paths = storedPaths(defaults: defaults, kind: kind)
        guard !paths.isEmpty else { return [] }

        // Clé effacée dans tous les cas : one-shot, on ne re-propose pas un
        // fichier disparu au prochain foreground.
        defaults.removeObject(forKey: kind.pendingPathKey)

        return paths.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else {
                print("[PendingImportInbox] Fichier en attente introuvable : \(path)")
                return nil
            }
            return URL(fileURLWithPath: path)
        }
    }

    /// Lecture tolérante de la clé : tableau JSON de chemins (format courant),
    /// ou chemin brut — une version antérieure de l'app, ou une share extension
    /// pas encore mise à jour, écrit encore la forme scalaire.
    private static func storedPaths(defaults: UserDefaults, kind: Kind) -> [String] {
        guard let raw = defaults.string(forKey: kind.pendingPathKey), !raw.isEmpty else { return [] }
        if let data = raw.data(using: .utf8),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            return list
        }
        return [raw]
    }

    private static func write(paths: [String], defaults: UserDefaults, kind: Kind) {
        guard let data = try? JSONEncoder().encode(paths),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: kind.pendingPathKey)
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
