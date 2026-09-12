import Foundation

/// Common protocol for every company-identification source.
/// Each country typically has its own source (Sirene for FR, Companies House for UK, etc.)
/// plus global sources (OpenCorporates).
///
/// **To add a new source**:
///   1. Create a `struct MySourceDataSource: CompanyDataSource`
///   2. Implement `search(...)`, returning `[MerchantEnrichment]` with `source = .sirene`
///      (we keep `.sirene` as the generic "company registry" category — the
///      distinction is made via `id` and `displayName`)
///   3. Add it to `CompanyDataSourcesRegistry.allKnownSources`
///   4. (Optional) Pre-configure it in `defaultEnabledIds` if it's free + useful by default
protocol CompanyDataSource: Sendable {
    /// Stable identifier, e.g. "sirene_fr", "companies_house_uk". Used to persist
    /// the ON/OFF toggle and the API key.
    var id: String { get }

    /// Name shown in the UI, e.g. "Sirene (FR companies)".
    var displayName: String { get }

    /// Country covered, ISO 3166-1 alpha-2 (e.g. "FR"). Nil = a global source.
    /// The registry filters by country automatically at search time.
    var country: String? { get }

    /// If true, the source needs an API key the user must configure in
    /// Settings before it can be used. If false, it works with no config.
    var requiresAPIKey: Bool { get }

    /// Sign-up / API key URL. Used to open the browser
    /// from the settings UI. Nil if not relevant.
    var apiKeyHelpURL: URL? { get }

    /// Implementation state: true = actually functional, false = a placeholder (the UI
    /// shows a "Coming soon" badge). Lets us list planned sources without breaking
    /// the UX if the user enables a placeholder one.
    var isImplemented: Bool { get }

    /// Runs a company search. The context's `country` is used for routing (the
    /// registry only calls this source if its country matches or it's global).
    /// `apiKey` is passed if the user has configured one.
    /// Returns [] on no result or if the source is unavailable (offline / 4xx / 5xx).
    func search(query: String,
                postalCode: String?,
                apiKey: String?) async -> [MerchantEnrichment]
}

// MARK: - Default implementations

extension CompanyDataSource {
    var apiKeyHelpURL: URL? { nil }
    var isImplemented: Bool { true }
}
