import Foundation
import NemorisEngine

/// Singleton qui gère le cycle de vie du TransactionEngine côté app.
///
/// Choix techniques :
/// - `engine.sqlite` vit dans Application Support (séparé du finance.sqlite utilisateur)
/// - Le seed JSON + modèle ONNX sont bundlés via le SPM NemorisEngine (Bundle.module)
/// - Boot paresseux : `shared.engine` n'instancie qu'au premier accès
/// - Embeddings activés par défaut (≈300 ms de warm-up acceptable au lancement)
///
/// La donnée utilisateur (tiers, transactions, payee_groups) reste dans finance.sqlite,
/// gérée par l'app via raw SQLite C API. Aucun mélange des deux schémas.
@MainActor
@Observable
final class EngineBootstrap {

    static let shared = EngineBootstrap()

    private(set) var engine: TransactionEngine?
    private(set) var bootError: String?
    private(set) var bootTimeMs: Int?
    private var bootTask: Task<Void, Never>? = nil

    private init() {}

    /// À appeler depuis NemorisApp au lancement. Idempotent : un second appel renvoie
    /// immédiatement.
    ///
    /// **Perf** : le boot lourd (chargement du modèle ONNX MiniLM ~22 MB + seed JSON
    /// + construction de l'index embeddings) tourne dans un `Task.detached` → main
    /// thread libre pour rendre l'UI. Le moteur n'est exposé via `engine` qu'une fois
    /// le boot terminé (peut prendre 1-15s au cold start selon le device).
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

            // Retour sur MainActor (héritage de l'isolation du Task parent).
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

    /// Réinitialise le moteur (utile pour les outils debug / réimport seed).
    func reset() {
        bootTask?.cancel()
        bootTask = nil
        engine = nil
        bootError = nil
        bootTimeMs = nil
    }

    /// Path persistant pour la base moteur (apprentissage local : merchants 'learned', contacts).
    /// Le seed canonique est rechargé depuis le bundle à chaque boot, donc supprimer ce fichier
    /// est non destructif tant que l'utilisateur n'a pas validé de tiers personnalisés.
    private func engineDatabaseURL() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        let dir = support.appendingPathComponent("Nemoris", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.sqlite")
    }
}
