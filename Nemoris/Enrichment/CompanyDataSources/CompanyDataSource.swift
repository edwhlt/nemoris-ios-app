import Foundation

/// Protocole commun pour toutes les sources d'identification d'entreprise.
/// Chaque pays a typiquement sa propre source (Sirene pour FR, Companies House pour UK, etc.)
/// + des sources globales (OpenCorporates).
///
/// **Pour ajouter une nouvelle source** :
///   1. Créer un `struct MaSourceDataSource: CompanyDataSource`
///   2. Implémenter `search(...)` qui renvoie `[MerchantEnrichment]` avec `source = .sirene`
///      (on garde `.sirene` comme catégorie générique "registre entreprises" — la
///      distinction se fait via `id` et `displayName`)
///   3. L'ajouter à `CompanyDataSourcesRegistry.allKnownSources`
///   4. (Optionnel) Pré-configurer dans `defaultEnabledIds` si gratuit + utile par défaut
protocol CompanyDataSource: Sendable {
    /// Identifiant stable, ex. "sirene_fr", "companies_house_uk". Utilisé pour la persistance
    /// du toggle ON/OFF et de la clé API.
    var id: String { get }

    /// Nom affiché en UI, ex. "Sirene (entreprises FR)".
    var displayName: String { get }

    /// Pays couvert au format ISO 3166-1 alpha-2 (ex. "FR"). Nil = source globale.
    /// Le registry filtre automatiquement par pays au moment de la recherche.
    var country: String? { get }

    /// Si true, la source nécessite une clé API que l'utilisateur doit configurer dans
    /// les paramètres avant de pouvoir l'utiliser. Si false, marche sans config.
    var requiresAPIKey: Bool { get }

    /// URL d'inscription / d'obtention de la clé API. Utilisée pour ouvrir le navigateur
    /// depuis l'UI settings. Nil si pas pertinent.
    var apiKeyHelpURL: URL? { get }

    /// État implémentation : true = réellement fonctionnelle, false = placeholder (UI
    /// affiche un badge "Bientôt"). Permet de lister les sources prévues sans casser
    /// l'UX si l'utilisateur en active un placeholder.
    var isImplemented: Bool { get }

    /// Lance une recherche d'entreprise. Le `country` du contexte sert au routing (le
    /// registry n'appelle cette source que si son pays match ou si elle est globale).
    /// `apiKey` est passée si l'utilisateur en a configuré une.
    /// Renvoie [] si pas de résultat ou si la source est indisponible (offline / 4xx / 5xx).
    func search(query: String,
                postalCode: String?,
                apiKey: String?) async -> [MerchantEnrichment]
}

// MARK: - Default implementations

extension CompanyDataSource {
    var apiKeyHelpURL: URL? { nil }
    var isImplemented: Bool { true }
}
