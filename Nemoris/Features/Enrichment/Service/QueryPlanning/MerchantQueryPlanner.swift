import Foundation

// Le planificateur de requêtes marchand.
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT.
//
// Deux fonctions pures totales :
//   extract(_:)                   → analyse le libellé (nom / localité / bruit)
//   plan(extraction:locality:…)   → cascade ordonnée de tentatives concrètes
//
// Entre les deux, l'exécuteur intercale la résolution asynchrone de la localité. Voir
// `LocalityResolver` pour la justification de ce découpage.
//
// RÈGLE CARDINALE, vérifiée par t1 : la localité ne finit JAMAIS dans `q=`.
// L'API matche `q` contre la raison sociale et les enseignes, jamais contre l'adresse ;
// y mettre la ville ne restreint pas la recherche, il la fait échouer.

enum MerchantQueryPlanner {

    // MARK: - Entrée

    /// Miroir de `NemorisEngine.TokenTag`, recopié par `rawValue`.
    /// Le planificateur ne peut pas importer `NemorisEngine` : c'est un package SwiftPM,
    /// et le harness `swiftc` devrait alors le compiler en entier.
    struct Token: Hashable, Sendable {
        enum Tag: String, Sendable, Hashable {
            case merchant, processor, date, city, country, direction, identifier, noise
        }
        let value: String
        let tag: Tag

        init(_ value: String, _ tag: Tag = .merchant) {
            self.value = value
            self.tag = tag
        }
    }

    struct Input: Hashable, Sendable {
        let rawLabel: String
        /// Sortie de `NormalizerPipeline` — consommée, jamais recalculée.
        var engineMerchantCandidate: String?
        var engineCityCandidate: String?
        var engineCountryCandidate: String?
        var engineProcessorId: String?
        var engineTokens: [Token]
        /// Champs du formulaire : ils PRIMENT sur toute déduction.
        var userCountry: String?
        var userPostalCode: String?
        var userQueryOverride: String?
        /// nil ⇒ chemin déterministe seul, toujours valide.
        var refinement: LLMQueryRefinement?

        init(rawLabel: String,
             engineMerchantCandidate: String? = nil,
             engineCityCandidate: String? = nil,
             engineCountryCandidate: String? = nil,
             engineProcessorId: String? = nil,
             engineTokens: [Token] = [],
             userCountry: String? = nil,
             userPostalCode: String? = nil,
             userQueryOverride: String? = nil,
             refinement: LLMQueryRefinement? = nil) {
            self.rawLabel = rawLabel
            self.engineMerchantCandidate = engineMerchantCandidate
            self.engineCityCandidate = engineCityCandidate
            self.engineCountryCandidate = engineCountryCandidate
            self.engineProcessorId = engineProcessorId
            self.engineTokens = engineTokens
            self.userCountry = userCountry
            self.userPostalCode = userPostalCode
            self.userQueryOverride = userQueryOverride
            self.refinement = refinement
        }
    }

    struct Options: Hashable, Sendable {
        var maxAttempts: Int
        var includeCeased: Bool
        var allowPlaces: Bool
        var matchingLimit: Int
        var perPage: Int = 10

        static let interactive = Options(
            maxAttempts: SearchBudget.interactive.maxAttempts,
            includeCeased: SearchBudget.interactive.includeCeased,
            allowPlaces: SearchBudget.interactive.allowPlaces,
            matchingLimit: SearchBudget.interactive.matchingLimit
        )
        static let batch = Options(
            maxAttempts: SearchBudget.batch.maxAttempts,
            includeCeased: SearchBudget.batch.includeCeased,
            allowPlaces: SearchBudget.batch.allowPlaces,
            matchingLimit: SearchBudget.batch.matchingLimit
        )

        init(maxAttempts: Int, includeCeased: Bool, allowPlaces: Bool, matchingLimit: Int, perPage: Int = 10) {
            self.maxAttempts = maxAttempts
            self.includeCeased = includeCeased
            self.allowPlaces = allowPlaces
            self.matchingLimit = matchingLimit
            self.perPage = perPage
        }
    }

