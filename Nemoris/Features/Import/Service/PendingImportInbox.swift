import Foundation

/// Inbox for documents dropped off by an App Intent / Siri shortcut
/// (`ImportInvestmentDocumentIntent`, `ImportFileIntent`) or by the share
/// extensions (`NemorisShareInvest`, `NemorisShareTransactions`).
///
/// The depositor imports NOTHING silently: it copies the received file into
/// the shared App Group container (`PendingImports/<uuid>.<ext>`) and sets a
/// key pointing to it (one key PER import type). The next time the app comes
/// to the foreground, it consumes the key, opens the pre-filled import screen
/// and lets the user review, then validate (no automatic commit).
///
/// The App Group container is shared between the app, the intent extension
/// and the share extensions (same suite name as `WidgetDataStore.appGroupID`).
/// The share extensions embed a MIRROR of the writing logic
/// (`ShareInboxWriter` in NemorisShareTransactions/ and NemorisShareInvest/,
/// same convention as the widget's mirrored models) — keep the keys, folder
/// name and file format in sync.
@MainActor
enum PendingImportInbox {

    /// Pending import type. Each kind has its own key → an investment drop never
    /// overwrites a transaction drop (and vice versa).
    enum Kind {
        /// Portfolio statement/capture → pre-filled `InvestmentPDFImportView`.
        case investment
        /// CSV bank statement → pre-filled `ImportEntryView`.
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
    /// Maximum lifetime of a pending file before it's purged (never consumed).
    private static let maxAge: TimeInterval = 24 * 3600

    /// The `PendingImports/` directory in the App Group container, created if missing.
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

    /// Drops off ONE pending document.
    @discardableResult
    static func stash(data: Data, fileExtension: String, kind: Kind) -> Bool {
        stash(files: [(data: data, fileExtension: fileExtension)], kind: kind)
    }

    /// Drops off N pending documents. Called by the App Intents and the share
    /// extensions (through their `ShareInboxWriter` mirror).
    ///
    /// APPEND semantics: paths already pending are kept. Two successive shares
    /// before returning to the app accumulate, instead of the second erasing the
    /// first (whose file would stay on disk with nothing pointing to it).
    @discardableResult
    static func stash(files: [(data: Data, fileExtension: String)], kind: Kind) -> Bool {
        guard !files.isEmpty else { return false }
        purgeStale()
        guard let dir = inboxDirectory(),
              let defaults = UserDefaults(suiteName: appGroupID) else { return false }

        var paths = storedPaths(defaults: defaults, kind: kind)
        for file in files {
            // The bytes are authoritative (same rule as the share extensions): an
            // `IntentFile` supplied by Shortcuts often carries an abstract type without
            // a usable extension, and a `.dat` file would then be treated as plain text
            // by the import — binary passing for a statement.
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

    /// Consumes the pending investment documents. Called by the app when it comes
    /// to the foreground.
    static func consumePendingInvestmentImports() -> [URL] {
        consume(kind: .investment)
    }

    /// Consumes the pending transaction statements.
    static func consumePendingTransactionImports() -> [URL] {
        consume(kind: .transactions)
    }

    /// Consumes the pending documents of the given kind (those still on disk).
    /// Clears the key (one-shot).
    private static func consume(kind: Kind) -> [URL] {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return [] }
        let paths = storedPaths(defaults: defaults, kind: kind)
        guard !paths.isEmpty else { return [] }

        // The key is cleared in every case: one-shot, a vanished file isn't offered
        // again on the next foreground.
        defaults.removeObject(forKey: kind.pendingPathKey)

        return paths.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else {
                print("[PendingImportInbox] Fichier en attente introuvable : \(path)")
                return nil
            }
            return URL(fileURLWithPath: path)
        }
    }

    /// Tolerant key read: a JSON array of paths (current format), or a raw path
    /// — an earlier app version, or a share extension not yet updated, still
    /// writes the scalar form.
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

    /// Deletes pending files older than `maxAge` (never consumed).
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
