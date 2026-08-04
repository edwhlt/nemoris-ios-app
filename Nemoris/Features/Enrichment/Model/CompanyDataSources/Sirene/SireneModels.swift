import Foundation
import CoreLocation

/// Une entreprise SIRENE (résultat de l'API recherche-entreprises.api.gouv.fr).
struct SireneEstablishment: Identifiable, Hashable {
    let siret: String
    let siren: String
    let legalName: String          // raison sociale (ex "DUPUIS SAS")
    let enseigne: String?          // nom commercial / enseigne (ex "Boulangerie Dupuis")
    let nafCode: String?           // ex "10.71C"
    let address: String?           // ex "75 RUE DE LA REPUBLIQUE 69002 LYON"
    let postalCode: String?
    let city: String?
    let coordinates: CLLocationCoordinate2D?
    let createdAt: Date?
    let isActive: Bool

    var id: String { siret }

    /// Le nom le plus pertinent à afficher / utiliser comme nom de tiers.
    /// L'enseigne (commercial) prime sur la raison sociale (légale).
    var displayName: String {
        if let e = enseigne?.trimmingCharacters(in: .whitespaces), !e.isEmpty {
            return e.capitalizedFirst
        }
        return legalName.capitalizedFirst
    }

    static func == (lhs: SireneEstablishment, rhs: SireneEstablishment) -> Bool {
        lhs.siret == rhs.siret
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(siret)
    }
}

/// Résultat brut du décodage de la réponse JSON SIRENE.
struct SireneSearchResponse: Decodable {
    let results: [SireneCompany]
    let totalResults: Int

    enum CodingKeys: String, CodingKey {
        case results, totalResults = "total_results"
    }
}

struct SireneCompany: Decodable {
    let siren: String?
    let nomComplet: String?
    let nomRaisonSociale: String?
    let sigle: String?
    let activitePrincipale: String?
    let dateCreation: String?
    let dateFermeture: String?
    let etatAdministratif: String?
    let siege: SireneSiege?
    /// Établissements (agences, magasins) dont le nom ou l'enseigne matche la requête.
    /// Renseigné uniquement si l'appel demande `include=matching_etablissements`.
    ///
    /// C'est la clé du drill-down : le siège d'une enseigne est souvent à l'autre bout du
    /// pays, alors que le commerce cherché est une BRANCHE — qu'on reconnaît à son adresse.
    /// Exemple mesuré (`q=boulangerie pralus`) : le siège est à Roanne, mais la boutique
    /// facturée était « 18 quai Saint-Antoine, 69002 Lyon », qui n'apparaît que là.
    let matchingEtablissements: [SireneEtablissement]?
    let nombreEtablissements: Int?
    let nombreEtablissementsOuverts: Int?

    enum CodingKeys: String, CodingKey {
        case siren
        case nomComplet = "nom_complet"
        case nomRaisonSociale = "nom_raison_sociale"
        case sigle
        case activitePrincipale = "activite_principale"
        case dateCreation = "date_creation"
        case dateFermeture = "date_fermeture"
        case etatAdministratif = "etat_administratif"
        case siege
        case matchingEtablissements = "matching_etablissements"
        case nombreEtablissements = "nombre_etablissements"
        case nombreEtablissementsOuverts = "nombre_etablissements_ouverts"
    }
}

/// Un établissement renvoyé dans `matching_etablissements`.
/// ⚠️ `latitude`/`longitude` arrivent en CHAÎNES dans cette API, pas en nombres.
struct SireneEtablissement: Decodable {
    let siret: String?
    let adresse: String?
    let codePostal: String?
    let commune: String?
    let libelleCommune: String?
    let latitude: String?
    let longitude: String?
    let listeEnseignes: [String]?
    let nomCommercial: String?
    let estSiege: Bool?
    let ancienSiege: Bool?
    let etatAdministratif: String?
    let activitePrincipale: String?
    let dateCreation: String?

    enum CodingKeys: String, CodingKey {
        case siret, adresse, commune, latitude, longitude
        case codePostal = "code_postal"
        case libelleCommune = "libelle_commune"
        case listeEnseignes = "liste_enseignes"
        case nomCommercial = "nom_commercial"
        case estSiege = "est_siege"
        case ancienSiege = "ancien_siege"
        case etatAdministratif = "etat_administratif"
        case activitePrincipale = "activite_principale"
        case dateCreation = "date_creation"
    }
}

struct SireneSiege: Decodable {
    let siret: String?
    let adresse: String?
    let codePostal: String?
    let libelleCommune: String?
    let latitude: String?
    let longitude: String?
    let listeEnseignes: [String]?
    let nomCommercial: String?
    let activitePrincipale: String?

    enum CodingKeys: String, CodingKey {
        case siret, adresse, latitude, longitude
        case codePostal = "code_postal"
        case libelleCommune = "libelle_commune"
        case listeEnseignes = "liste_enseignes"
        case nomCommercial = "nom_commercial"
        case activitePrincipale = "activite_principale"
    }
}

extension SireneCompany {
    /// Convertit la réponse brute en un modèle utilisable côté UI.
    func toEstablishment() -> SireneEstablishment? {
        guard let siret = siege?.siret, !siret.isEmpty,
              let siren = siren, !siren.isEmpty,
              let legal = nomRaisonSociale ?? nomComplet, !legal.isEmpty else {
            return nil
        }

        let enseigne: String? = {
            if let first = siege?.listeEnseignes?.first, !first.isEmpty { return first }
            if let nc = siege?.nomCommercial, !nc.isEmpty { return nc }
            return nil
        }()

        let coords: CLLocationCoordinate2D? = {
            guard let latS = siege?.latitude, let lat = Double(latS),
                  let lonS = siege?.longitude, let lon = Double(lonS) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }()

        let createdAt: Date? = {
            guard let s = dateCreation else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            return formatter.date(from: s)
        }()

        return SireneEstablishment(
            siret: siret,
            siren: siren,
            legalName: legal,
            enseigne: enseigne,
            nafCode: siege?.activitePrincipale ?? activitePrincipale,
            address: siege?.adresse,
            postalCode: siege?.codePostal,
            city: siege?.libelleCommune,
            coordinates: coords,
            createdAt: createdAt,
            isActive: etatAdministratif == "A"
        )
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first = first else { return self }
        return first.uppercased() + dropFirst()
    }
}
