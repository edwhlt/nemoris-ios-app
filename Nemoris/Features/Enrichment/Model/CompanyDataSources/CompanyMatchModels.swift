import Foundation

// Entreprise et établissements, indépendamment du registre qui les a fournis.
//
// POURQUOI CES TYPES N'ENTRENT PAS DANS `MerchantEnrichment`
//
// `MerchantEnrichment` est une projection PLATE, à une seule adresse, fusionnable champ par
// champ. C'est toute la sémantique de `EnrichmentOrchestrator.merge()` (argmax de
// `confidence × poids` pour CHAQUE champ) — un argmax sur un tableau d'établissements ne
// veut rien dire. C'est aussi le payload de `enrichment_cache.json`, une entrée par
// libellé : y imbriquer 20 branches gonflerait un cache qui n'a ni TTL ni éviction.
//
// La liste d'établissements n'a d'intérêt que pendant la session interactive, le temps que
// l'utilisateur choisisse la bonne boutique. Elle vit donc dans `MerchantSearchResult`,
// jamais en cache long terme.

/// Un établissement : une adresse physique rattachée à une personne morale.
struct Establishment: Hashable, Sendable, Identifiable {
    /// SIRET en France, identifiant local du fournisseur ailleurs.
    let id: String
    let address: String?
    let postalCode: String?
    let city: String?
    let enseignes: [String]
    let nomCommercial: String?
    let isHeadquarters: Bool
    let isFormerHeadquarters: Bool
    let isActive: Bool
    let nafCode: String?
    let latitude: Double?
    let longitude: Double?

    /// Nom le plus parlant : l'enseigne commerciale prime sur tout.
    var displayName: String? {
        enseignes.first(where: { !$0.isEmpty }) ?? nomCommercial
    }

    /// Tous les noms sous lesquels cet établissement peut matcher.
    var searchableNames: [String] {
        var names = enseignes.filter { !$0.isEmpty }
        if let nc = nomCommercial, !nc.isEmpty { names.append(nc) }
        return names
    }

