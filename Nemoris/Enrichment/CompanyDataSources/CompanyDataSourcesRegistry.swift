import Foundation
import Observation

/// Registry singleton qui agrège toutes les sources d'identification d'entreprise.
/// Gère :
///   - Liste statique de toutes les sources connues (Sirene, Companies House, Zefix, …)
///   - État `enabled` persisté en UserDefaults
///   - Clés API persistées en UserDefaults
///   - Méthode `search(query:country:postalCode:)` qui dispatch sur les sources actives
///     **filtrant par pays quand un pays est connu** : si le tier est en VN, on ne tape pas
///     Companies House (UK). Si le pays est inconnu (`nil`), on interroge TOUTES les
///     sources actives — cf. `activeSources(forCountry:)`.
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

    /// Sources actives pour ce pays. Filtre les placeholders non-implémentés et celles
    /// qui ont `requiresAPIKey = true` mais pas de clé saisie.
    ///
    /// **Sémantique de `country`** :
    ///   - non-nil → contrainte stricte : seules les sources globales (`source.country == nil`)
    ///     et celles dont le pays correspond exactement sont interrogées.
    ///   - **nil → AUCUNE contrainte** : toutes les sources actives sont interrogées.
    ///
    /// ⚠️ `nil` signifiait auparavant l'inverse — il faisait échouer le `guard let normalized`
    /// et excluait donc *toutes* les sources déclarant un pays, c'est-à-dire les trois qui
    /// existent (Sirene FR, Companies House GB, Zefix CH). Les écrans qui passaient `nil`
    /// (`EnrichmentSheetView`, `EnrichmentMapFullscreenSheet`) ne recevaient donc jamais le
    /// moindre résultat d'entreprise : leur toggle « Sources entreprises » était inerte,
    /// silencieusement, sans erreur ni liste vide distinguable d'une recherche infructueuse.
    ///
    /// « Pays inconnu » veut dire « cherche partout », jamais « ne cherche nulle part » :
    /// une recherche manuelle sur un libellé étranger ne doit pas être condamnée d'avance.
    func activeSources(forCountry country: String?) -> [any CompanyDataSource] {
        let normalized = country?.uppercased()
        return allKnownSources.filter { source in
            guard isEnabled(source) else { return false }
            // Filtre par pays — seulement si un pays est demandé.
            if let normalized, let src = source.country, src != normalized { return false }
            // Si clé API requise, vérifier qu'on en a une
            if source.requiresAPIKey {
                guard let key = apiKeys[source.id], !key.isEmpty else { return false }
            }
            return true
        }
    }

    // MARK: - Search dispatch

    /// Interroge en parallèle toutes les sources actives matchant le pays donné.
    /// Si `country == nil`, toutes les sources actives sont interrogées (aucune contrainte).
    /// Concatène les résultats (pas de dédup — l'appelant peut le faire).
    /// ⚠️ L'ordre de sortie est celui d'ACHÈVEMENT des tâches, donc non déterministe :
    /// ne jamais prendre `.first` comme « meilleur résultat ». Le classement est la
    /// responsabilité de l'appelant.
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
