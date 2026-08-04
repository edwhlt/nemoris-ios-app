import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// AXE B — Wrapper Apple Foundation Models (`LanguageModelSession`) pour l'enrichissement
/// de libellés bancaires. 100% on-device, gratuit, pas de clé API. iOS 26.0+.
///
/// Si le framework n'est pas disponible (iOS < 26.0) ou si le modèle n'est pas dispo
/// sur l'appareil, `identify(...)` renvoie nil — `AIEnrichmentBackend` (le point de
/// dispatch partagé) bascule alors vers `LocalLLMService` si l'utilisateur en a
/// configuré un, ou continue simplement avec Sirene + MapKit.
///
/// Privacy : aucun appel réseau, aucune télémétrie. Cohérent avec le projet privacy-first.
@MainActor
final class EnrichmentLLMService {

    static let shared = EnrichmentLLMService()

    /// Indique si le framework Foundation Models est disponible ET prêt sur cet appareil.
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Tente d'identifier un marchand à partir du libellé brut + contexte transaction.
    /// Renvoie un `MerchantEnrichment` avec source=.llm si succès, nil sinon.
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

    /// Complétion texte générique via Foundation Models. `nil` si le framework
    /// est indisponible ou si la génération échoue — même contrat de silence
    /// qu'`identify`. Utilisée par `AIEnrichmentBackend.completeText` pour les
    /// tâches qui ne sont pas de l'identification de marchand (extraction de
    /// relevés, notamment).
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
        // On donne TOUJOURS le libellé brut original au LLM — c'est lui qui contient
        // les indices géographiques (codes pays, noms de villes) que le canonical aurait
        // perdu en route.
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
        // Strip code fences si le modèle en a mis quand même
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Trouve le premier { et le dernier }
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}")
        else { return nil }
        let jsonSubstring = String(cleaned[start...end])

        guard let data = jsonSubstring.data(using: .utf8),
              let payload = try? JSONDecoder().decode(LLMPayload.self, from: data)
        else { return nil }

        // On laisse l'orchestrateur faire le mapping category text → category_id Nemoris
        // (il a accès au repo). Ici on stocke juste les champs bruts : le nom de catégorie
        // part dans `categoryHint`, que `EnrichmentOrchestrator.resolvingCategoryHint`
        // convertit en `categoryId`. Avant, il était décodé puis jeté.
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