    // MARK: - Extraction

    static func extract(_ input: Input) -> MerchantLabelExtraction {
        // L'utilisateur a tapé sa propre requête : elle fait autorité, on ne redécoupe rien.
        if let override = input.userQueryOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return overrideExtraction(input, override: override)
        }

        let tokens = tokenizeForPlanning(input)
        guard !tokens.isEmpty else { return emptyExtraction(input) }

        let refinement = input.refinement ?? DeterministicQueryRefiner.refine(
            rawLabel: input.rawLabel, tokens: tokens
        )

        // --- 1. Gabarit bancaire à champs fixes (91 % des libellés « PAIEMENT »).
        if let (template, slots) = BankLabelTemplate.match(tokens) {
            return templateExtraction(input, tokens: tokens, template: template,
                                      slots: slots, refinement: refinement)
        }

        // --- 2. Repli heuristique : nettoyage + localité en fin de libellé.
        return heuristicExtraction(input, tokens: tokens, refinement: refinement)
    }

    // MARK: - Plan

    static func plan(extraction: MerchantLabelExtraction,
                     locality: ResolvedLocality?,
                     options: Options = .interactive) -> MerchantQueryPlan {
        let ranking = rankingContext(extraction: extraction, locality: locality)
        let attempts = buildAttempts(extraction: extraction, locality: locality, options: options)
        return MerchantQueryPlan(
            extraction: extraction,
            locality: locality,
            attempts: attempts,
            ranking: ranking
        )
    }

    /// Raccourci : extraction + plan, pour les tests et les appelants sans localité résolue.
    static func plan(_ input: Input,
                     locality: ResolvedLocality? = nil,
                     options: Options = .interactive) -> MerchantQueryPlan {
        plan(extraction: extract(input), locality: locality, options: options)
    }

    // MARK: - Construction des tentatives

    private static func buildAttempts(extraction: MerchantLabelExtraction,
                                      locality: ResolvedLocality?,
                                      options: Options) -> [SearchAttempt] {
        // Aucune tentative pour un particulier : on n'envoie JAMAIS le nom d'une personne
        // physique à un registre d'entreprises. Vie privée, et ça ne donne rien.
        guard !extraction.isPersonNotBusiness else { return [] }
        // Ni pour un libellé dont il ne reste rien d'exploitable : pas de requête réseau
        // pour « *** » ou « A ».
        guard !extraction.degenerate else { return [] }

        let name = extraction.nameQuery
        let country = extraction.countryHint ?? locality?.countryCode
        var attempts: [SearchAttempt] = []

        func add(_ kind: SearchAttemptKind, _ rationale: String, _ precision: Double) {
            guard attempts.count < options.maxAttempts else { return }
            attempts.append(SearchAttempt(id: attempts.count + 1, kind: kind,
                                          rationale: rationale, expectedPrecision: precision))
        }

        func registryQuery(_ q: String,
                           commune: String? = nil,
                           postal: String? = nil,
                           departement: String? = nil,
                           ceased: Bool = false) -> CompanyRegistryQuery {
            CompanyRegistryQuery(
                q: q, codeCommune: commune, codePostal: postal, departement: departement,
                perPage: options.perPage,
                etatAdministratif: ceased ? nil : "A",
                limiteMatchingEtablissements: options.matchingLimit
            )
        }

        // Le registre d'entreprises n'est interrogé que pour la France. Un libellé
        // vietnamien ne produit qu'une recherche cartographique — inutile de dépenser
        // une requête chez Sirene pour un restaurant de Da Nang.
        let isFrench = (country == nil || country == "FR")

        if isFrench {
            // 1 — commune INSEE : le filtre le plus précis.
            if let insee = locality?.inseeCode, !extraction.isOnlinePayment {
                add(.companyRegistry(registryQuery(name, commune: insee)),
                    "nom seul + commune INSEE \(insee)", 0.95)
            }
            // 2 — code postal.
            let postal = extraction.postalCodeToken
                ?? (extraction.isOnlinePayment ? nil : locality?.unambiguousPostalCode)
            if let postal {
                add(.companyRegistry(registryQuery(name, postal: postal)),
                    "nom seul + code postal \(postal)", 0.9)
            }
            // 3 — département.
            if let dep = extraction.departmentHint ?? (extraction.isOnlinePayment ? nil : locality?.departmentCode) {
                add(.companyRegistry(registryQuery(name, departement: dep)),
                    "nom seul + département \(dep)", 0.75)
            }
            // 4 — nom nu. TOUJOURS présent : c'est le correctif du bug d'origine.
            // « q=srom flanches » rendait 0, « q=srom » rend 13 résultats parmi lesquels
            // le classement par proximité du lieu retrouve le bon.
            add(.companyRegistry(registryQuery(name)),
                locality == nil && extraction.primaryLocalityText != nil
                    ? "nom seul, tri par proximité du lieu"
                    : "nom seul",
                0.6)
            // 5 — nom raccourci : les enseignes sont tronquées en largeur fixe dans les
            // relevés (« SC-PHIE MASSY V »), le dernier token est souvent coupé.
            //
            // ⚠️ Pas de tentative « nom + localité » ici, même quand la commune n'est pas
            // résolue et que le fragment est ambigu (« SROM **FLANCHES** » est un lieu-dit
            // mais « FOURNIL **PLIQUE** » est le nom du boulanger). Ce serait rouvrir la
            // porte au bug d'origine. Et c'est inutile : `q=fournil` trouve déjà la
            // boulangerie — le registre matche les noms partiels, et `CandidateRanker`
            // fait remonter « FOURNIL PLIQUE » sur le recouvrement de tokens. La règle
            // cardinale reste absolue : la localité ne va JAMAIS dans `q=`.
            if extraction.nameTokens.count >= 3 {
                let shortened = extraction.nameTokens.dropLast().joined(separator: " ")
                add(.companyRegistry(registryQuery(shortened)), "nom raccourci", 0.45)
            }
            // 6 — proximité géographique, dernier recours si tout le reste est vide.
            if let lat = locality?.latitude, let lon = locality?.longitude,
               !extraction.isOnlinePayment {
                add(.companyRegistryNearPoint(latitude: lat, longitude: lon,
                                              radiusKm: 5, perPage: 15),
                    "commerces autour de \(locality?.displayName ?? "la commune")", 0.3)
            }
        }

        // 7 — recherche cartographique.
        if options.allowPlaces {
            let localityLabel = locality?.displayName ?? extraction.primaryLocalityText
            let text = AbbreviationTable.expand(extraction.nameTokens).joined(separator: " ")
            add(.placeText(PlaceTextQuery(
                text: text,
                localityLabel: localityLabel,
                countryCode: country,
                latitude: locality?.latitude,
                longitude: locality?.longitude,
                limit: 8
            )), "recherche cartographique", 0.5)
        }

        // 8 — rejeu en incluant les entreprises fermées. Interactif seulement : en batch,
        // un établissement fermé est presque toujours un faux positif.
        if isFrench, options.includeCeased {
            add(.companyRegistry(registryQuery(name, ceased: true)),
                "en incluant les entreprises fermées", 0.25)
        }

        return attempts
    }

    // MARK: - Contexte de classement

    private static func rankingContext(extraction: MerchantLabelExtraction,
                                       locality: ResolvedLocality?) -> RankingContext {
        // Si l'oracle n'a pas reconnu de commune, le texte de localité n'est PAS perdu :
        // il devient un signal de tri cherché dans l'adresse des candidats. Un lieu-dit
        // inconnu de geo.api.gouv.fr apparaît très souvent tel quel dans l'adresse du bon
        // établissement. C'est ce qui rend le correctif indépendant de l'oracle.
        let freeText = locality == nil ? extraction.primaryLocalityText : nil
        return RankingContext(
            nameTokens: extraction.nameTokens,
            freeLocalityText: freeText,
            inseeCode: locality?.inseeCode,
            postalCodes: extraction.postalCodeToken.map { [$0] } ?? locality?.postalCodes ?? [],
            departmentCode: extraction.departmentHint ?? locality?.departmentCode,
            cityLabel: locality?.displayName
        )
    }

    // MARK: - Variantes d'extraction

    private static func overrideExtraction(_ input: Input, override: String) -> MerchantLabelExtraction {
        let tokens = MerchantTokenSimilarity.tokenize(override)
        return MerchantLabelExtraction(
            rawLabel: input.rawLabel,
            templateId: nil,
            processorId: nil,
            nameTokens: tokens,
            localityTokens: localityTokensFromUser(input),
            countryHint: input.userCountry?.uppercased(),
            departmentHint: nil,
            droppedTokens: [],
            isPersonNotBusiness: false,
            isOnlinePayment: false
        )
    }

    private static func emptyExtraction(_ input: Input) -> MerchantLabelExtraction {
        MerchantLabelExtraction(
            rawLabel: input.rawLabel,
            templateId: nil, processorId: nil,
            nameTokens: [], localityTokens: localityTokensFromUser(input),
            countryHint: input.userCountry?.uppercased(), departmentHint: nil,
            droppedTokens: [], isPersonNotBusiness: false, isOnlinePayment: false
        )
    }

    private static func templateExtraction(_ input: Input,
                                           tokens: [String],
                                           template: BankLabelTemplate,
                                           slots: TemplateSlots,
                                           refinement: LLMQueryRefinement) -> MerchantLabelExtraction {
        var dropped = slots.dropped
        var localityTokens = localityTokensFromUser(input)

        // La localité vient du CRÉNEAU du gabarit — position fixe, avant le marchand,
        // et tronquée. Confiance 1.0 : ce n'est pas une devinette, c'est la structure.
        if let range = slots.localityRange {
            let text = tokens[range].joined(separator: " ")
            if !text.isEmpty {
                localityTokens.append(LocalityToken(raw: text, kind: .cityName, confidence: 1.0))
                for t in tokens[range] { dropped.append(DroppedToken(value: t, reason: .locality)) }
            }
        }

        var nameTokens = Array(tokens[slots.merchantRange])
        // Le créneau marchand peut encore contenir un code postal ou un code pays isolé.
        nameTokens = stripGeoNoise(from: nameTokens, into: &localityTokens, dropped: &dropped)
        // La ville se répète très souvent dans le nom de l'enseigne : « MASSY AUCHAN MASSY »,
        // « LYON CITADIUM LYON », « PARIS VELIZE JD PARIS VELIZE ». La laisser dans `q=`
        // reproduit exactement le bug que cet axe corrige — `q=auchan` + filtre commune
        // trouve, `q=auchan massy` ne trouve rien.
        nameTokens = stripRepeatedLocality(from: nameTokens, localityTokens: localityTokens,
                                           dropped: &dropped)
        nameTokens = joinSpelledAcronyms(nameTokens)

        var country = input.userCountry?.uppercased()
            ?? refinement.countryCode
            ?? input.engineCountryCandidate?.uppercased()
        if country == nil, localityTokens.contains(where: { $0.kind == .postalCode }) { country = "FR" }
        // Un gabarit bancaire français implique la France dès qu'un lieu est présent.
        if country == nil, slots.localityRange != nil || slots.departmentCode != nil { country = "FR" }

        return MerchantLabelExtraction(
            rawLabel: input.rawLabel,
            templateId: template.id,
            processorId: refinement.processorName ?? input.engineProcessorId,
            nameTokens: nameTokens,
            localityTokens: localityTokens,
            countryHint: country,
            departmentHint: slots.departmentCode,
            droppedTokens: dropped,
            isPersonNotBusiness: refinement.isPersonNotBusiness,
            isOnlinePayment: slots.isOnlinePayment
        )
    }

    private static func heuristicExtraction(_ input: Input,
                                            tokens: [String],
                                            refinement: LLMQueryRefinement) -> MerchantLabelExtraction {
        var dropped: [DroppedToken] = []
        var localityTokens = localityTokensFromUser(input)
        var working: [String] = []

        // 1. Retrait des préfixes bancaires en TÊTE, des processeurs et des références.
        var leadingPrefix = true
        for token in tokens {
            if leadingPrefix, AbbreviationTable.isBankPrefix(token) {
                dropped.append(DroppedToken(value: token, reason: .processorPrefix)); continue
            }
            if AbbreviationTable.isPaymentProcessor(token) {
                dropped.append(DroppedToken(value: token, reason: .processorPrefix)); continue
            }
            if AbbreviationTable.isReferenceWithDigits(token)
                || AbbreviationTable.referenceMarkers.contains(token) {
                dropped.append(DroppedToken(value: token, reason: .paymentReference)); continue
            }
            if BankLabelTemplate.isTransactionId(token) {
                dropped.append(DroppedToken(value: token, reason: .transactionId)); continue
            }
            if BankLabelTemplate.isDayMonth(token) {
                dropped.append(DroppedToken(value: token, reason: .date)); continue
            }
            // Suite de chiffres trop longue pour être un code postal : c'est une référence
            // de mandat ou de contrat (« IDFM 332747815 2980171 786180 »). Les laisser
            // passer produisait des `q=` entièrement composés d'identifiants.
            if token.count >= 6, token.allSatisfy(\.isNumber) {
                dropped.append(DroppedToken(value: token, reason: .transactionId)); continue
            }
            leadingPrefix = false
            working.append(token)
        }

        // 2. Ville étrangère connue, n'importe où.
        var countryFromCity: String? = nil
        if let hit = ForeignLocalityTable.findCity(in: working) {
            localityTokens.append(LocalityToken(raw: hit.name, kind: .cityName, confidence: 1.0))
            for t in working[hit.range] { dropped.append(DroppedToken(value: t, reason: .locality)) }
            countryFromCity = hit.countryCode
            working.removeSubrange(hit.range)
        }

        // 3. Code pays isolé en fin de libellé (jamais ailleurs — « CB » n'est pas Cuba).
        var countryFromCode: String? = nil
        if let last = working.last, last.count == 2, last.allSatisfy(\.isLetter),
           ForeignLocalityTable.countryCodes.contains(last), working.count > 1 {
            countryFromCode = ForeignLocalityTable.normalizeCountryCode(last)
            dropped.append(DroppedToken(value: last, reason: .countryCode))
            working.removeLast()
        }

        // 4. Code postal / bruit géographique résiduel.
        working = stripGeoNoise(from: working, into: &localityTokens, dropped: &dropped)

        // 5. Ville confirmée par le moteur (son set fermé de 153 communes) : elle est
        //    fiable quand elle répond, mais elle rate tout le reste — d'où l'étape 6.
        if let engineCity = input.engineCityCandidate?.lowercased(),
           !engineCity.isEmpty,
           let index = working.firstIndex(of: engineCity) {
            localityTokens.append(LocalityToken(raw: engineCity, kind: .cityName, confidence: 1.0))
            dropped.append(DroppedToken(value: engineCity, reason: .locality))
            working.remove(at: index)
        }

        // 6. Sinon, n-gram de fin agrandi vers la gauche à travers les particules
        //    toponymiques françaises (« saint didier au mont d or », « aix en provence »).
        //    Deviné, donc confiance 0.6 — et il reste TOUJOURS au moins un token de nom.
        //
        //    ⚠️ Jamais sur un virement ou un prélèvement : il n'y a pas de point de vente,
        //    donc pas de ville à deviner. Sans cette garde, « VIR INST PAUL ANDRE » voyait
        //    « andre » comme une commune et l'arrachait au nom.
        let isTransfer = tokens.contains { $0 == "vir" || $0 == "virement" || $0 == "prlv" }
        if !isTransfer,
           !localityTokens.contains(where: { $0.kind == .cityName }), working.count >= 2 {
            let span = trailingLocalitySpan(working)
            if span > 0, working.count - span >= 1 {
                let text = working.suffix(span).joined(separator: " ")
                localityTokens.append(LocalityToken(raw: text, kind: .cityName, confidence: 0.6))
                for t in working.suffix(span) { dropped.append(DroppedToken(value: t, reason: .locality)) }
                working.removeLast(span)
            }
        }

        // 7. Le raffinement peut proposer une localité que rien n'a vue.
        if !localityTokens.contains(where: { $0.kind == .cityName }),
           let hinted = refinement.localityName, !hinted.isEmpty {
            localityTokens.append(LocalityToken(raw: hinted, kind: .cityName, confidence: 0.5))
        }

        var country = input.userCountry?.uppercased()
            ?? countryFromCity
            ?? countryFromCode
            ?? refinement.countryCode
            ?? input.engineCountryCandidate?.uppercased()
        if country == nil, localityTokens.contains(where: { $0.kind == .postalCode }) { country = "FR" }

        return MerchantLabelExtraction(
            rawLabel: input.rawLabel,
            templateId: nil,
            processorId: refinement.processorName ?? input.engineProcessorId,
            nameTokens: joinSpelledAcronyms(working),
            localityTokens: localityTokens,
            countryHint: country,
            departmentHint: nil,
            droppedTokens: dropped,
            isPersonNotBusiness: refinement.isPersonNotBusiness,
            isOnlinePayment: false
        )
    }

    // MARK: - Aides

    /// Particules toponymiques françaises. Un nom de commune ne s'arrête jamais dessus,
    /// donc on continue de grandir vers la gauche tant qu'on en croise une.
    private static let toponymParticles: Set<String> = [
        "saint", "st", "sainte", "ste", "sur", "sous", "en", "les", "le", "la", "lez",
        "de", "du", "des", "aux", "au", "d", "l", "mont", "val", "pres", "sr"
    ]

    /// Fragments qui terminent souvent un libellé sans être des lieux.
    private static let nonLocalityTrailers: Set<String> = [
        "com", "net", "org", "www", "app", "bill", "shop", "store", "online", "web",
        "sarl", "sas", "sasu", "eurl", "sci", "inc", "ltd", "gmbh", "bv", "nv", "plc"
    ]

    /// Combien de tokens de fin forment plausiblement une commune multi-mots.
    /// Renvoie 0 si le dernier token est manifestement autre chose.
    ///
    /// ⚠️ Volontairement CONSERVATEUR (seuil à 4 caractères) : une localité devinée à tort
    /// RETIRE un mot du `q=`, ce qui est destructeur. Le seuil bas d'origine transformait
    /// « APPLE COM/BILL » en ville « com », « ON AIR » en ville « on » et « Cat Ba » en
    /// ville « ba ». Rater une ville coûte une requête de plus ; en inventer une coûte le
    /// bon résultat. Les communes courtes légitimes (Hué, Gif) arrivent par le gabarit
    /// bancaire ou la table étrangère, pas par cette devinette.
    private static func trailingLocalitySpan(_ tokens: [String]) -> Int {
        guard let last = tokens.last, last.allSatisfy(\.isLetter),
              !nonLocalityTrailers.contains(last) else { return 0 }

        // Amorce. Un mot d'au moins 4 lettres peut porter une commune à lui seul.
        // Un mot court ne le peut QUE s'il termine un nom composé, ce que signale la
        // particule qui le précède : « Saint-Didier-au-Mont-**d'Or** », « …-sur-**Mer** ».
        let precededByParticle = tokens.count >= 2
            && toponymParticles.contains(tokens[tokens.count - 2])
        guard last.count >= 4 || precededByParticle else { return 0 }

        var span = 1
        // Grandit tant que le token immédiatement à gauche est une particule.
        while span < tokens.count - 1, span < 7 {
            let candidate = tokens[tokens.count - 1 - span]
            guard toponymParticles.contains(candidate) else { break }
            span += 1
            // Une particule est forcément suivie (à gauche) d'un mot qui fait partie du nom.
            if span < tokens.count - 1 {
                span += 1
            } else {
                break
            }
        }
        return span
    }

    /// Retire les codes postaux et codes pays restés dans le nom, en les versant
    /// dans les tokens de localité. C'est le correctif du bug « 75011 dans q= » :
    /// `NormalizerPipeline.isPureNumericNoise` ne jette un token numérique que s'il fait
    /// ≤ 4 caractères ET qu'il est en dernier — un code postal à 5 chiffres survit donc
    /// toujours et finit dans `merchantCandidate`.
    private static func stripGeoNoise(from tokens: [String],
                                      into localityTokens: inout [LocalityToken],
                                      dropped: inout [DroppedToken]) -> [String] {
        var out: [String] = []
        for token in tokens {
            if token.count == 5, token.allSatisfy(\.isNumber) {
                if !localityTokens.contains(where: { $0.kind == .postalCode }) {
                    localityTokens.append(LocalityToken(raw: token, kind: .postalCode, confidence: 1.0))
                }
                dropped.append(DroppedToken(value: token, reason: .postalCode))
                continue
            }
            out.append(token)
        }
        // Ne jamais vider complètement le nom : mieux vaut un `q` bruité qu'un `q` vide.
        return out.isEmpty ? tokens : out
    }

    /// Recolle les sigles épelés lettre par lettre : « C P A M TROYES » → « cpam troyes »,
    /// « B B HOTEL » → « bb hotel ». Les relevés espacent fréquemment les sigles, et un
    /// registre d'entreprises ne trouve rien avec `q=c p a m` alors que `q=cpam` trouve.
    /// Seules les séries d'AU MOINS deux lettres isolées consécutives sont recollées.
    static func joinSpelledAcronyms(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var run: [String] = []
        func flush() {
            if run.count >= 2 { out.append(run.joined()) } else { out.append(contentsOf: run) }
            run.removeAll()
        }
        for token in tokens {
            if token.count == 1, token.allSatisfy(\.isLetter) {
                run.append(token)
            } else {
                flush()
                out.append(token)
            }
        }
        flush()
        return out
    }

    /// Retire du nom les mots qui répètent la localité déjà isolée.
    /// Ne vide JAMAIS le nom : si l'enseigne n'est QUE le nom de la ville, on la garde
    /// (« PAIEMENT PSC 1001 LYON LYON » vaut mieux que `q=` vide).
    private static func stripRepeatedLocality(from tokens: [String],
                                              localityTokens: [LocalityToken],
                                              dropped: inout [DroppedToken]) -> [String] {
        let localityWords = Set(localityTokens
            .filter { $0.kind == .cityName }
            .flatMap { $0.raw.split(separator: " ").map(String.init) })
        guard !localityWords.isEmpty else { return tokens }
        let filtered = tokens.filter { !localityWords.contains($0) }
        guard !filtered.isEmpty else { return tokens }
        for token in tokens where localityWords.contains(token) {
            dropped.append(DroppedToken(value: token, reason: .locality))
        }
        return filtered
    }

    private static func localityTokensFromUser(_ input: Input) -> [LocalityToken] {
        guard let pc = input.userPostalCode?.trimmingCharacters(in: .whitespaces),
              pc.count == 5, pc.allSatisfy(\.isNumber) else { return [] }
        return [LocalityToken(raw: pc, kind: .postalCode, confidence: 1.0)]
    }

    /// Tokens de travail. Utilise ceux du moteur quand ils sont là (en écartant ce qu'il
    /// a déjà classé comme bruit structurel), sinon retombe sur une tokenisation locale.
    /// Ce repli sert pendant le démarrage à froid du moteur (1 à 15 s pour charger ONNX) :
    /// ce n'est PAS une seconde implémentation de la normalisation, juste un découpage.
    static func tokenizeForPlanning(_ input: Input) -> [String] {
        if !input.engineTokens.isEmpty {
            let kept = input.engineTokens
                .filter { $0.tag != .noise && $0.tag != .direction }
                .map(\.value)
            if !kept.isEmpty { return kept }
        }
        return MerchantTokenSimilarity.tokenize(input.rawLabel)
    }
}
