import Foundation
import SQLite3

enum DatabaseLinkError: LocalizedError {
    case invalidSourceFile
    case bookmarkFailed(String)
    case notReadable(String)

    var errorDescription: String? {
        switch self {
        case .invalidSourceFile:
            return "Le fichier sélectionné n'est pas un fichier .sqlite valide."
        case .bookmarkFailed(let reason):
            return "Impossible de mémoriser le fichier : \(reason)"
        case .notReadable(let reason):
            return "Fichier inaccessible : \(reason)"
        }
    }
}

final class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()

    private let bookmarkKey = "databaseFileBookmark"
    private let fallbackFileName = "finance.sqlite"

    private(set) var externalFileURL: URL?

    private init() {
        resolveStoredBookmark()
    }

    // MARK: - Public API

    var externalFileName: String? {
        externalFileURL?.lastPathComponent
    }

    func hasDatabase() -> Bool {
        externalFileURL != nil || FileManager.default.fileExists(atPath: fallbackURL().path)
    }

    /// Kept for compatibility with existing repository callers.
    func hasDatabaseCopy() -> Bool { hasDatabase() }

    func sqliteURL() -> URL {
        externalFileURL ?? fallbackURL()
    }

    /// Links an external SQLite file and verifies it can be opened by SQLite.
    func linkExternalFile(from pickerURL: URL) throws {
        guard pickerURL.pathExtension.lowercased() == "sqlite" else {
            throw DatabaseLinkError.invalidSourceFile
        }

        // Start security scope (may return false on iOS for files already accessible)
        _ = pickerURL.startAccessingSecurityScopedResource()

        // Verify SQLite can actually open the file
        var testDB: OpaquePointer?
        let openResult = sqlite3_open_v2(pickerURL.path, &testDB, SQLITE_OPEN_READONLY, nil)
        sqlite3_close(testDB)
        guard openResult == SQLITE_OK else {
            pickerURL.stopAccessingSecurityScopedResource()
            let msg = String(cString: sqlite3_errstr(openResult))
            throw DatabaseLinkError.notReadable(msg)
        }

        // Persist bookmark for next launch
        if let bookmarkData = try? pickerURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmarkData, forKey: bookmarkKey)
        }

        externalFileURL?.stopAccessingSecurityScopedResource()
        externalFileURL = pickerURL
    }

    func unlinkExternalFile() {
        externalFileURL?.stopAccessingSecurityScopedResource()
        externalFileURL = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// Returns a human-readable connection status for the current database.
    func connectionStatus() -> String {
        guard let url = externalFileURL else {
            let path = fallbackURL().path
            guard FileManager.default.fileExists(atPath: path) else {
                return "Aucun fichier lié"
            }
            return verifyOpen(path: path)
        }
        return verifyOpen(path: url.path)
    }

    // MARK: - Private

    private func verifyOpen(path: String) -> String {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        sqlite3_close(db)
        if result == SQLITE_OK { return "Connexion OK" }
        return "Erreur SQLite \(result) : \(String(cString: sqlite3_errstr(result)))"
    }

    private func resolveStoredBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        // Start scope; on iOS this may return false but the URL can still be accessible
        _ = url.startAccessingSecurityScopedResource()
        externalFileURL = url

        if isStale {
            if let newData = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(newData, forKey: bookmarkKey)
            }
        }
    }

    private func fallbackURL() -> URL {
        let supportDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = supportDir.appendingPathComponent("FinanceMobileIOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        return appDir.appendingPathComponent(fallbackFileName)
    }
}
