import Foundation

// The merchant query planner.
// ⚠️ PURE FILE: `import Foundation` ONLY.
//
// Two total pure functions:
//   extract(_:)                   → parses the label (name / locality / noise)
//   plan(extraction:locality:…)   → an ordered cascade of concrete attempts
//
// Between the two, the executor interleaves the asynchronous locality
// resolution. See `LocalityResolver` for why the split is done this way.
//
// CARDINAL RULE, verified by t1: the locality NEVER ends up in `q=`.
// The API matches `q` against the company name and trade names, never against
// the address; putting the city in doesn't restrict the search, it makes it fail.

enum MerchantQueryPlanner {

    // MARK: - Input

    /// Mirror of `NemorisEngine.TokenTag`, copied by `rawValue`.
    /// The planner can't import `NemorisEngine`: it's a SwiftPM package,
    /// and the `swiftc` harness would then have to compile it in full.
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
        /// Output of `NormalizerPipeline` — consumed, never recomputed.
        var engineMerchantCandidate: String?
        var engineCityCandidate: String?
        var engineCountryCandidate: String?
        var engineProcessorId: String?
        var engineTokens: [Token]
        /// Form fields: they TAKE PRIORITY over any inference.
        var userCountry: String?
        var userPostalCode: String?
        var userQueryOverride: String?
        /// nil ⇒ deterministic path only, always valid.
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
        // The user typed their own query: it's authoritative, we don't re-split anything.
        if let override = input.userQueryOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return overrideExtraction(input, override: override)
        }

        let tokens = tokenizeForPlanning(input)
        guard !tokens.isEmpty else { return emptyExtraction(input) }

        let refinement = input.refinement ?? DeterministicQueryRefiner.refine(
            rawLabel: input.rawLabel, tokens: tokens
        )

        // --- 1. Fixed-field bank template (91% of "PAIEMENT" labels).
        if let (template, slots) = BankLabelTemplate.match(tokens) {
            return templateExtraction(input, tokens: tokens, template: template,
                                      slots: slots, refinement: refinement)
        }

        // --- 2. Heuristic fallback: cleanup + locality at the end of the label.
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

    /// Shortcut: extraction + plan, for tests and callers with no resolved locality.
    static func plan(_ input: Input,
                     locality: ResolvedLocality? = nil,
                     options: Options = .interactive) -> MerchantQueryPlan {
        plan(extraction: extract(input), locality: locality, options: options)
    }

    // MARK: - Building attempts

    private static func buildAttempts(extraction: MerchantLabelExtraction,
                                      locality: ResolvedLocality?,
                                      options: Options) -> [SearchAttempt] {
        // No attempt for a private individual: we NEVER send a real person's
        // name to a company registry. Privacy, and it wouldn't return anything anyway.
        guard !extraction.isPersonNotBusiness else { return [] }
        // Nor for a label with nothing usable left: no network request
        // for "***" or "A".
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

        // The company registry is only queried for France. A Vietnamese
        // label only produces a map search — no point spending a
        // Sirene request on a restaurant in Da Nang.
        let isFrench = (country == nil || country == "FR")

        if isFrench {
            // 1 — INSEE commune: the most precise filter.
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
            // 3 — department.
            if let dep = extraction.departmentHint ?? (extraction.isOnlinePayment ? nil : locality?.departmentCode) {
                add(.companyRegistry(registryQuery(name, departement: dep)),
                    "nom seul + département \(dep)", 0.75)
            }
            // 4 — bare name. ALWAYS present: it's the fix for the original bug.
            // "q=srom flanches" returned 0, "q=srom" returns 13 results among which
            // ranking by proximity to the location finds the right one.
            add(.companyRegistry(registryQuery(name)),
                locality == nil && extraction.primaryLocalityText != nil
                    ? "nom seul, tri par proximité du lieu"
                    : "nom seul",
                0.6)
            // 5 — shortened name: chain names are truncated at a fixed width in
            // statements ("SC-PHIE NIMES V"), the last token is often cut off.
            //
            // ⚠️ No "name + locality" attempt here, even when the commune isn't
            // resolved and the fragment is ambiguous ("SROM **FLANCHES**" is a place
            // name but "FOURNIL **PLIQUE**" is the baker's own name). That would reopen
            // the door to the original bug. And it's unnecessary: `q=fournil` already
            // finds the bakery — the registry matches partial names, and `CandidateRanker`
            // promotes "FOURNIL PLIQUE" based on token overlap. The cardinal rule
            // stays absolute: the locality NEVER goes into `q=`.
            if extraction.nameTokens.count >= 3 {
                let shortened = extraction.nameTokens.dropLast().joined(separator: " ")
                add(.companyRegistry(registryQuery(shortened)), "nom raccourci", 0.45)
            }
            // 6 — geographic proximity, last resort if everything else is empty.
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

        // 8 — replay including closed companies. Interactive only: in batch,
        // a closed establishment is almost always a false positive.
        if isFrench, options.includeCeased {
            add(.companyRegistry(registryQuery(name, ceased: true)),
                "en incluant les entreprises fermées", 0.25)
        }

        return attempts
    }

    // MARK: - Ranking context

    private static func rankingContext(extraction: MerchantLabelExtraction,
                                       locality: ResolvedLocality?) -> RankingContext {
        // If the oracle didn't recognize a commune, the locality text is NOT lost:
        // it becomes a sort signal looked for in candidates' addresses. A place
        // name unknown to geo.api.gouv.fr very often shows up as-is in the
        // right establishment's address. That's what makes the fix independent of
        // the oracle.
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

        // The locality comes from the template's SLOT — a fixed position, before
        // the merchant, and truncated. Confidence 1.0: it's not a guess, it's the
        // structure.
        if let range = slots.localityRange {
            let text = tokens[range].joined(separator: " ")
            if !text.isEmpty {
                localityTokens.append(LocalityToken(raw: text, kind: .cityName, confidence: 1.0))
                for t in tokens[range] { dropped.append(DroppedToken(value: t, reason: .locality)) }
            }
        }

        var nameTokens = Array(tokens[slots.merchantRange])
        // The merchant slot can still contain an isolated postal code or country code.
        nameTokens = stripGeoNoise(from: nameTokens, into: &localityTokens, dropped: &dropped)
        // The city very often repeats in the chain's name: "NIMES AUCHAN NIMES",
        // "LYON CITADIUM LYON", "PARIS VELIZE JD PARIS VELIZE". Leaving it in `q=`
        // reproduces exactly the bug this feature fixes — `q=auchan` + a commune
        // filter finds it, `q=auchan nimes` finds nothing.
        nameTokens = stripRepeatedLocality(from: nameTokens, localityTokens: localityTokens,
                                           dropped: &dropped)
        nameTokens = joinSpelledAcronyms(nameTokens)

        var country = input.userCountry?.uppercased()
            ?? refinement.countryCode
            ?? input.engineCountryCandidate?.uppercased()
        if country == nil, localityTokens.contains(where: { $0.kind == .postalCode }) { country = "FR" }
        // A French bank template implies France as soon as a place is present.
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

        // 1. Stripping LEADING bank prefixes, processors and references.
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
            // A run of digits too long to be a postal code: it's a mandate or contract
            // reference ("IDFM 332747815 2980171 786180"). Letting them through
            // produced `q=`s made entirely of identifiers.
            if token.count >= 6, token.allSatisfy(\.isNumber) {
                dropped.append(DroppedToken(value: token, reason: .transactionId)); continue
            }
            leadingPrefix = false
            working.append(token)
        }

        // 2. A known foreign city, anywhere.
        var countryFromCity: String? = nil
        if let hit = ForeignLocalityTable.findCity(in: working) {
            localityTokens.append(LocalityToken(raw: hit.name, kind: .cityName, confidence: 1.0))
            for t in working[hit.range] { dropped.append(DroppedToken(value: t, reason: .locality)) }
            countryFromCity = hit.countryCode
            working.removeSubrange(hit.range)
        }

        // 3. An isolated country code at the end of the label (never elsewhere — "CB" isn't Cuba).
        var countryFromCode: String? = nil
        if let last = working.last, last.count == 2, last.allSatisfy(\.isLetter),
           ForeignLocalityTable.countryCodes.contains(last), working.count > 1 {
            countryFromCode = ForeignLocalityTable.normalizeCountryCode(last)
            dropped.append(DroppedToken(value: last, reason: .countryCode))
            working.removeLast()
        }

        // 4. Residual postal code / geographic noise.
        working = stripGeoNoise(from: working, into: &localityTokens, dropped: &dropped)

        // 5. A city confirmed by the engine (its closed set of 153 communes): reliable
        //    when it answers, but it misses everything else — hence step 6.
        if let engineCity = input.engineCityCandidate?.lowercased(),
           !engineCity.isEmpty,
           let index = working.firstIndex(of: engineCity) {
            localityTokens.append(LocalityToken(raw: engineCity, kind: .cityName, confidence: 1.0))
            dropped.append(DroppedToken(value: engineCity, reason: .locality))
            working.remove(at: index)
        }

        // 6. Otherwise, a trailing n-gram grown leftward across French toponymic
        //    particles ("saint didier au mont d or", "aix en provence").
        //    A guess, hence confidence 0.6 — and at least one name token always
        //    remains.
        //
        //    ⚠️ Never on a transfer or a direct debit: there's no point of sale,
        //    so no city to guess. Without this guard, "VIR INST PAUL ANDRE" saw
        //    "andre" as a commune and tore it off the name.
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

        // 7. Refinement may propose a locality that nothing else saw.
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

    /// French toponymic particles. A commune name never stops on one of these,
    /// so we keep growing leftward as long as we hit one.
    private static let toponymParticles: Set<String> = [
        "saint", "st", "sainte", "ste", "sur", "sous", "en", "les", "le", "la", "lez",
        "de", "du", "des", "aux", "au", "d", "l", "mont", "val", "pres", "sr"
    ]

    /// Fragments that often end a label without being places.
    private static let nonLocalityTrailers: Set<String> = [
        "com", "net", "org", "www", "app", "bill", "shop", "store", "online", "web",
        "sarl", "sas", "sasu", "eurl", "sci", "inc", "ltd", "gmbh", "bv", "nv", "plc"
    ]

    /// How many trailing tokens plausibly form a multi-word commune name.
    /// Returns 0 if the last token is clearly something else.
    ///
    /// ⚠️ Deliberately CONSERVATIVE (4-character threshold): a wrongly-guessed
    /// locality REMOVES a word from `q=`, which is destructive. The original
    /// low threshold turned "APPLE COM/BILL" into the city "com", "ON AIR" into
    /// the city "on", and "Cat Ba" into the city "ba". Missing a city costs one
    /// more request; inventing one costs the right result. Legitimate short
    /// commune names (Hué, Gif) arrive via the bank template or the foreign
    /// locality table, not through this guess.
    private static func trailingLocalitySpan(_ tokens: [String]) -> Int {
        guard let last = tokens.last, last.allSatisfy(\.isLetter),
              !nonLocalityTrailers.contains(last) else { return 0 }

        // Seed. A word of at least 4 letters can carry a commune name on its own.
        // A short word can ONLY do so if it ends a compound name, which the
        // particle before it signals: "Saint-Didier-au-Mont-**d'Or**", "…-sur-**Mer**".
        let precededByParticle = tokens.count >= 2
            && toponymParticles.contains(tokens[tokens.count - 2])
        guard last.count >= 4 || precededByParticle else { return 0 }

        var span = 1
        // Grows as long as the token immediately to the left is a particle.
        while span < tokens.count - 1, span < 7 {
            let candidate = tokens[tokens.count - 1 - span]
            guard toponymParticles.contains(candidate) else { break }
            span += 1
            // A particle is necessarily followed (to its left) by a word that's part of the name.
            if span < tokens.count - 1 {
                span += 1
            } else {
                break
            }
        }
        return span
    }

    /// Strips postal codes and country codes still stuck in the name, moving
    /// them into the locality tokens. This is the fix for the "75011 in q=" bug:
    /// `NormalizerPipeline.isPureNumericNoise` only drops a numeric token if it's
    /// ≤ 4 characters AND it's the last one — a 5-digit postal code therefore always
    /// survives and ends up in `merchantCandidate`.
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
        // Never empty the name completely: a noisy `q` is better than an empty `q`.
        return out.isEmpty ? tokens : out
    }

    /// Stitches back together acronyms spelled letter by letter: "C P A M TROYES" →
    /// "cpam troyes", "B B HOTEL" → "bb hotel". Statements frequently space out
    /// acronyms, and a company registry finds nothing with `q=c p a m` while
    /// `q=cpam` finds it. Only runs of AT LEAST two consecutive single letters
    /// are stitched together.
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

    /// Removes from the name any words that repeat the already-isolated locality.
    /// NEVER empties the name: if the chain's name IS the city name, we keep it
    /// ("PAIEMENT PSC 1001 LYON LYON" is better than an empty `q=`).
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

    /// Working tokens. Uses the engine's own when they're there (discarding what
    /// it has already classified as structural noise), otherwise falls back to a
    /// local tokenization. This fallback serves during the engine's cold start
    /// (1 to 15s to load ONNX): it's NOT a second implementation of
    /// normalization, just a split.
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
