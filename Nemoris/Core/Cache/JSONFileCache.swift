import Foundation

/// Generic disk cache stored at `Library/Caches/nemoris/{name}.json`.
///
/// Why `Library/Caches/` rather than a SQLite table?
///   - iOS can automatically purge this folder under storage pressure
///     (acceptable, since the content is always re-fetchable from its source APIs).
///   - Never included in iCloud / the user's sync folder → the SQLite
///     database TRULY represents user data (positions, orders, transactions),
///     not a mix of data and HTTP cache.
///   - No SQL migration to maintain.
///   - Lighter system backup.
///
/// Implementation:
///   - Hydrate-once on first read (synchronous disk read, up to ~50ms for a
///     cache of a few MB → acceptable outside the boot screen).
///   - Subsequent reads: RAM only.
///   - Writes: 200 ms debounce via `Task.detached`. Several consecutive
///     `set()` calls trigger only one disk write.
///
/// Concurrency:
///   - `@MainActor` for simplicity (all reads come from the UI).
///   - Disk reads/writes are dispatched off-main via `Task.detached`.
@MainActor
final class JSONFileCache<Value: Codable & Sendable> {

    // MARK: - State

    private var memory: [String: Value] = [:]
    private var hydrated = false
    private let fileURL: URL
    private var pendingWrite: Task<Void, Never>?

    // MARK: - Init

    /// `name` is the file name (without extension). The final file is
    /// `Library/Caches/nemoris/{name}.json`.
    init(name: String) {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("nemoris", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("\(name).json")
    }

    // MARK: - Hydration

    /// Synchronous disk read on the first call. If the file doesn't exist or
    /// is corrupted, starts with an empty dictionary.
    private func hydrateIfNeeded() {
        guard !hydrated else { return }
        hydrated = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: Value].self, from: data) {
            memory = decoded
        }
    }

    // MARK: - Public API

    /// Returns the stored value for `key`, or `nil`.
    func get(_ key: String) -> Value? {
        hydrateIfNeeded()
        return memory[key]
    }

    /// Stores `value` for `key`. Disk write is debounced 200 ms.
    func set(_ key: String, value: Value) {
        hydrateIfNeeded()
        memory[key] = value
        scheduleWrite()
    }

    /// Removes the value for `key`.
    func remove(_ key: String) {
        hydrateIfNeeded()
        memory[key] = nil
        scheduleWrite()
    }

    /// Clears the cache (RAM + disk).
    func clear() {
        memory.removeAll()
        hydrated = true
        scheduleWrite()
    }

    /// All keys present in the cache.
    func allKeys() -> [String] {
        hydrateIfNeeded()
        return Array(memory.keys)
    }

    /// Number of cached entries.
    var count: Int {
        hydrateIfNeeded()
        return memory.count
    }

    // MARK: - Disk write (debounced)

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let snapshot = memory
        let url = fileURL
        pendingWrite = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
