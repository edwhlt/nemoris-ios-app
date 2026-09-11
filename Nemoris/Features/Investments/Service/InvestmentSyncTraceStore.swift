import Foundation

/// Lightweight log of the last price sync attempt, per identifier (ticker or
/// ISIN). Persisted in UserDefaults to survive a relaunch without the cost of
/// an extra SQLite table.
///
/// Used by `InvestmentPositionDetailView` to show "Last sync: X min ago ·
/// success/error · message" — instead of a silent sync where the user never
/// knows what happened.
enum InvestmentSyncTraceStore {

    enum Status: String, Codable {
        case success
        case noData       // Yahoo + Stooq answered but with 0 points
        case error        // Network, HTTP error, parsing
        case invalidId    // Identifier vide
        case rateLimited  // Provider 429 (breaker open) — retry later
    }

    struct Entry: Codable {
        let identifier: String
        let attemptedAt: Date
        let status: Status
        let message: LocalizedStringResource
        let symbolsTried: [String]  // Symbols tried on Yahoo/Stooq
        let source: String?         // "yahoo" / "stooq" si success
        let pointsCount: Int        // Number of points fetched on success
    }

    private static let storageKey = "investment_sync_trace_v1"

    /// Records an attempt for a given identifier. Replaces the previous entry
    /// (only the latest is kept — that's what matters to the user).
    static func record(_ entry: Entry) {
        var all = loadAll()
        // Case-insensitive key: a sync on "FR0000121329" and on "fr0000121329" share the same trace
        all[entry.identifier.uppercased()] = entry
        save(all)
    }

    /// Fetches the last attempt for an identifier.
    static func fetch(identifier: String) -> Entry? {
        let key = identifier.uppercased()
        return loadAll()[key]
    }

    /// Fetches the best available entry among several identifiers (ISIN >
    /// ticker priority, matching `bestSyncIdentifier`).
    static func fetchBest(identifiers: [String]) -> Entry? {
        for id in identifiers where !id.isEmpty {
            if let entry = fetch(identifier: id) { return entry }
        }
        return nil
    }

    /// Full reset — useful for debugging or after a database wipe.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Clears the trace for one identifier. Call it when the matching position is
    /// deleted; otherwise the trace stays in UserDefaults and reappears if the
    /// user recreates a position with the same ticker/ISIN.
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
        case .success:     return "checkmark.circle.fill"
        case .noData:      return "questionmark.circle.fill"
        case .error:       return "exclamationmark.triangle.fill"
        case .invalidId:   return "xmark.octagon.fill"
        case .rateLimited: return "hourglass.circle.fill"
        }
    }

    var label: String {
        switch self {
        case .success:     return "Succès"
        case .noData:      return "Aucune donnée"
        case .error:       return "Erreur"
        case .invalidId:   return "ID invalide"
        case .rateLimited: return "Limite atteinte"
        }
    }
}

extension InvestmentSyncTraceStore.Entry {
    /// Relative age as shown to the user ("5 min", "2 h", "3 d" ago).
    var humanizedAttemptedAt: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLocalization.locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: attemptedAt, relativeTo: Date())
    }
}
