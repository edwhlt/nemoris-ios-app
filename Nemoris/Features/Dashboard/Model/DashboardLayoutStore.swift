import Foundation

// MARK: - DashboardLayoutStore
//
// Persistence of the Dashboard's layout (order, visibility, size per card).
//
// Same doctrine as `AppState.mainTabOrder` — UserDefaults + a normalization
// pass that fills in missing entries — but **in JSON rather than a
// `[String]` with suffixes**: the preference carries three pieces of information per card,
// and a positional encoding would become unreadable as soon as a
// fourth one is needed (a period per card, say).

enum DashboardLayoutStore {

    static let storageKey = "dashboard.layout.v1"

    // MARK: - Read / write

    static func load(from defaults: UserDefaults = .standard) -> [DashboardCardPreference] {
        guard let data = defaults.data(forKey: storageKey) else {
            return sanitize([])   // no preference yet: the default layout
        }
        return sanitize(decode(data))
    }

    static func save(_ preferences: [DashboardCardPreference], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(sanitize(preferences)) else { return }
        defaults.set(data, forKey: storageKey)
    }

    // MARK: - Tolerant decoding

    /// The raw on-disk form. Decoded first as a `String`, DELIBERATELY:
    /// if a future version removes a card, decoding directly into
    /// `[DashboardCardPreference]` would fail to decode the WHOLE array and
    /// the user would lose their entire layout instead of a single entry.
    private struct RawPreference: Codable {
        let card: String
        let isVisible: Bool
        let size: String
    }

    private static func decode(_ data: Data) -> [DashboardCardPreference] {
        guard let raws = try? JSONDecoder().decode([RawPreference].self, from: data) else { return [] }
        return raws.compactMap { raw in
            guard let card = DashboardCardID(rawValue: raw.card) else { return nil }
            let size = DashboardCardSize(rawValue: raw.size) ?? card.defaultSize
            return DashboardCardPreference(card: card, isVisible: raw.isVisible, size: size)
        }
    }

    // MARK: - Normalisation

    /// Deduplicates, fixes sizes that became invalid, and **appends at the end of the
    /// list** any missing card — so a card added in a future version won't
    /// insert itself into the middle of an already-customized layout.
    ///
    /// A clone of `AppState.sanitizeTabOrder`, plus the size clamp.
    static func sanitize(_ input: [DashboardCardPreference]) -> [DashboardCardPreference] {
        var result: [DashboardCardPreference] = []
        var seen: Set<DashboardCardID> = []

        for var preference in input where !seen.contains(preference.card) {
            // Covers the case "a card's supported sizes had `.compact` removed
            // in an update": without this clamp, the card would render
            // in a size its content can't honor.
            if !preference.card.supportedSizes.contains(preference.size) {
                preference.size = preference.card.defaultSize
            }
            result.append(preference)
            seen.insert(preference.card)
        }

        for card in DashboardCardID.allCases where !seen.contains(card) {
            result.append(DashboardCardPreference(defaultsFor: card))
        }
        return result
    }
}
