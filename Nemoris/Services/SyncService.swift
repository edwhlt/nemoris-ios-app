import Foundation

/// Manages automatic synchronisation of the SQLite database to a user-chosen folder.
/// Sync is triggered:
///   1. Automatically when the DB file is written (via DispatchSourceFileSystemObject)
///   2. Immediately when the app goes to background
///   3. Manually via sync()
final class SyncService: @unchecked Sendable {
    static let shared = SyncService()

    private let bookmarkKey = "syncDestinationBookmark"
    private let queue = DispatchQueue(label: "com.finance.syncservice", qos: .utility)

    private var destinationURL: URL?
    private var syncTimer: DispatchWorkItem?
    private var fileSource: DispatchSourceFileSystemObject?

    private(set) var destinationFolderName: String?
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncSuccess: Bool?

    private init() {
        resolveStoredBookmark()
    }

    // MARK: - Public API

    var hasDestination: Bool { destinationURL != nil }

    /// Registers a folder chosen by the user via document picker as the sync destination.
    func setDestination(from pickerURL: URL) throws {
        _ = pickerURL.startAccessingSecurityScopedResource()
        let bookmark: Data
        do {
            bookmark = try pickerURL.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            pickerURL.stopAccessingSecurityScopedResource()
            throw error
        }
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)

        destinationURL?.stopAccessingSecurityScopedResource()
        destinationURL = pickerURL
        destinationFolderName = pickerURL.lastPathComponent

        startFileMonitor()
        sync()
    }

    func removeDestination() {
        stopFileMonitor()
        destinationURL?.stopAccessingSecurityScopedResource()
        destinationURL = nil
        destinationFolderName = nil
        lastSyncDate = nil
        lastSyncSuccess = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }

    /// Called when the database file changes (debounced by 2 s).
    func scheduleSync() {
        syncTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.sync() }
        syncTimer = item
        queue.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    /// Copies the database to the sync destination immediately (synchronous, fast for small files).
    @discardableResult
    func sync() -> Bool {
        guard let destFolder = destinationURL else { return false }
        guard DatabaseManager.shared.hasDatabase() else { return false }

        let source = DatabaseManager.shared.sqliteURL()
        let dest = destFolder.appendingPathComponent(source.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            DispatchQueue.main.async {
                self.lastSyncDate = Date()
                self.lastSyncSuccess = true
            }
            return true
        } catch {
            DispatchQueue.main.async {
                self.lastSyncDate = Date()
                self.lastSyncSuccess = false
            }
            return false
        }
    }

    /// Call this when the app enters the background to trigger an immediate sync.
    func syncIfNeeded() {
        guard hasDestination else { return }
        syncTimer?.cancel()
        syncTimer = nil
        sync()
    }

    /// Restarts the file monitor (call after the active database changes).
    func refreshFileMonitor() {
        startFileMonitor()
    }

    // MARK: - File Monitor

    private func startFileMonitor() {
        stopFileMonitor()
        guard DatabaseManager.shared.hasDatabase(), destinationURL != nil else { return }
        let path = DatabaseManager.shared.sqliteURL().path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: queue
        )
        source.setEventHandler { [weak self] in self?.scheduleSync() }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }

    private func stopFileMonitor() {
        fileSource?.cancel()
        fileSource = nil
        syncTimer?.cancel()
        syncTimer = nil
    }

    // MARK: - Bookmark Persistence

    private func resolveStoredBookmark() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }

        _ = url.startAccessingSecurityScopedResource()
        destinationURL = url
        destinationFolderName = url.lastPathComponent

        if isStale, let newData = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(newData, forKey: bookmarkKey)
        }

        startFileMonitor()
    }
}
