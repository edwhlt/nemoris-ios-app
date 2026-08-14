import Foundation
import Testing
@testable import Nemoris

/// Planification des requêtes au registre des entreprises.
///
/// La règle cardinale, mesurée sur l'API réelle : « carrefour market
/// flanches » rend 0 résultat quand « carrefour market » en rend 1411. Un nom
/// de lieu dans le terme cherché ne restreint pas la recherche — il la fait
/// échouer. La localité doit être un FILTRE, jamais un mot du terme.
@Suite("Planificateur de requêtes marchandes")
struct MerchantQueryPlannerEngineTests {

    // Ces aides conservent la localisation de l'appelant : sans le paramètre
    // de source, tout échec pointerait ici au lieu du test concerné.
    private func expect(_ condition: Bool, _ label: String, _ detail: String = "",
                        sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(condition, "\(label)\(detail.isEmpty ? "" : " — \(detail)")",
                sourceLocation: sourceLocation)
    }

    private func expectEqual(_ lhs: String, _ rhs: String, _ label: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        expect(lhs == rhs, label, "attendu « \(rhs) », obtenu « \(lhs) »",
               sourceLocation: sourceLocation)
    }

    private func expectEqual(_ lhs: Int, _ rhs: Int, _ label: String,
                             sourceLocation: SourceLocation = #_sourceLocation) {
        expect(lhs == rhs, label, "attendu \(rhs), obtenu \(lhs)",
               sourceLocation: sourceLocation)
    }


    // Tests unitaires de la planification de requêtes marchand (AXE S) — compile les fichiers
    // RÉELS du module `Nemoris/Enrichment/QueryPlanning/`.
    //
    // RÉGRESSION PRINCIPALE VERROUILLÉE ICI (t1) : le libellé bancaire entier partait dans le
    // `q=` de recherche-entreprises.api.gouv.fr. Or cette API matche `q` contre la raison
    // sociale et les enseignes, JAMAIS contre l'adresse. Mesuré sur l'API réelle :
    //
    //     q=carrefour market flanches  →  0 résultat
    //     q=carrefour market           →  1907 résultats
    //     q=srom                       →  13 résultats, dont SROM · 69370 Saint-Didier-au-Mont-d'Or
    //
    // La localité doit donc devenir un FILTRE ou un SIGNAL DE TRI, jamais un mot de la requête.
    //
    // t2 verrouille la seconde découverte : 91 % des libellés « PAIEMENT » du corpus réel
    // suivent un gabarit à champs fixes où la localité est AVANT le marchand et TRONQUÉE à
    // ~13 caractères — deux choses que le tag de ville du moteur (position finale, set fermé
    // de 153 communes, correspondance exacte) ne peut structurellement pas voir.

    // MARK: - Aides de construction

    /// Construit une entrée à partir d'un libellé brut, sans sortie moteur (le planificateur
    /// retombe alors sur sa tokenisation interne — c'est le cas nominal quand le moteur ONNX
    /// est encore en cours de démarrage).
    private func input(_ label: String,
               userCountry: String? = nil,
               userPostalCode: String? = nil,
               userQuery: String? = nil,
               refinement: LLMQueryRefinement? = nil) -> MerchantQueryPlanner.Input {
        MerchantQueryPlanner.Input(
            rawLabel: label,
            userCountry: userCountry,
            userPostalCode: userPostalCode,
            userQueryOverride: userQuery,
            refinement: refinement
        )
    }

    private func locality(_ name: String,
                  insee: String? = nil,
                  cp: [String] = [],
                  dep: String? = nil,
                  lat: Double? = nil,
                  lon: Double? = nil) -> ResolvedLocality {
        ResolvedLocality(
            displayName: name, inseeCode: insee, postalCodes: cp, departmentCode: dep,
            countryCode: "FR", latitude: lat, longitude: lon, population: nil, source: .geoAPI
        )
    }

    /// Tous les `q=` des tentatives registre d'un plan.
    private func registryQueries(_ plan: MerchantQueryPlan) -> [String] {
        plan.attempts.compactMap {
            if case .companyRegistry(let q) = $0.kind { return q.q }
            return nil
        }
    }

    private func registryAttempts(_ plan: MerchantQueryPlan) -> [CompanyRegistryQuery] {
        plan.attempts.compactMap {
            if case .companyRegistry(let q) = $0.kind { return q }
            return nil
        }
    }

    /// Aucune tentative ne doit contenir `needle` dans son `q=`.
    private func noAttemptMentions(_ plan: MerchantQueryPlan, _ needle: String) -> Bool {
        registryQueries(plan).allSatisfy { !$0.contains(needle) }
    }

    private func candidate(_ id: String,
                   names: [String],
                   address: String? = nil,
                   cp: String? = nil,
                   city: String? = nil,
                   insee: String? = nil,
                   siege: Bool = false,
                   active: Bool = true,
                   naf: String? = nil,
                   weight: Double = 1.0,
                   viaEnseigne: Bool = false) -> RankableCandidate {
        RankableCandidate(
            id: id, names: names, addressLine: address, postalCode: cp, cityLabel: city,
            inseeCode: insee, isHeadquarters: siege, isActive: active, nafCode: naf,
            hasCoordinates: false, providerWeight: weight, matchedViaEnseigne: viaEnseigne
        )
    }

