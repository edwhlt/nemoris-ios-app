import Foundation
import Observation

/// Singleton registry that aggregates every company-identification source.
/// Handles:
///   - a static list of every known source (Sirene, Companies House, Zefix, …)
///   - `enabled` state persisted in UserDefaults
///   - API keys persisted in UserDefaults
///   - the `search(query:country:postalCode:)` method, which dispatches to active
///     sources **filtering by country when a country is known**: if the payee is in VN,
///     we don't hit Companies House (UK). If the country is unknown (`nil`), every
///     active source is queried — see `activeSources(forCountry:)`.
///
/// To add a source: see `CompanyDataSource.swift`.
@MainActor
@Observable
final class CompanyDataSourcesRegistry {

    static let shared = CompanyDataSourcesRegistry()

    /// Every known source, in the order shown in Settings.
    let allKnownSources: [any CompanyDataSource] = [
        SireneDataSource(),
        CompaniesHouseDataSource(),
        ZefixDataSource()
    ]

    /// IDs enabled by default (free sources + no API key required).
    private static let defaultEnabledIds: Set<String> = ["sirene_fr", "zefix_ch"]

    /// UserDefaults key prefixes for persistence.
    private static let enabledKey = "companyDataSources.enabled"
    private static let apiKeyPrefix = "companyDataSources.apiKey."

    // MARK: - State (Observable)

    private(set) var enabledIds: Set<String>
    private(set) var apiKeys: [String: String]

    private init() {
        // Loads the persisted state
        let defaults = UserDefaults.standard
        if let raw = defaults.array(forKey: Self.enabledKey) as? [String] {
            self.enabledIds = Set(raw)
        } else {
            self.enabledIds = Self.defaultEnabledIds
        }
        var keys: [String: String] = [:]
        let bootstrap: [any CompanyDataSource] = [
            SireneDataSource(), CompaniesHouseDataSource(), ZefixDataSource()
        ]
        for source in bootstrap {
            if let v = defaults.string(forKey: Self.apiKeyPrefix + source.id), !v.isEmpty {
                keys[source.id] = v
            }
        }
        self.apiKeys = keys
    }

    // MARK: - Mutations (UI settings)

    func setEnabled(_ source: any CompanyDataSource, enabled: Bool) {
        if enabled { enabledIds.insert(source.id) } else { enabledIds.remove(source.id) }
        UserDefaults.standard.set(Array(enabledIds), forKey: Self.enabledKey)
    }

    func setAPIKey(_ source: any CompanyDataSource, key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            apiKeys.removeValue(forKey: source.id)
            UserDefaults.standard.removeObject(forKey: Self.apiKeyPrefix + source.id)
        } else {
            apiKeys[source.id] = trimmed
            UserDefaults.standard.set(trimmed, forKey: Self.apiKeyPrefix + source.id)
        }
    }

    func apiKey(for source: any CompanyDataSource) -> String? {
        apiKeys[source.id]
    }

    func isEnabled(_ source: any CompanyDataSource) -> Bool {
        enabledIds.contains(source.id) && source.isImplemented
    }

    /// Sources active for this country. Filters out unimplemented placeholders and
    /// those that have `requiresAPIKey = true` but no key entered.
    ///
    /// **Semantics of `country`**:
    ///   - non-nil → a strict constraint: only global sources (`source.country == nil`)
    ///     and those whose country matches exactly are queried.
    ///   - **nil → NO constraint at all**: every active source is queried.
    ///
    /// ⚠️ `nil` used to mean the opposite — it made the `guard let normalized` fail
    /// and therefore excluded *every* source declaring a country, i.e. the three that
    /// exist (Sirene FR, Companies House GB, Zefix CH). The screens passing `nil`
    /// (`EnrichmentSheetView`, `EnrichmentMapFullscreenSheet`) therefore never received the
    /// slightest company result: their "Company sources" toggle was inert,
    /// silently, with no error and no empty list distinguishable from an unsuccessful search.
    ///
    /// "Unknown country" means "search everywhere", never "search nowhere":
    /// a manual search on a foreign label must not be doomed from the start.
    func activeSources(forCountry country: String?) -> [any CompanyDataSource] {
        let normalized = country?.uppercased()
        return allKnownSources.filter { source in
            guard isEnabled(source) else { return false }
            // Filter by country — only if a country is requested.
            if let normalized, let src = source.country, src != normalized { return false }
            // If an API key is required, check that we have one
            if source.requiresAPIKey {
                guard let key = apiKeys[source.id], !key.isEmpty else { return false }
            }
            return true
        }
    }

    // MARK: - Search dispatch

    /// Queries every active source matching the given country in parallel.
    /// If `country == nil`, every active source is queried (no constraint at all).
    /// Concatenates the results (no dedup — the caller can do that).
    /// ⚠️ The output order is the tasks' COMPLETION order, so non-deterministic:
    /// never take `.first` as the "best result". Ranking is the
    /// caller's responsibility.
    func search(query: String,
                country: String?,
                postalCode: String? = nil) async -> [MerchantEnrichment] {
        let sources = activeSources(forCountry: country)
        guard !sources.isEmpty else { return [] }

        let apiKeysSnapshot = self.apiKeys

        return await withTaskGroup(of: [MerchantEnrichment].self) { group in
            for source in sources {
                let key = apiKeysSnapshot[source.id]
                group.addTask { @Sendable in
                    await source.search(query: query, postalCode: postalCode, apiKey: key)
                }
            }
            var all: [MerchantEnrichment] = []
            for await batch in group {
                all.append(contentsOf: batch)
            }
            return all
        }
    }
}
