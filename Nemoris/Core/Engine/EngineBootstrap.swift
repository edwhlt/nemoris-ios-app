import Foundation
import NemorisEngine

/// Singleton managing the app-side lifecycle of the TransactionEngine.
///
/// Technical choices:
/// - `engine.sqlite` lives in Application Support (separate from the user's finance.sqlite)
/// - The JSON seed + ONNX model are bundled via the NemorisEngine SPM package (Bundle.module)
/// - Lazy boot: `shared.engine` only instantiates on first access
/// - Embeddings enabled by default (~300 ms warm-up acceptable at launch)
///
/// User data (tiers, transactions, payee_groups) stays in finance.sqlite,
/// managed by the app through the raw SQLite C API. The two schemas never mix.
@MainActor
@Observable
final class EngineBootstrap {

    static let shared = EngineBootstrap()

    private(set) var engine: TransactionEngine?
    private(set) var bootError: String?
    private(set) var bootTimeMs: Int?
    private var bootTask: Task<Void, Never>? = nil

    private init() {}

    /// Call from NemorisApp at launch. Idempotent: a second call returns
    /// immediately.
    ///
    /// **Perf**: the heavy boot work (loading the ~22 MB ONNX MiniLM model +
    /// JSON seed + building the embeddings index) runs in a `Task.detached`,
    /// keeping the main thread free to render the UI. The engine is only
    /// exposed via `engine` once boot completes (can take 1-15s on cold
    /// start depending on the device).
    func bootIfNeeded(withEmbeddings: Bool = true) {
        guard engine == nil, bootError == nil, bootTask == nil else { return }
        let path = engineDatabaseURL().path

        bootTask = Task { [weak self] in
            let t0 = Date()
            let outcome: Result<TransactionEngine, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let e = try TransactionEngine.boot(path: path, withEmbeddings: withEmbeddings)
                    return .success(e)
                } catch {
                    return .failure(error)
                }
            }.value

            // Back on the MainActor (inherited from the parent Task's isolation).
            guard let self else { return }
            switch outcome {
            case .success(let e):
                self.engine = e
                self.bootTimeMs = Int(Date().timeIntervalSince(t0) * 1000)
                print("[EngineBootstrap] ready in \(self.bootTimeMs ?? 0) ms")
            case .failure(let err):
                self.bootError = String(describing: err)
                print("[EngineBootstrap] boot failed: \(err)")
            }
            self.bootTask = nil
        }
    }

    /// Resets the engine (useful for debug tools / seed re-import).
    func reset() {
        bootTask?.cancel()
        bootTask = nil
        engine = nil
        bootError = nil
        bootTimeMs = nil
    }

    /// Persistent path for the engine database (local learning: 'learned'
    /// merchants, contacts). The canonical seed is reloaded from the bundle
    /// on every boot, so deleting this file is non-destructive as long as
    /// the user hasn't validated any custom tiers.
    private func engineDatabaseURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = support.appendingPathComponent("Nemoris", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.sqlite")
    }
}
