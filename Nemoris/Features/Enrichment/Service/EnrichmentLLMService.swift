import Foundation
import CoreGraphics
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Wrapper around Apple Foundation Models (`LanguageModelSession`) for enriching
/// bank labels. 100% on-device, free, no API key. iOS 26.0+.
///
/// If the framework isn't available (iOS < 26.0) or the model isn't available
/// on the device, `identify(...)` returns nil — `AIEnrichmentBackend` (the shared
/// dispatch point) then falls back to `LocalLLMService` if the user configured
/// one, or simply continues with Sirene + MapKit.
///
/// Privacy: no network calls, no telemetry. Consistent with the project's privacy-first stance.
@MainActor
final class EnrichmentLLMService {

    static let shared = EnrichmentLLMService()

    /// Indicates whether the Foundation Models framework is available AND ready on this device.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Tries to identify a merchant from the raw label + transaction context.
    /// Returns a `MerchantEnrichment` with source=.llm on success, nil otherwise.
    func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return await identifyV2(context: context)
        }
        #endif
        return nil
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func identifyV2(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let prompt = Self.buildPrompt(context: context)
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: prompt)
            return Self.parseJSONResponse(response.content, context: context)
        } catch {
            print("[EnrichmentLLMService] generation error: \(error.localizedDescription)")
            return nil
        }
    }
    #endif

    /// Generic text completion via Foundation Models. `nil` if the framework
    /// is unavailable or generation fails — same silent-failure contract
    /// as `identify`. Used by `AIEnrichmentBackend.completeText` for
    /// tasks other than merchant identification (statement extraction,
    /// notably).
    func complete(system: String, user: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let session = LanguageModelSession(instructions: system)
            do {
                return try await session.respond(to: user).content
            } catch {
                print("[EnrichmentLLMService] complete error: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    /// True if the embedded Apple model accepts an IMAGE as input.
    ///
    /// ⚠️ `FoundationModels.Attachment` / `ImageAttachmentContent` are
    /// `@available(iOS 27.0, macOS 27.0)` — one step AFTER the rest of the framework
    /// (iOS 26). Verified in the SDK, not inferred.
    ///
    /// ⚠️ **`@available` isn't enough here**: Xcode 26's SDK (Swift 6.3,
    /// iOS 26) doesn't even DECLARE `Attachment` — it's not just marked
    /// unavailable, the symbol doesn't exist at all in this SDK. `#if
    /// canImport(FoundationModels)` still passes (the MODULE has existed since
    /// iOS 26), so `if #available` alone lets the compiler try to
    /// resolve `Attachment` and fail with "Cannot find 'Attachment' in
    /// scope" — on Xcode 26 specifically, not on Xcode 27 (Swift 6.4, SDK
    /// iOS 27, where the type exists). Hence the COMPILE-TIME guard `#if
    /// compiler(>=6.4)` in addition to the runtime guard: it strips the block
    /// out of the program BEFORE the type-checker has to resolve `Attachment`.
    /// Threshold verified empirically (`xcrun swift --version` for each
    /// toolchain): Xcode 26.6 → Swift 6.3.3, Xcode 27.0 → Swift 6.4.
    var supportsImageInput: Bool {
        #if compiler(>=6.4) && canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Completion from an IMAGE: the model reads the screenshot itself.
    ///
    /// This is by far the more robust path — the layout (columns,
    /// grouping by date, category subtitles) carries meaning that flattened
    /// OCR text destroys, and that no line-ordering heuristic
    /// reconstructs in a general way.
    ///
    /// ⚠️ Same `#if compiler(>=6.4)` guard as `supportsImageInput` above —
    /// `Attachment` doesn't exist in Xcode 26's SDK. On that toolchain,
    /// this function reduces to `return nil`: `supportsImageInput` is already
    /// `false` there, so no caller should ever reach it.
    func complete(system: String, user: String, image: CGImage) async -> String? {
        #if compiler(>=6.4) && canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let session = LanguageModelSession(instructions: system)
            do {
                let response = try await session.respond {
                    user
                    Attachment(image)
                }
                return response.content
            } catch {
                print("[EnrichmentLLMService] complete(image) error: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }

    // MARK: - Prompts

    static let instructions = """
    Tu es un assistant qui identifie des marchands à partir d'un libellé bancaire.
    Le libellé peut venir de n'importe quel pays — analyse-le sans présupposer la France.

    PROCÉDURE :

    1) IDENTIFIE LE PROCESSEUR DE PAIEMENT (à IGNORER pour trouver le marchand) :
       - International : PAYPAL, STRIPE, SUMUP, ADYEN, SQUARE, KLARNA, REVOLUT
       - Asie : VNPAY (Vietnam), ALIPAY, WECHAT PAY (Chine), PAYU (Inde)
       - Wallets : APPLE PAY, GOOGLE PAY, SAMSUNG PAY
       - Préfixes bancaires FR : CB, VIR, PRLV, INST, RETRAIT, FRAIS
       Le marchand est ce qui SUIT ces préfixes.

    2) IDENTIFIE LE PAYS depuis le libellé :
       - Codes ISO 2 lettres collés au libellé (ex "VN P" = Vietnam, "US" = USA, "GB" = UK, "DE" = Allemagne)
       - Noms de villes connues : Ha Giang/Hanoi/Hô-Chi-Minh = VN, London = GB, Berlin = DE, etc.
       - Si VNPAY → presque certainement VN. Si SEPA RECU → probablement zone euro.

    3) IDENTIFIE LA VILLE — cherche dans le libellé brut avant tout.
       Le bouton "PAYS / VILLE" est souvent collé en fin (ex "PARIS 75", "HA GIANG", "75001")

    4) EXTRAIS LE NOM COMMERCIAL :
       - Abréviations FR : RES = Restaurant, BAR/CAFE, HOT = Hôtel, MKT = Market,
         PHARM, BOULANG = Boulangerie, PSC = code de référence VNPAY à IGNORER
       - Abréviations vietnamiennes :
           NHA HANG = Restaurant
           CONG TY TNHH = Company Limited (SARL) — extraire le nom qui suit
           HO KINH DOANH = Household Business — souvent commerce de famille
           CHO = Marché
           QUAN = Restaurant / Quan (suivi du nom)
           KHACH SAN = Hôtel
           SIEU THI = Supermarché
           ACV = Airports Corporation of Vietnam (aéroport)
           NOI BAI = aéroport principal de Hanoi
           TAN SON NHAT = aéroport principal de Hô Chi Minh
       - Villes vietnamiennes connues : HA NOI, HO CHI MINH (= SAIGON),
         DA NANG, HUE, HAI PHONG, NHA TRANG, DA LAT, HOI AN, CAN THO,
         VUNG TAU, HA GIANG, NGU HANH SON (district Da Nang), PHU QUOC
       - Codes de référence numériques/alphanumériques à IGNORER (PSC, REF, N°…)

    5) PROPOSE UNE search_query CLEAN pour les APIs cartographiques :
       Format "<nom du marchand> <ville>" sans les codes de paiement ni de référence.

    EXEMPLES :

    Input: "VNPAY HUNG RES PSC VN P HA GIANG"
    Output : {"name":"Hung Restaurant","category":"Alimentation","country":"VN","city":"Ha Giang",
              "domain":null,"confidence":0.75,
              "search_query":"Hung Restaurant Ha Giang",
              "reasoning":"VNPAY = paiement vietnamien, RES = restaurant, HA GIANG = ville VN"}

    Input: "ACV NOI BAI PSC VN HA NOI"
    Output : {"name":"Aéroport de Hanoi (Noi Bai)","category":"Voyages","country":"VN","city":"Hanoi",
              "domain":"vietnamairport.vn","confidence":0.85,
              "search_query":"Noi Bai International Airport Hanoi",
              "reasoning":"ACV = Airports Corp Vietnam, NOI BAI = aéroport principal Hanoi"}

    Input: "VNPAY NH AN HO PSC VN DA NANG"
    Output : {"name":"Nha An Ho","category":"Alimentation","country":"VN","city":"Da Nang",
              "domain":null,"confidence":0.55,
              "search_query":"Nha An Ho Restaurant Da Nang",
              "reasoning":"NH (Nha Hang) = Restaurant en abrégé, suivi du nom An Ho"}

    Input: "CONG TY TNHH F PSC VN DA NANG"
    Output : {"name":"Société F (Da Nang)","category":"Autre","country":"VN","city":"Da Nang",
              "domain":null,"confidence":0.35,
              "search_query":"Company F Da Nang Vietnam",
              "reasoning":"CONG TY TNHH = SARL, mais nom 'F' trop court pour identifier précisément"}

    Input: "NHA HANG RAU M PSC VN DA NANG"
    Output : {"name":"Restaurant Rau M","category":"Alimentation","country":"VN","city":"Da Nang",
              "domain":null,"confidence":0.6,
              "search_query":"Rau M Restaurant Da Nang",
              "reasoning":"NHA HANG = Restaurant en vietnamien"}

    Input: "HO KINH DOANH PSC VN DA NANG"
    Output : {"name":"Commerce familial (non identifié)","category":"Autre","country":"VN","city":"Da Nang",
              "domain":null,"confidence":0.3,
              "search_query":null,
              "reasoning":"HO KINH DOANH = household business, nom du commerce absent du libellé"}

    Input: "PAYPAL *NETFLIX 4007 CA"
    Output : {"name":"Netflix","category":"Loisirs & Culture","country":"US","city":null,
              "domain":"netflix.com","confidence":0.95,
              "search_query":"Netflix",
              "reasoning":"PAYPAL processeur, NETFLIX marque connue"}

    Input: "CB CARREFOUR MARKET 75011 PARIS"
    Output : {"name":"Carrefour Market","category":"Alimentation","country":"FR","city":"Paris",
              "domain":"carrefour.fr","confidence":0.95,
              "search_query":"Carrefour Market Paris 11",
              "reasoning":"Carrefour Market enseigne FR, code postal 75011 = Paris 11e"}

    Input: "SUMUP*BOULANG MARIE LYON"
    Output : {"name":"Boulangerie Marie","category":"Alimentation","country":"FR","city":"Lyon",
              "domain":null,"confidence":0.7,
              "search_query":"Boulangerie Marie Lyon",
              "reasoning":"SUMUP = processeur, BOULANG abrégé pour Boulangerie"}

    RÈGLE : réponds UNIQUEMENT en JSON valide (pas de texte autour, pas de markdown).
    Schéma final :
    {
      "name": "Nom commercial extrait",
      "category": "Alimentation|Transport|Logement|Santé|Loisirs & Culture|Vêtements & Shopping|Voyages|Revenus|Banque & Finance|Autre",
      "country": "Code ISO 2 lettres OBLIGATOIRE",
      "city": "Ville si déductible sinon null",
      "domain": "domaine.tld si connu sinon null",
      "confidence": 0.85,
      "search_query": "Requête clean pour relancer une recherche cartographique",
      "reasoning": "Quels indices ont été utilisés (1 phrase)"
    }
    Confidence < 0.5 si tu doutes.
    """

    static func buildPrompt(context: MerchantEnrichmentContext) -> String {
        // We ALWAYS give the LLM the original raw label — it's what carries
        // the geographic clues (country codes, city names) that the canonical form may have
        // lost along the way.
        var lines = ["Libellé bancaire brut : \(context.rawLabel)"]
        if let canonical = context.canonicalName,
           !canonical.isEmpty,
           canonical.lowercased() != context.rawLabel.lowercased() {
            lines.append("Variante simplifiée (hypothèse) : \(canonical)")
        }
        if let amount = context.amount {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "EUR"
            formatter.locale = Locale(identifier: "fr_FR")
            if let s = formatter.string(from: NSNumber(value: amount)) {
                lines.append("Montant : \(s)")
                let absVal = abs(amount)
                if absVal < 15 && amount < 0 {
                    lines.append("Indice : montant faible (abonnement, café, péage, transport local possibles)")
                } else if absVal > 200 && amount < 0 {
                    lines.append("Indice : montant élevé (gros achat, voyage, hôtel, électronique possibles)")
                }
            }
        }
        if let city = context.city, !city.isEmpty {
            lines.append("Ville (déjà déduite) : \(city)")
        }
        if let country = context.country, !country.isEmpty {
            lines.append("Pays (déjà déduit) : \(country)")
        }
        lines.append("")
        lines.append("Identifie le marchand. Cherche d'abord ville + pays dans le libellé brut, puis le nom commercial.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Parser

    static func parseJSONResponse(_ raw: String, context: MerchantEnrichmentContext) -> MerchantEnrichment? {
        // Strip code fences if the model added them anyway
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Find the first { and the last }
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}")
        else { return nil }
        let jsonSubstring = String(cleaned[start...end])

        guard let data = jsonSubstring.data(using: .utf8),
              let payload = try? JSONDecoder().decode(LLMPayload.self, from: data)
        else { return nil }

        // We let the orchestrator do the category text → Nemoris category_id mapping
        // (it has access to the repo). Here we just store the raw fields: the category name
        // goes into `categoryHint`, which `EnrichmentOrchestrator.resolvingCategoryHint`
        // converts into `categoryId`. It used to be decoded then discarded.
        var result = MerchantEnrichment(
            displayName: payload.name,
            domain: payload.domain,
            categoryId: nil,
            address: nil,
            city: payload.city ?? context.city,
            country: payload.country ?? context.country,
            latitude: nil, longitude: nil,
            phone: nil, siret: nil, nafCode: nil,
            source: .llm,
            confidence: max(0, min(1, payload.confidence)),
            enrichedAt: Date(),
            searchHint: payload.search_query?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        )
        result.categoryHint = payload.category?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        return result
    }

    private struct LLMPayload: Decodable {
        let name: String?
        let category: String?
        let country: String?
        let city: String?
        let domain: String?
        let confidence: Double
        let reasoning: String?
        let search_query: String?
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
