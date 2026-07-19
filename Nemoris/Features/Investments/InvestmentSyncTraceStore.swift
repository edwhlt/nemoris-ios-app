import Foundation

/// Log léger de la dernière tentative de synchronisation des cours, par
/// identifier (ticker ou ISIN). Persisté dans UserDefaults pour rester dispo
/// après relaunch sans payer le coût d'une table SQLite supplémentaire.
///
/// Utilisé par `InvestmentPositionDetailView` pour afficher "Dernière sync :
/// il y a X min · success/error · message" — au lieu d'un sync silencieux où
/// l'user ne sait jamais ce qui s'est passé.
enum InvestmentSyncTraceStore {

    enum Status: String, Codable {
        case success
        case noData       // Yahoo + Stooq ont répondu mais 0 points
        case error        // Réseau, erreur HTTP, parsing
        case invalidId    // Identifier vide
    }

    struct Entry: Codable {
        let identifier: String
        let attemptedAt: Date
        let status: Status
        let message: String         // Lisible par l'user
        let symbolsTried: [String]  // Liste des symbols essayés sur Yahoo/Stooq
        let source: String?         // "yahoo" / "stooq" si success
        let pointsCount: Int        // Nb de points récupérés si success
    }

    private static let storageKey = "investment_sync_trace_v1"

    /// Enregistre une tentative pour un identifier donné. Remplace l'entrée
    /// précédente (on ne garde que la plus récente — c'est ce qui intéresse l'user).
    static func record(_ entry: Entry) {
        var all = loadAll()
        // Clé case-insensitive : sync sur "FR0000121329" et "fr0000121329" partagent la même trace
        all[entry.identifier.uppercased()] = entry
        save(all)
    }

    /// Récupère la dernière tentative pour un identifier.
    static func fetch(identifier: String) -> Entry? {
        let key = identifier.uppercased()
        return loadAll()[key]
    }

    /// Récupère la meilleure entrée disponible parmi plusieurs identifiers
    /// (priorité ISIN > ticker pour matcher la logique `bestSyncIdentifier`).
    static func fetchBest(identifiers: [String]) -> Entry? {
        for id in identifiers where !id.isEmpty {
            if let entry = fetch(identifier: id) { return entry }
        }
        return nil
    }

    /// Reset complet — utile pour debug ou après un wipe de la DB.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Efface la trace pour un identifier précis. À appeler quand la position
    /// correspondante est supprimée, sinon la trace reste dans UserDefaults
    /// et se réaffiche si l'user recrée une position avec le même ticker/ISIN.
    static func clear(identifiers: [String]) {
        var all = loadAll()
        for id in identifiers where !id.isEmpty {
            all.removeValue(forKey: id.uppercased())
        }
        save(all)
    }

    // MARK: - Storage

    private static func loadAll() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func save(_ dict: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

// MARK: - Helpers d'affichage

extension InvestmentSyncTraceStore.Status {
    var icon: String {
        switch self {
        case .success:   return "checkmark.circle.fill"
        case .noData:    return "questionmark.circle.fill"
        case .error:     return "exclamationmark.triangle.fill"
        case .invalidId: return "xmark.octagon.fill"
        }
    }

    var label: String {
        switch self {
        case .success:   return "Succès"
        case .noData:    return "Aucune donnée"
        case .error:     return "Erreur"
        case .invalidId: return "ID invalide"
        }
    }
}

extension InvestmentSyncTraceStore.Entry {
    /// "il y a 5 min" / "il y a 2 h" / "il y a 3 j"
    var humanizedAttemptedAt: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: attemptedAt, relativeTo: Date())
    }
}