    /// Générateur congruentiel linéaire à graine — mélange reproductible pour t10.
    struct SeededRandom: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }


    // MARK: - t1 · La ville ne finit JAMAIS dans q= (le bug d'origine)

    @Test("La ville ne finit jamais dans le q= du registre")
    func t1() {
        let plan = MerchantQueryPlanner.plan(input("CB SROM FLANCHES"))
        expectEqual(plan.extraction.nameQuery, "srom", "« CB SROM FLANCHES » → q = srom")
        expect(plan.extraction.localityTokens.contains { $0.raw == "flanches" && $0.kind == .cityName },
               "« flanches » est reconnu comme un lieu")
        expect(noAttemptMentions(plan, "flanches"),
               "aucune tentative ne contient « flanches » dans q=")
        expect(!plan.attempts.isEmpty, "le plan produit au moins une tentative")

        // Localité NON résolue (geo.api.gouv.fr ne connaît pas « Flanches ») : la première
        // tentative doit être le q= NU, sans aucun filtre géo inventé.
        let first = registryAttempts(plan).first
        expect(first != nil && !first!.hasGeoFilter,
               "sans commune résolue, la 1re tentative registre est le q= nu")
        expectEqual(plan.attempts.first?.kind.shortName ?? "", "registry_bare_q",
                    "1re tentative = registry_bare_q")
        expectEqual(plan.ranking.freeLocalityText ?? "", "flanches",
                    "« flanches » survit comme texte de tri sur les adresses")

        // Même règle avec une enseigne multi-mots.
        let plan2 = MerchantQueryPlanner.plan(input("CARREFOUR MARKET FLANCHES"))
        expectEqual(plan2.extraction.nameQuery, "carrefour market",
                    "« CARREFOUR MARKET FLANCHES » → q = carrefour market")
        expect(noAttemptMentions(plan2, "flanches"), "q= ne contient pas la ville (enseigne multi-mots)")

        // Et avec la commune résolue, la ville devient un FILTRE, jamais un mot de q=.
        let plan3 = MerchantQueryPlanner.plan(
            input("CB SROM FLANCHES"),
            locality: locality("Saint-Didier-au-Mont-d'Or", insee: "69194", cp: ["69370"], dep: "69")
        )
        expect(noAttemptMentions(plan3, "flanches"), "avec commune résolue, q= reste propre")
        expect(registryAttempts(plan3).contains { $0.codeCommune == "69194" },
               "la commune devient un filtre code_commune")
        expect(registryAttempts(plan3).allSatisfy { $0.q == "srom" },
               "toutes les tentatives registre gardent le même q= propre")
        expect(plan3.ranking.freeLocalityText == nil,
               "commune résolue ⇒ plus besoin du texte libre de localité")
        expect(plan.cacheKey != "", "le plan expose une clé de cache non vide")
        expect(plan.extraction.droppedTokens.contains { $0.reason == .locality },
               "le retrait de la ville est tracé dans droppedTokens (puce « Retiré du nom »)")
    }

    // MARK: - t2 · Gabarit bancaire à champs fixes (la découverte du corpus réel)

    @Test("Gabarit à champs fixes : localité EN TÊTE et tronquée")
    func t2() {
        // Cas nominal : PAIEMENT PSC DDMM <VILLE tronquée> <MARCHAND> CARTE NNNN GIR<id>
        let plan = MerchantQueryPlanner.plan(
            input("PAIEMENT PSC 1803 MONT SUR LOIR SC-X2M VERNON CARTE 1042 GIR012607803713662")
        )
        expectEqual(plan.extraction.templateId ?? "", "card_payment_fixed_field",
                    "le gabarit carte à champs fixes est reconnu")
        expectEqual(plan.extraction.primaryLocalityText ?? "", "mont sur loir",
                    "la localité tronquée est extraite EN TÊTE du créneau")
        expectEqual(plan.extraction.nameQuery, "sc x2m vernon", "le marchand suit la localité")
        expect(noAttemptMentions(plan, "gif"), "q= ne contient pas la ville")
        expect(plan.extraction.droppedTokens.contains { $0.value == "carte" && $0.reason == .cardMarker },
               "« CARTE » est retiré comme marqueur de carte")
        expect(plan.extraction.droppedTokens.contains { $0.reason == .transactionId },
               "l'identifiant GIR… est retiré")
        expect(plan.extraction.droppedTokens.contains { $0.value == "1803" && $0.reason == .date },
               "la date DDMM est retirée")
        expectEqual(plan.extraction.countryHint ?? "", "FR", "gabarit FR ⇒ pays FR")

        // Préfixe département explicite : « 35 RENNES » → filtre gratuit.
        let plan2 = MerchantQueryPlanner.plan(
            input("PAIEMENT PSC 1903 35 RENNES SELF2 EIFFEL CARTE 1042")
        )
        expectEqual(plan2.extraction.departmentHint ?? "", "35",
                    "le préfixe « 35 » est reconnu comme département")
        expect(!plan2.extraction.nameQuery.contains("35"), "le département ne reste pas dans q=")
        expect(registryAttempts(plan2).contains { $0.departement == "35" },
               "le département devient un filtre departement=")
        expect(plan2.extraction.nameQuery.contains("self2") || plan2.extraction.nameQuery.contains("eiffel"),
               "le marchand est conservé")

        // Paiement web : PAYLI dans le créneau localité ⇒ aucun filtre géographique.
        let plan3 = MerchantQueryPlanner.plan(
            input("PAIEMENT CB 2503 PAYLI2469 AMAZON PRIME FR PAYWEB1042 GIR012608403558190")
        )
        expect(plan3.extraction.isOnlinePayment, "PAYLI/PAYWEB ⇒ paiement en ligne")
        expect(plan3.extraction.droppedTokens.contains { $0.value.hasPrefix("payli") },
               "PAYLI2469 est retiré (référence, pas une ville)")
        expect(plan3.extraction.localityTokens.allSatisfy { $0.kind != .cityName },
               "un paiement web n'a pas de localité physique")
        expect(registryAttempts(plan3).allSatisfy { !$0.hasGeoFilter },
               "aucune tentative registre ne porte de filtre géo")
        expect(!plan3.attempts.contains { $0.kind.shortName == "registry_near_point" },
               "pas de recherche par proximité pour un paiement web")
        expect(plan3.extraction.nameQuery.contains("amazon"), "le marchand Amazon est conservé")

        // Terminateur « PAYWEB1042 » collé (variante observée dans le corpus).
        let plan4 = MerchantQueryPlanner.plan(
            input("PAIEMENT CB 0904 CORK APPLE COM/BILL PAYWEB1042 GIR012610000095685")
        )
        expect(plan4.extraction.nameQuery.contains("apple"), "« APPLE » est reconnu malgré la troncature")
        expect(!plan4.extraction.nameQuery.contains("payweb"), "PAYWEB1042 collé est retiré")

        // Repli n-gram quand aucun gabarit ne s'applique.
        let plan5 = MerchantQueryPlanner.plan(input("TCL 69 LYO"))
        expect(plan5.extraction.templateId == nil, "aucun gabarit ⇒ repli heuristique")
        expect(!plan5.extraction.nameQuery.isEmpty, "le repli produit tout de même un nom")

        // Un libellé « PAIEMENT » ne doit jamais produire un q= vide.
        let plan6 = MerchantQueryPlanner.plan(input("PAIEMENT PSC 1609 OULLINS ELKAN CARTE 1042"))
        expectEqual(plan6.extraction.nameQuery, "elkan", "un seul token marchand est préservé")
        expectEqual(plan6.extraction.primaryLocalityText ?? "", "oullins", "la ville est bien isolée")
    }

    // MARK: - t3 · Cascade avec commune résolue

    @Test("Cascade ordonnée quand la commune est résolue")
    func t3() {
        let extraction = MerchantQueryPlanner.extract(
            input("PAIEMENT PSC 1803 MONT SUR LOIR OCT TRADITION CARTE 1042")
        )
        let gif = locality("Gif-sur-Yvette", insee: "91272", cp: ["91190"], dep: "91",
                           lat: 48.6959, lon: 2.1329)
        let plan = MerchantQueryPlanner.plan(extraction: extraction, locality: gif,
                                             options: .interactive)
        let names = plan.attempts.map(\.kind.shortName)

        expectEqual(names.first ?? "", "registry_commune", "1 · filtre commune INSEE")
        expect(names.count >= 4, "au moins 4 tentatives planifiées")
        expectEqual(names[1], "registry_postal", "2 · filtre code postal")
        expectEqual(names[2], "registry_departement", "3 · filtre département")
        expectEqual(names[3], "registry_bare_q", "4 · nom nu (le correctif)")

        let queries = registryAttempts(plan)
        expect(queries.allSatisfy { $0.q == extraction.nameQuery },
               "toutes les tentatives registre partagent le même q= propre")
        expect(queries.allSatisfy { $0.limiteMatchingEtablissements == 20 },
               "limite_matching_etablissements = 20 en interactif")
        expect(queries.allSatisfy { $0.perPage == 10 }, "per_page = 10")
        expect(queries.allSatisfy { $0.etatAdministratif == "A" || $0.etatAdministratif == nil },
               "etat_administratif = A sauf sur le rejeu final")
        expectEqual(queries[0].codeCommune ?? "", "91272", "code_commune = 91272")
        expectEqual(queries[1].codePostal ?? "", "91190", "code_postal = 91190")
        expectEqual(queries[2].departement ?? "", "91", "departement = 91")
        expect(queries[0].canonicalKey == queries[0].canonicalKey,
               "la clé canonique est stable")
        expect(queries[0].canonicalKey != queries[3].canonicalKey,
               "deux requêtes différentes ont deux clés de cache différentes")

        // Les identifiants de tentative sont des ordinaux 1-based contigus.
        expect(plan.attempts.enumerated().allSatisfy { $0.offset + 1 == $0.element.id },
               "les id de tentative sont des ordinaux 1-based contigus")
        expect(plan.attempts.allSatisfy { !$0.rationale.isEmpty },
               "chaque tentative porte une justification affichable")
    }

    // MARK: - t4 · Code postal collé au nom

    @Test("Le code postal est extrait du nom, jamais laissé dans q=")
    func t4() {
        // NormalizerPipeline.isPureNumericNoise ne jette un token numérique que s'il fait
        // ≤ 4 caractères ET est en dernier → un code postal à 5 chiffres survit toujours.
        let plan = MerchantQueryPlanner.plan(input("CB CARREFOUR MARKET 75011 PARIS"))
        expect(!plan.extraction.nameQuery.contains("75011"), "75011 ne reste pas dans le nom")
        expectEqual(plan.extraction.postalCodeToken ?? "", "75011", "75011 devient un token de localité")
        expectEqual(plan.extraction.countryHint ?? "", "FR", "un code postal à 5 chiffres implique FR")
        expect(registryAttempts(plan).contains { $0.codePostal == "75011" },
               "le code postal devient un filtre code_postal")
        expect(noAttemptMentions(plan, "75011"), "aucune tentative ne met 75011 dans q=")
        expect(plan.extraction.droppedTokens.contains { $0.reason == .postalCode },
               "le retrait du code postal est tracé")
        expect(plan.extraction.nameQuery.contains("carrefour"), "le nom de l'enseigne survit")

        // Négatif : 5 chiffres dans un libellé étranger ne doivent PAS produire de filtre FR.
        let vn = MerchantQueryPlanner.plan(input("VNPAY HUNG RES 12345 HA GIANG"))
        expectEqual(vn.extraction.countryHint ?? "", "VN", "la ville vietnamienne impose VN")
        expect(!registryAttempts(vn).contains { $0.codePostal != nil },
               "pas de filtre code_postal hors de France")
        expect(registryAttempts(vn).isEmpty, "aucune requête registre hors de France")

        // Le code postal saisi par l'utilisateur prime.
        let user = MerchantQueryPlanner.plan(input("BOULANGERIE MARIE", userPostalCode: "69002"))
        expect(registryAttempts(user).contains { $0.codePostal == "69002" },
               "le code postal du formulaire est utilisé comme filtre")

        // Un code postal invalide côté formulaire est ignoré.
        let bad = MerchantQueryPlanner.plan(input("BOULANGERIE MARIE", userPostalCode: "69"))
        expect(!registryAttempts(bad).contains { $0.codePostal != nil },
               "un code postal mal formé est ignoré")
    }

    // MARK: - t5 · Communes multi-mots et tronquées

    @Test("Communes multi-mots, particules toponymiques, troncature")
    func t5() {
        let aix = MerchantQueryPlanner.plan(input("BOULANGERIE MARTIN AIX EN PROVENCE"))
        expect(aix.extraction.primaryLocalityText?.contains("aix") == true,
               "« aix en provence » est saisi comme un bloc")
        expect(aix.extraction.primaryLocalityText?.contains("provence") == true,
               "la particule « en » n'a pas coupé le nom de commune")
        expect(aix.extraction.nameQuery.contains("boulangerie"), "le nom du commerce survit")
        expect(noAttemptMentions(aix, "provence"), "la commune ne part pas dans q=")

        let stDidier = MerchantQueryPlanner.plan(input("SROM SAINT DIDIER AU MONT D OR"))
        expect(stDidier.extraction.primaryLocalityText?.contains("saint") == true,
               "le n-gram grandit vers la gauche jusqu'à « saint »")
        expectEqual(stDidier.extraction.nameQuery, "srom", "il reste toujours un nom exploitable")

        // Un seul token : c'est le NOM, pas une ville. Miroir de la règle
        // promote-geo-back-to-merchant du moteur — sans quoi q= serait vide.
        let parisOnly = MerchantQueryPlanner.plan(input("PARIS"))
        expectEqual(parisOnly.extraction.nameQuery, "paris", "« PARIS » seul reste le nom")
        expect(parisOnly.extraction.primaryLocalityText == nil,
               "aucune localité extraite d'un libellé à un seul token")

        // Troncature en largeur fixe : le fragment doit être conservé tel quel pour l'oracle,
        // qui sait résoudre « ISSY LES » → Issy-les-Moulineaux (vérifié à l'API).
        let issy = MerchantQueryPlanner.plan(
            input("PAIEMENT CB 2503 ISSY LES CANAL PLUS FR PAYWEB1042")
        )
        expect(issy.extraction.isOnlinePayment, "PAYWEB ⇒ paiement en ligne")
        expect(issy.extraction.nameQuery.contains("canal"), "« CANAL PLUS » est conservé")

        let cormeilles = MerchantQueryPlanner.plan(
            input("PAIEMENT PSC 1903 CORMEILLES EN IVS FRANCE CARTE 1042")
        )
        expect(cormeilles.extraction.primaryLocalityText?.contains("cormeilles") == true,
               "« CORMEILLES EN » tronqué est bien traité comme une localité")
        expect(!cormeilles.extraction.nameQuery.contains("cormeilles"),
               "la localité tronquée ne reste pas dans le nom")
        expect(!cormeilles.extraction.nameQuery.isEmpty, "un nom subsiste")

        // Le nom ne doit jamais être entièrement mangé par la localité.
        for label in ["PAIEMENT PSC 1703 NIMES AUCHAN NIMES CARTE 1042",
                      "PAIEMENT PSC 1001 LYON CITADIUM LYON CARTE 1042"] {
            let p = MerchantQueryPlanner.plan(input(label))
            expect(!p.extraction.nameQuery.isEmpty, "« \(label) » garde un nom non vide")
        }
    }

    // MARK: - t6 · Libellés étrangers

    @Test("Libellés étrangers : aucune requête au registre français")
    func t6() {
        let grab = MerchantQueryPlanner.plan(input("Grab A 98C6OCFG VN HA NOI"))
        expectEqual(grab.extraction.countryHint ?? "", "VN", "« HA NOI » impose le pays VN")
        expect(grab.extraction.primaryLocalityText?.contains("ha noi") == true, "la ville est Ha Noi")
        expect(grab.extraction.nameQuery.contains("grab"), "le marchand Grab est conservé")
        expect(registryAttempts(grab).isEmpty,
               "ZÉRO tentative registre : Sirene ne connaît pas les commerces vietnamiens")
        expect(grab.attempts.contains { $0.kind.shortName == "place_text" },
               "seule la recherche cartographique est planifiée")

        let vnpay = MerchantQueryPlanner.plan(input("VNPAY HUNG RES PSC VN P HA GIANG"))
        expectEqual(vnpay.extraction.processorId ?? "", "vnpay", "VNPAY est reconnu comme processeur")
        expectEqual(vnpay.extraction.countryHint ?? "", "VN", "pays VN")
        expect(vnpay.extraction.primaryLocalityText?.contains("ha giang") == true, "ville Ha Giang")
        expect(!vnpay.extraction.nameQuery.contains("vnpay"), "le processeur ne reste pas dans le nom")
        expect(!vnpay.extraction.nameQuery.contains("psc"), "le code de référence PSC est retiré")
        expect(registryAttempts(vnpay).isEmpty, "aucune requête registre")

        // Les abréviations sont développées pour la recherche cartographique.
        let expanded = AbbreviationTable.expand(["hung", "res"])
        expect(expanded.contains("restaurant"), "« RES » est développé en « restaurant »")
        let nhaHang = AbbreviationTable.expand(["nha", "hang", "rau", "m"])
        expect(nhaHang.contains("restaurant"), "« NHA HANG » multi-mots est développé")

        let paypal = MerchantQueryPlanner.plan(input("PAYPAL *NETFLIX 4007 CA"))
        expect(paypal.extraction.nameQuery.contains("netflix"), "« NETFLIX » est isolé")
        expect(!paypal.extraction.nameQuery.contains("paypal"), "PAYPAL est retiré")
        expectEqual(paypal.extraction.processorId ?? "", "paypal", "PAYPAL est le processeur")

        // Un code pays de 2 lettres en tête ne doit jamais être pris pour un pays.
        let cb = MerchantQueryPlanner.plan(input("CB CARREFOUR"))
        expect(cb.extraction.countryHint == nil || cb.extraction.countryHint == "FR",
               "« CB » en tête n'est pas interprété comme un code pays")
        expect(cb.extraction.nameQuery.contains("carrefour"), "le nom survit")
    }

    // MARK: - t7 · Préfixes bancaires et personnes physiques

    @Test("Bruit bancaire retiré, particuliers jamais envoyés au registre")
    func t7() {
        let sumup = MerchantQueryPlanner.plan(input("SUMUP*BOULANG MARIE LYON"))
        expectEqual(sumup.extraction.processorId ?? "", "sumup", "SUMUP est le processeur")
        expect(!sumup.extraction.nameQuery.contains("sumup"), "SUMUP ne reste pas dans le nom")
        expect(sumup.extraction.nameQuery.contains("boulang"), "« BOULANG MARIE » est conservé")

        let prlv = MerchantQueryPlanner.plan(input("PRLV SEPA WOMBAT JEAN-MACE PRLV ON AIR LYON"))
        expect(!prlv.extraction.nameQuery.hasPrefix("prlv"), "le préfixe PRLV est retiré")
        expect(!prlv.extraction.nameQuery.isEmpty, "un nom subsiste")

        // Virements nominatifs → JAMAIS de requête à un registre d'entreprises.
        for label in ["VIR DE M DIDIER HELET CG3V25344L068242",
                      "VIR INST WERO M NATHAN LAURENT WERO DB7E79E3B27D4097",
                      "VIR SEPA RECU M DUPONT"] {
            let p = MerchantQueryPlanner.plan(input(label))
            expect(p.extraction.isPersonNotBusiness, "« \(label.prefix(24))… » = personne physique")
            expect(p.attempts.isEmpty, "aucune tentative pour un particulier")
        }

        // Contre-exemple : un virement vers une opération interne n'est PAS une personne.
        let livret = MerchantQueryPlanner.plan(input("VIR LIVRET JEUNE CG3W26063M200769"))
        expect(!livret.extraction.isPersonNotBusiness,
               "« VIR LIVRET JEUNE » n'est pas un virement nominatif")
        let caf = MerchantQueryPlanner.plan(input("VIR ORG DE L MAYENNE 8064731HHELET 042026ME"))
        expect(!caf.extraction.isPersonNotBusiness, "« VIR ORG DE L MAYENNE » n'est pas un particulier")
        let epargne = MerchantQueryPlanner.plan(input("VIR EPARGNE SAL R-035426630"))
        expect(!epargne.extraction.isPersonNotBusiness, "« VIR EPARGNE SAL » n'est pas un particulier")
        expect(epargne.extraction.nameQuery.contains("epargne"), "« EPARGNE » est conservé")
    }

    // MARK: - t8 · Enseigne contre raison sociale

    @Test("Enseigne, raison sociale, nom raccourci")
    func t8() {
        let plan = MerchantQueryPlanner.plan(
            input("CARREFOUR MARKET FLANCHES"),
            locality: locality("Roanne", insee: "42187", cp: ["42300"], dep: "42")
        )
        expect(registryQueries(plan).contains("carrefour market"),
               "la marque multi-mots reste entière dans q=")
        // Le nom raccourci existe mais arrive APRÈS le nom complet.
        let queries = registryQueries(plan)
        if let fullIndex = queries.firstIndex(of: "carrefour market"),
           let shortIndex = queries.firstIndex(of: "carrefour") {
            expect(fullIndex < shortIndex, "le nom raccourci est tenté après le nom complet")
        } else {
            // À deux mots seulement, aucun raccourcissement n'est nécessaire.
            expect(queries.contains("carrefour market"), "le nom complet est présent")
        }

        // Classement : à localité égale, la raison sociale exacte bat l'enseigne seule.
        let ctx = RankingContext(nameTokens: ["boulangerie", "pralus"], cityLabel: "Roanne")
        let exact = candidate("A", names: ["Boulangerie Pralus"], city: "Roanne")
        let enseigneOnly = candidate("B", names: ["CSF"], city: "Roanne", viaEnseigne: true)
        let ranked = CandidateRanker.rank([enseigneOnly, exact], context: ctx)
        expectEqual(ranked.first?.id ?? "", "A", "la raison sociale exacte gagne")

        // Mais si la raison sociale ne matche pas du tout, l'enseigne l'emporte —
        // c'est le cas LIDL/CARREFOUR MARKET vérifié à l'API.
        let ctx2 = RankingContext(nameTokens: ["carrefour", "market"], cityLabel: "Roanne")
        let unrelated = candidate("A", names: ["Syndicat des copropriétaires"], city: "Roanne")
        let viaEnseigne = candidate("B", names: ["LIDL", "Carrefour Market"], city: "Roanne",
                                    viaEnseigne: true)
        let ranked2 = CandidateRanker.rank([unrelated, viaEnseigne], context: ctx2)
        expectEqual(ranked2.first?.id ?? "", "B", "l'enseigne gagne quand la raison sociale ne dit rien")

        // Troncature en largeur fixe : les relevés coupent les mots (« BOULANG » pour
        // BOULANGERIE, « YVETT » pour YVETTE, « DEFE » pour DÉFENSE). Un token tronqué doit
        // matcher son mot complet par préfixe, sinon toute enseigne coupée serait mal classée.
        let sim = MerchantTokenSimilarity.score(["boulang", "marie"], ["boulangerie", "marie"])
        expect(sim > 0.7, "un mot tronqué matche son mot complet par préfixe (\(String(format: "%.2f", sim)))")
        let sim2 = MerchantTokenSimilarity.score(["gif", "sur", "yvett"], ["gif", "sur", "yvette"])
        expect(sim2 > 0.7, "« yvett » matche « yvette » (\(String(format: "%.2f", sim2)))")
        // Limite assumée : une CONTRACTION n'est pas un préfixe (« phie » ≠ pha…), elle ne
        // matche donc que sur les autres tokens. C'est le rôle du filtre géographique de
        // rattraper ces cas, pas celui de la similarité de noms.
        let contraction = MerchantTokenSimilarity.score(["phie", "nimes"], ["pharmacie", "nimes"])
        expect(contraction >= 0.4 && contraction < 0.7,
               "une contraction ne matche que partiellement (\(String(format: "%.2f", contraction)))")
        let noMatch = MerchantTokenSimilarity.score(["srom"], ["sram"])
        expect(noMatch < 0.3, "deux noms proches en frappe mais distincts ne matchent pas (\(String(format: "%.2f", noMatch)))")
        let unordered = MerchantTokenSimilarity.score(
            ["boulangerie", "pralus"], ["pralus", "la", "boulangerie"]
        )
        expect(unordered > 0.7, "l'ordre des mots n'a pas d'importance (\(String(format: "%.2f", unordered)))")
    }

    // MARK: - t9 · Libellés vides et poubelle

    @Test("Libellés dégénérés : aucun appel réseau")
    func t9() {
        for label in ["", "   ", "***", "0000000", "A", "CB CB CB"] {
            let plan = MerchantQueryPlanner.plan(input(label))
            expect(plan.attempts.isEmpty, "« \(label) » ne produit AUCUNE tentative")
        }
        let garbage = MerchantQueryPlanner.plan(input("***"))
        expect(garbage.extraction.degenerate, "« *** » est marqué dégénéré")

        // Round-trip Codable : le plan doit survivre à la sérialisation (cache, tests corpus).
        let plan = MerchantQueryPlanner.plan(
            input("CB SROM FLANCHES"),
            locality: locality("Roanne", insee: "42187", cp: ["42300"], dep: "42")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(plan),
           let decoded = try? JSONDecoder().decode(MerchantQueryPlan.self, from: data) {
            expect(decoded == plan, "round-trip Codable du plan complet")
            expectEqual(decoded.extraction.nameQuery, plan.extraction.nameQuery,
                        "le nom survit au round-trip")
            expectEqual(decoded.attempts.count, plan.attempts.count,
                        "les tentatives survivent au round-trip")
        } else {
            expect(false, "round-trip Codable du plan complet", "encodage ou décodage échoué")
        }

        // Un libellé fait uniquement de bruit bancaire ne doit rien produire.
        let onlyNoise = MerchantQueryPlanner.plan(input("PAIEMENT CB 1503 CARTE 1042"))
        expect(onlyNoise.attempts.isEmpty || !onlyNoise.extraction.nameQuery.isEmpty,
               "un libellé sans marchand ne produit pas de q= vide")
    }

    // MARK: - t10 · Le ranker est un ordre total déterministe (verrouille results.first)

    @Test("Classement : ordre total, reproductible, indépendant de l'ordre d'entrée")
    func t10() {
        let ctx = RankingContext(
            nameTokens: ["pralus"],
            inseeCode: "69382",
            postalCodes: ["69002"],
            departmentCode: "69",
            cityLabel: "Lyon"
        )
        let pool = [
            candidate("s1", names: ["Pralus Lyon"], cp: "69002", city: "Lyon", insee: "69382", siege: true),
            candidate("s2", names: ["Boulangerie Pralus"], cp: "69002", city: "Lyon", insee: "69382"),
            candidate("s3", names: ["Pralus Roanne"], cp: "42300", city: "Roanne", insee: "42187"),
            candidate("s4", names: ["Pralus Lyon"], cp: "69002", city: "Lyon", insee: "69382", active: false),
            candidate("s5", names: ["Sans rapport"], cp: "69002", city: "Lyon", insee: "69382"),
            candidate("s6", names: ["Pralus Lyon"], cp: "69002", city: "Lyon", insee: "69382")
        ]
        let reference = CandidateRanker.rank(pool, context: ctx).map(\.id)
        var stable = true
        for seed in 1...20 {
            var rng = SeededRandom(seed: UInt64(seed))
            let shuffled = pool.shuffled(using: &rng)
            if CandidateRanker.rank(shuffled, context: ctx).map(\.id) != reference { stable = false }
        }
        expect(stable, "20 mélanges à graine produisent le MÊME classement")
        expectEqual(reference.count, pool.count, "aucun candidat perdu au classement")

        // Hiérarchie des signaux de localité.
        let ctxInsee = RankingContext(nameTokens: ["pralus"], inseeCode: "69382",
                                      postalCodes: ["69002"], departmentCode: "69", cityLabel: "Lyon")
        let good = candidate("g", names: ["Pralus"], cp: "69002", city: "Lyon", insee: "69382")
        let wrongCity = candidate("w", names: ["Pralus"], cp: "42300", city: "Roanne", insee: "42187")
        let rankedGeo = CandidateRanker.rank([wrongCity, good], context: ctxInsee)
        expectEqual(rankedGeo.first?.id ?? "", "g", "le bon code INSEE gagne")
        expect(CandidateRanker.score(good, context: ctxInsee).localityMatch >
               CandidateRanker.score(wrongCity, context: ctxInsee).localityMatch,
               "INSEE correspondant > INSEE différent")

        // Un établissement fermé ne dépasse jamais un ouvert à nom égal.
        let openOne = candidate("open", names: ["Pralus"], cp: "69002", city: "Lyon", insee: "69382")
        let closedOne = candidate("closed", names: ["Pralus"], cp: "69002", city: "Lyon",
                                  insee: "69382", active: false)
        expectEqual(CandidateRanker.rank([closedOne, openOne], context: ctxInsee).first?.id ?? "",
                    "open", "un établissement fermé ne dépasse pas un ouvert")

        // Bris d'égalité par siège, puis par id.
        let hq = candidate("z_hq", names: ["Pralus"], cp: "69002", city: "Lyon", insee: "69382", siege: true)
        let branch = candidate("a_branch", names: ["Pralus"], cp: "69002", city: "Lyon", insee: "69382")
        expectEqual(CandidateRanker.rank([branch, hq], context: ctxInsee).first?.id ?? "",
                    "z_hq", "à score égal, le siège passe devant")

        // Aucune information de lieu ⇒ score de localité NEUTRE (0.5), pas une pénalité.
        let ctxNoGeo = RankingContext(nameTokens: ["pralus"])
        expect(CandidateRanker.score(good, context: ctxNoGeo).localityMatch == 0.5,
               "sans info de lieu, le score de localité est neutre")

        // Localité NON résolue retrouvée dans l'adresse — le cœur du correctif SROM.
        let ctxFree = RankingContext(nameTokens: ["srom"], freeLocalityText: "flanches")
        let atFlanches = candidate("f", names: ["SROM"], address: "12 route de Flanches 69370 Chazay")
        let elsewhere = candidate("e", names: ["SROM"], address: "3 rue de la Fosse 89400 Bassou")
        expect(CandidateRanker.score(atFlanches, context: ctxFree).localityMatch >
               CandidateRanker.score(elsewhere, context: ctxFree).localityMatch,
               "un lieu-dit non résolu retrouvé dans l'adresse fait remonter le bon candidat")
        expectEqual(CandidateRanker.rank([elsewhere, atFlanches], context: ctxFree).first?.id ?? "",
                    "f", "le candidat dont l'adresse cite le lieu-dit gagne")

        // Un candidat SANS aucun nom ne peut rien matcher : son score de nom est 0.
        // C'est la raison pour laquelle l'adaptateur `Establishment.rankable` DOIT joindre la
        // raison sociale de l'entreprise — la plupart des petits commerces n'ont pas d'enseigne
        // déclarée. Sans ça, tous les établissements se retrouvaient à 0 et étaient départagés
        // par leur seul identifiant : « CB SROM FLANCHES » classait « COMMUNE DE POMMEVIC »
        // devant « SROM ». Le câblage lui-même est vérifié par integration/ExecutorLiveCheck.
        let ctxNamed = RankingContext(nameTokens: ["srom"])
        let named = candidate("named", names: ["SROM"])
        let nameless = candidate("aaa_nameless", names: [])
        expect(CandidateRanker.score(nameless, context: ctxNamed).nameSimilarity == 0,
               "un candidat sans nom a une similarité nulle")
        expect(CandidateRanker.score(named, context: ctxNamed).nameSimilarity > 0.9,
               "un candidat au nom exact a une similarité maximale")
        expectEqual(CandidateRanker.rank([nameless, named], context: ctxNamed).first?.id ?? "",
                    "named", "le candidat nommé passe devant, malgré un id supérieur")

        // Le poids du fournisseur module le score final.
        let ctxW = RankingContext(nameTokens: ["pralus"], cityLabel: "Lyon")
        let sirene = candidate("sirene", names: ["Pralus"], city: "Lyon", weight: 1.0)
        let mapkit = candidate("mapkit", names: ["Pralus"], city: "Lyon", weight: 0.7)
        expectEqual(CandidateRanker.rank([mapkit, sirene], context: ctxW).first?.id ?? "",
                    "sirene", "à qualité égale, la source officielle prime")
    }

    // MARK: - t11 · Budget respecté

    @Test("Le budget borne le plan, de façon auditable sans rien exécuter")
    func t11() {
        let gif = locality("Gif-sur-Yvette", insee: "91272", cp: ["91190"], dep: "91",
                           lat: 48.6959, lon: 2.1329)
        let extraction = MerchantQueryPlanner.extract(input("CB OCT TRADITION MONT SUR LOIRE"))

        let batch = MerchantQueryPlanner.plan(extraction: extraction, locality: gif, options: .batch)
        expect(batch.attempts.count <= 2, "batch : au plus 2 tentatives (\(batch.attempts.count))")
        expect(!batch.attempts.contains { $0.kind.shortName == "place_text" },
               "batch : aucune recherche cartographique")
        expect(registryAttempts(batch).allSatisfy { $0.limiteMatchingEtablissements == 10 },
               "batch : limite_matching_etablissements = 10")
        expect(registryAttempts(batch).allSatisfy { $0.etatAdministratif == "A" },
               "batch : jamais d'entreprises fermées")

        let interactive = MerchantQueryPlanner.plan(extraction: extraction, locality: gif,
                                                    options: .interactive)
        expect(interactive.attempts.count <= 6,
               "interactif : au plus 6 tentatives (\(interactive.attempts.count))")
        expect(interactive.attempts.count > batch.attempts.count,
               "l'interactif planifie plus large que le batch")

        // Les budgets sont cohérents entre eux.
        expect(SearchBudget.batch.maxRequests < SearchBudget.interactive.maxRequests,
               "le budget batch est plus serré que l'interactif")
        expect(!SearchBudget.batch.allowLLM, "le batch n'appelle jamais le modèle de langage")
        expect(SearchBudget.deep.maxRequests >= SearchBudget.interactive.maxRequests,
               "la recherche approfondie est la plus permissive")
        expect(SearchBudget.Usage().totalLookups == 0, "une consommation neuve est à zéro")
    }

    // MARK: - t12 · L'IA enrichit, elle ne conditionne jamais (règle iOS 18)

    @Test("Le raffinement IA est additif et ne peut rien détruire")
    func t12() {
        let label = "VNPAY HUNG RES PSC VN P HA GIANG"

        // Sans raffinement : le plan est déjà exploitable (chemin iOS 18).
        let without = MerchantQueryPlanner.plan(input(label))
        expect(!without.attempts.isEmpty, "sans IA, le plan produit tout de même des tentatives")
        expect(!without.extraction.nameQuery.isEmpty, "sans IA, un nom est extrait")

        // Raffinement ADVERSARIAL : ville hallucinée, confiance maximale, nom poubelle.
        let adversarial = LLMQueryRefinement(
            merchantName: "@@@@", localityName: "atlantide", postalCode: "99999",
            countryCode: "ZZ", processorName: "inexistant",
            expandedTokens: [], isPersonNotBusiness: false, confidence: 1.0
        )
        let withBad = MerchantQueryPlanner.plan(input(label, refinement: adversarial))
        expect(withBad.attempts.count >= without.attempts.count,
               "un raffinement halluciné ne RETIRE aucune tentative")
        let withoutNames = Set(without.attempts.map(\.kind.shortName))
        let withBadNames = Set(withBad.attempts.map(\.kind.shortName))
        expect(withoutNames.isSubset(of: withBadNames),
               "toutes les tentatives déterministes subsistent")

        // Un code pays invalide ne doit pas être retenu tel quel.
        expect(withBad.extraction.countryHint != "ZZ" || withBad.attempts.isEmpty,
               "un code pays fantaisiste ne pilote pas la cascade")

        // Raffinement UTILE : il ajoute ce que le déterministe ne savait pas.
        let helpful = LLMQueryRefinement(
            merchantName: "Hung Restaurant", localityName: "ha giang",
            countryCode: "VN", processorName: "vnpay",
            expandedTokens: ["restaurant"], confidence: 0.8
        )
        let withGood = MerchantQueryPlanner.plan(input(label, refinement: helpful))
        expectEqual(withGood.extraction.countryHint ?? "", "VN", "le raffinement confirme le pays")
        expect(registryAttempts(withGood).isEmpty, "toujours aucune requête registre hors FR")

        // La requête saisie par l'utilisateur prime sur tout.
        let override = MerchantQueryPlanner.plan(input(label, userQuery: "Hung Restaurant"))
        expectEqual(override.extraction.nameQuery, "hung restaurant",
                    "la requête tapée par l'utilisateur fait autorité")

        // Mapping @Generable : vide → nil, clamp, majuscules. C'est CE bout-là qui est
        // testable, et c'est là que se logent les vraies erreurs du chemin IA.
        let mapped = GeneratedQueryPlanMapping.map(
            merchantName: "  Boulangerie Marie  ", localityName: "LYON", postalCode: "69002",
            countryCode: "fr", processorName: "SumUp", expandedTokens: ["", "boulangerie", "null"],
            isPersonNotBusiness: false, confidence: 1.7
        )
        expectEqual(mapped.merchantName ?? "", "Boulangerie Marie", "les espaces sont retirés")
        expectEqual(mapped.localityName ?? "", "lyon", "la localité est normalisée en minuscules")
        expectEqual(mapped.countryCode ?? "", "FR", "le code pays est mis en majuscules")
        expect(mapped.confidence == 1.0, "la confiance est bornée à 1")
        expectEqual(mapped.expandedTokens.count, 1, "les jetons vides et « null » sont écartés")

        let empties = GeneratedQueryPlanMapping.map(
            merchantName: "", localityName: "   ", postalCode: "null", countryCode: "",
            processorName: "none", expandedTokens: [], isPersonNotBusiness: true, confidence: -3
        )
        expect(empties.merchantName == nil, "une chaîne vide devient nil")
        expect(empties.localityName == nil, "une chaîne d'espaces devient nil")
        expect(empties.postalCode == nil, "« null » littéral devient nil")
        expect(empties.processorName == nil, "« none » littéral devient nil")
        expect(empties.confidence == 0, "une confiance négative est bornée à 0")
        expect(empties.isPersonNotBusiness, "le drapeau personne physique est conservé")

        // Un code postal mal formé venant du modèle est rejeté avant de devenir un filtre.
        let badPC = GeneratedQueryPlanMapping.map(
            merchantName: "X", localityName: "", postalCode: "7501", countryCode: "",
            processorName: "", expandedTokens: [], isPersonNotBusiness: false, confidence: 0.5
        )
        expect(badPC.postalCode == nil, "un code postal à 4 chiffres est rejeté")

        expect(LLMQueryRefinement.none.isEmpty, "l'élément neutre est bien vide")
    }

    // MARK: - t13 · Sigles épelés, villes répétées, devinettes de localité

    @Test("Sigles recollés, ville répétée retirée, devinettes prudentes")
    func t13() {
        // Les relevés espacent les sigles. `q=c p a m` ne trouve rien, `q=cpam` trouve.
        expectEqual(MerchantQueryPlanner.joinSpelledAcronyms(["c", "p", "a", "m", "troyes"])
                        .joined(separator: " "),
                    "cpam troyes", "« C P A M TROYES » est recollé en « cpam troyes »")
        expectEqual(MerchantQueryPlanner.joinSpelledAcronyms(["b", "b", "hotel"])
                        .joined(separator: " "),
                    "bb hotel", "« B B HOTEL » → « bb hotel »")
        expectEqual(MerchantQueryPlanner.joinSpelledAcronyms(["sas", "sisens"])
                        .joined(separator: " "),
                    "sas sisens", "des mots normaux ne sont pas recollés")
        expectEqual(MerchantQueryPlanner.joinSpelledAcronyms(["e", "leclerc"])
                        .joined(separator: " "),
                    "e leclerc", "une lettre isolée seule n'est pas un sigle")

        let cpam = MerchantQueryPlanner.plan(input("VIR C P A M TROYES 928133150967"))
        expect(!cpam.extraction.isPersonNotBusiness,
               "le « M » d'un sigle épelé n'est pas une civilité")
        expect(cpam.extraction.nameQuery.contains("cpam"), "« cpam » part dans q=")
        expect(!cpam.extraction.nameQuery.contains("928133150967"),
               "la référence numérique longue est retirée")

        // La ville répétée dans l'enseigne doit sortir de q=.
        let auchan = MerchantQueryPlanner.plan(input("PAIEMENT PSC 1703 NIMES AUCHAN NIMES CARTE 1042"))
        expectEqual(auchan.extraction.nameQuery, "auchan", "« NIMES AUCHAN NIMES » → q = auchan")
        expect(noAttemptMentions(auchan, "nimes"), "la ville répétée ne reste pas dans q=")

        let citadium = MerchantQueryPlanner.plan(input("PAIEMENT PSC 1001 LYON CITADIUM LYON CARTE 1042"))
        expectEqual(citadium.extraction.nameQuery, "citadium", "« LYON CITADIUM LYON » → q = citadium")

        // La localité ne mange jamais tout le nom.
        let onlyCity = MerchantQueryPlanner.plan(input("PAIEMENT PSC 1001 LYON LYON CARTE 1042"))
        expect(!onlyCity.extraction.nameQuery.isEmpty,
               "si l'enseigne EST la ville, on garde un q= non vide")

        // La devinette de localité en fin de libellé est prudente : un mot court ou un
        // fragment de domaine n'est pas une commune.
        let appleCom = MerchantQueryPlanner.plan(input("APPLE COM BILL IE ITUNES COM"))
        expect(appleCom.extraction.primaryLocalityText == nil,
               "« com » n'est pas deviné comme une commune")
        let onAir = MerchantQueryPlanner.plan(input("PRLV SEPA ON AIR LYON"))
        expect(onAir.extraction.primaryLocalityText == nil,
               "aucune devinette de lieu sur un prélèvement (pas de point de vente)")

        // Mais une commune composée finissant par un mot court reste reconnue.
        let montDOr = MerchantQueryPlanner.plan(input("SROM SAINT DIDIER AU MONT D OR"))
        expectEqual(montDOr.extraction.nameQuery, "srom",
                    "« …au Mont d'Or » reste une commune malgré le « or » final")

        // Un remboursement entre amis EST un virement nominatif.
        let refund = MerchantQueryPlanner.plan(
            input("VIR INST WERO M ADAM FOURNIER REMBOURSEMENT PHILIPPINES 0823366242924587")
        )
        expect(refund.extraction.isPersonNotBusiness,
               "« REMBOURSEMENT » n'annule pas la détection de personne physique")
        expect(refund.attempts.isEmpty, "aucune requête registre pour ce remboursement P2P")
    }
}
