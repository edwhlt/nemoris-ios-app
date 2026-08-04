import Foundation

// MARK: - DashboardLayoutStore
//
// Persistance de la mise en page du Dashboard (ordre, visibilité, taille par carte).
//
// Même doctrine que `AppState.mainTabOrder` — UserDefaults + une passe de
// normalisation qui complète les entrées manquantes — mais **en JSON plutôt qu'en
// `[String]` avec des suffixes** : la préférence porte trois informations par carte,
// et un encodage positionnel deviendrait illisible dès qu'on voudra en ajouter une
// quatrième (une période par carte, par exemple).

enum DashboardLayoutStore {

    static let storageKey = "dashboard.layout.v1"

    // MARK: - Lecture / écriture

    static func load(from defaults: UserDefaults = .standard) -> [DashboardCardPreference] {
        guard let data = defaults.data(forKey: storageKey) else {
            return sanitize([])   // aucune préférence encore : mise en page par défaut
        }
        return sanitize(decode(data))
    }

    static func save(_ preferences: [DashboardCardPreference], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(sanitize(preferences)) else { return }
        defaults.set(data, forKey: storageKey)
    }

    // MARK: - Décodage tolérant

    /// Forme brute sur le disque. On décode d'abord en `String` **volontairement** :
    /// si une version future retire une carte, décoder directement en
    /// `[DashboardCardPreference]` ferait échouer le décodage de TOUT le tableau et
    /// l'utilisateur perdrait sa mise en page entière au lieu d'une seule entrée.
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

    /// Déduplique, corrige les tailles devenues invalides, et **ajoute en fin de liste**
    /// toute carte absente — donc une carte ajoutée dans une future version n'ira pas
    /// s'insérer au milieu d'une mise en page déjà personnalisée.
    ///
    /// Clone de `AppState.sanitizeTabOrder`, avec en plus le clamp de taille.
    static func sanitize(_ input: [DashboardCardPreference]) -> [DashboardCardPreference] {
        var result: [DashboardCardPreference] = []
        var seen: Set<DashboardCardID> = []

        for var preference in input where !seen.contains(preference.card) {
            // Couvre le cas « on a retiré `.compact` des tailles supportées d'une
            // carte dans une mise à jour » : sans ce clamp, la carte serait rendue
            // dans une taille que son contenu ne sait pas honorer.
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