    /// Ligne d'adresse compacte pour l'UI.
    var addressLine: String? {
        let parts = [address, [postalCode, city].compactMap { $0 }.joined(separator: " ")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Une personne morale et les établissements qui matchent la recherche.
struct CompanyMatch: Hashable, Sendable, Identifiable {
    let providerId: String        // "sirene_fr"
    let siren: String
    let legalName: String
    let nomComplet: String?
    let nafCode: String?
    let isActive: Bool
    let creationDate: Date?
    /// Nombre TOTAL d'établissements de l'entreprise, tous non retournés.
    let establishmentCount: Int?
    let openEstablishmentCount: Int?
    let headquarters: Establishment?
    /// ⚠️ Uniquement les établissements qui MATCHENT la requête, pas tous ceux de
    /// l'entreprise. L'UI doit le dire ainsi (« établissements correspondant au nom
    /// recherché ») : laisser croire à une liste exhaustive serait mensonger.
    let establishments: [Establishment]

    var id: String { siren }

    var searchableNames: [String] {
        var names = [legalName]
        if let n = nomComplet, !n.isEmpty, n != legalName { names.append(n) }
        names.append(contentsOf: establishments.flatMap(\.searchableNames))
        if let hq = headquarters { names.append(contentsOf: hq.searchableNames) }
        return names.filter { !$0.isEmpty }
    }

    /// Vrai si la requête a matché une ENSEIGNE et non la raison sociale. C'est le cas
    /// courant des franchises : « CARREFOUR MARKET » est l'enseigne, la personne morale
    /// s'appelle « CSF » ou « OULLIDIS ». Vérifié à l'API : `q=carrefour market` fait
    /// remonter l'entité légale LIDL parce qu'un de ses établissements porte cette enseigne.
    func matchedViaEnseigne(query: [String]) -> Bool {
        let legalScore = MerchantTokenSimilarity.bestScore(
            query: query, against: [legalName, nomComplet].compactMap { $0 }
        )
        let enseigneNames = establishments.flatMap(\.searchableNames)
            + (headquarters?.searchableNames ?? [])
        guard !enseigneNames.isEmpty else { return false }
        let enseigneScore = MerchantTokenSimilarity.bestScore(query: query, against: enseigneNames)
        return enseigneScore > legalScore
    }

    /// Tous les établissements dignes d'être montrés : ceux qui matchent, plus le siège
    /// s'il n'y figure pas déjà (il porte souvent la seule adresse connue).
    var allEstablishments: [Establishment] {
        var out = establishments
        if let hq = headquarters, !out.contains(where: { $0.id == hq.id }) {
            out.append(hq)
        }
        return out
    }
}

// MARK: - Projection vers le modèle plat d'enrichissement

extension CompanyMatch {

    /// Projette cette entreprise et l'établissement retenu vers `MerchantEnrichment`.
    ///
    /// ⚠️ CHEMIN UNIQUE de conversion, partagé par l'orchestrateur (import batch) et par
    /// l'UI (choix manuel dans la liste). Les dupliquer les ferait diverger : c'est
    /// exactement la classe de bug que `EnvelopeSpendingCalculator` a servi à éteindre
    /// ailleurs dans le projet.
    ///
    /// `establishment` est le point clé du drill-down : le siège d'une enseigne est souvent
    /// à l'autre bout du pays alors que le commerce facturé est une branche. On prend donc
    /// l'adresse de l'établissement retenu, jamais celle du siège par défaut.
    func enrichment(for establishment: Establishment?,
                    confidence: Double,
                    fallbackCity: String? = nil,
                    resolveCategory: (String) -> Int? = { _ in nil }) -> MerchantEnrichment {
        let name = establishment?.displayName ?? legalName
        let naf = establishment?.nafCode ?? nafCode

        var result = MerchantEnrichment(
            displayName: name.titleCased,
            domain: nil,
            categoryId: naf.flatMap(resolveCategory),
            address: establishment?.address,
            city: establishment?.city ?? fallbackCity,
            country: "FR",
            latitude: establishment?.latitude,
            longitude: establishment?.longitude,
            phone: nil,
            siret: establishment?.id,
            nafCode: naf,
            source: .sirene,
            confidence: min(1, max(0, confidence)),
            enrichedAt: Date()
        )
        result.siren = siren
        result.postalCode = establishment?.postalCode
        return result
    }
}

extension RankedCompany {
    /// Variante pour le meilleur établissement — le score du classement EST la confiance,
    /// puisqu'il agrège similarité de nom, correspondance géographique, activité et siège.
    func enrichment(fallbackCity: String? = nil,
                    resolveCategory: (String) -> Int? = { _ in nil }) -> MerchantEnrichment {
        match.enrichment(for: bestEstablishment, confidence: score,
                         fallbackCity: fallbackCity, resolveCategory: resolveCategory)
    }
}

// MARK: - Adaptation vers les types purs du classement

extension Establishment {
    /// Projette vers le candidat agnostique attendu par `CandidateRanker`.
    ///
    /// ⚠️ `companyNames` n'est PAS optionnel dans les faits : la plupart des petites
    /// entreprises n'ont aucune enseigne déclarée (`liste_enseignes` vide), donc
    /// `searchableNames` est vide et l'établissement n'aurait AUCUN nom à comparer —
    /// score de similarité 0, quel que soit le libellé. Bug observé en conditions
    /// réelles : « CB SROM FLANCHES » classait « COMMUNE DE POMMEVIC » devant « SROM »,
    /// les deux étant à 0 sur le nom et départagés par leur seul identifiant.
    /// La raison sociale de l'entreprise est donc toujours jointe.
    func rankable(providerWeight: Double,
                  matchedViaEnseigne: Bool,
                  companyNames: [String] = []) -> RankableCandidate {
        RankableCandidate(
            id: id,
            names: searchableNames + companyNames,
            addressLine: address,
            postalCode: postalCode,
            cityLabel: city,
            inseeCode: nil,   // l'API renvoie le code commune INSEE dans `commune`
            isHeadquarters: isHeadquarters,
            isActive: isActive,
            nafCode: nafCode,
            hasCoordinates: latitude != nil && longitude != nil,
            providerWeight: providerWeight,
            matchedViaEnseigne: matchedViaEnseigne
        )
    }
}
