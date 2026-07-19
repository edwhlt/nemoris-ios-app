import Foundation

/// Cache disque générique stocké dans `Library/Caches/nemoris/{name}.json`.
///
/// Pourquoi `Library/Caches/` plutôt qu'un cluster SQLite ?
///   - iOS peut purger ce dossier automatiquement si manque d'espace (acceptable
///     car le contenu est toujours re-récupérable via les APIs sources).
///   - Jamais inclus dans iCloud / dossier sync utilisateur → la base SQLite
///     représente VRAIMENT les données utilisateur (positions, ordres, transactions),
///     pas un mélange data + cache HTTP.
///   - Pas de migration SQL à maintenir.
///   - Backup système plus léger.
///
/// Implémentation :
///   - Hydrate-once à la première lecture (lecture disque synchrone, max ~50ms
///     pour un cache de quelques MB → acceptable hors écran de boot).
///   - Lectures suivantes : RAM uniquement.
///   - Écritures : debouncing 200 ms via `Task.detached`. Plusieurs `set()`
///     consécutifs ne déclenchent qu'une seule écriture disque.
///
/// Concurrence :
///   - `@MainActor` pour simplicité (toutes les lectures viennent de l'UI).
///   - Lectures/écritures sur disque dispatched off-main via `Task.detached`.
@MainActor
final class JSONFileCache<Value: Codable & Sendable> {

    // MARK: - State

    private var memory: [String: Value] = [:]
    private var hydrated = false
    private let fileURL: URL
    private var pendingWrite: Task<Void, Never>?

    // MARK: - Init

    /// `name` est le nom du fichier (sans extension). Le fichier final est
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

    /// Lecture disque synchrone au premier appel. Si le fichier n'existe pas
    /// ou est corrompu, démarre avec un dict vide.
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

    /// Retourne la valeur stockée pour `key`, ou `nil`.
    func get(_ key: String) -> Value? {
        hydrateIfNeeded()
        return memory[key]
    }

    /// Stocke `value` pour `key`. Écriture disque debouncée 200 ms.
    func set(_ key: String, value: Value) {
        hydrateIfNeeded()
        memory[key] = value
        scheduleWrite()
    }

    /// Retire la valeur pour `key`.
    func remove(_ key: String) {
        hydrateIfNeeded()
        memory[key] = nil
        scheduleWrite()
    }

    /// Vide le cache (RAM + disque).
    func clear() {
        memory.removeAll()
        hydrated = true
        scheduleWrite()
    }

    /// Toutes les clés présentes dans le cache.
    func allKeys() -> [String] {
        hydrateIfNeeded()
        return Array(memory.keys)
    }

    /// Nombre d'entrées en cache.
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
