import Foundation
import Observation

/// Registry singleton qui agrège toutes les sources d'identification d'entreprise.
/// Gère :
///   - Liste statique de toutes les sources connues (Sirene, Companies House, Zefix, …)
///   - État `enabled` persisté en UserDefaults
///   - Clés API persistées en UserDefaults
///   - Méthode `search(query:country:postalCode:)` qui dispatch sur les sources actives
///     **filtrant automatiquement par pays** : si le tier est en VN, on ne tape pas
///     Companies House (UK) ; si pays inconnu, on tape les sources globales uniquement.
///
/// Pour ajouter une source : voir `CompanyDataSource.swift`.
@MainActor
@Observable
final class CompanyDataSourcesRegistry {

    static let shared = CompanyDataSourcesRegistry()

    /// Toutes les sources connues, dans l'ordre d'affichage settings.
    let allKnownSources: [any CompanyDataSource] = [
        SireneDataSource(),
        CompaniesHouseDataSource(),
        ZefixDataSource()
    ]

    /// IDs activés par défaut (sources gratuites + sans clé API).
    private static let defaultEnabledIds: Set<String> = ["sirene_fr", "zefix_ch"]

    /// Préfixes UserDefaults pour la persistance.
    private static let enabledKey = "companyDataSources.enabled"
    private static let apiKeyPrefix = "companyDataSources.apiKey."

    // MARK: - State (Observable)

    private(set) var enabledIds: Set<String>
    private(set) var apiKeys: [String: String]

    private init() {
        // Charge l'état persisté
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

    /// Sources actives pour ce pays. Inclut les sources globales (country = nil)
    /// et les sources matchant le code ISO. Filtre les placeholders non-implémentés.
    /// Filtre aussi celles qui ont `requiresAPIKey = true` mais pas de clé saisie.
    func activeSources(forCountry country: String?) -> [any CompanyDataSource] {
        let normalized = country?.uppercased()
        return allKnownSources.filter { source in
            guard isEnabled(source) else { return false }
            // Filtre par pays
            if let src = source.country {
                guard let normalized, src == normalized else { return false }
            }
            // Si clé API requise, vérifier qu'on en a une
            if source.requiresAPIKey {
                guard let key = apiKeys[source.id], !key.isEmpty else { return false }
            }
            return true
        }
    }

    // MARK: - Search dispatch

    /// Interroge en parallèle toutes les sources actives matchant le pays donné.
    /// Si `country == nil`, seules les sources globales sont interrogées.
    /// Concatène les résultats (pas de dédup — l'appelant peut le faire).
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
