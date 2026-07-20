import Foundation
import PDFKit
import Vision
#if canImport(UIKit)
import UIKit
#endif
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Extracteur + parser IA pour les relevés d'ordres d'investissement.
/// Supporte PDF, images (OCR via Vision), CSV et texte brut.
///
/// **Pipeline :**
/// 1. PDFKit extrait le texte brut page par page
/// 2. Apple Foundation Models (iOS 26+) analyse chaque page et identifie les ordres
/// 3. Les ordres sont agrégés par ISIN/ticker pour preview
///
/// **Universel :** le prompt IA est conçu pour gérer n'importe quel format bancaire
/// (Boursorama, Trade Republic, Degiro, Fortuneo, Bourse Direct, etc.)
final class InvestmentPDFParser: Sendable {

    @MainActor static let shared = InvestmentPDFParser()

    /// Indique si le parsing IA est disponible (Foundation Models iOS 26+).
    @MainActor var isAIAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    // MARK: - Extraction texte

    /// Extrait le texte brut de chaque page d'un PDF.
    func extractPages(from url: URL) -> [(pageNumber: Int, text: String)] {
        guard let document = PDFDocument(url: url) else {
            print("[PDFParser] Impossible d'ouvrir le PDF: \(url.lastPathComponent)")
            return []
        }
        var pages: [(Int, String)] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i),
                  let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            pages.append((i + 1, text))
        }
        print("[PDFParser] \(pages.count) pages avec texte extraites sur \(document.pageCount) total")
        return pages
    }

    // MARK: - Extraction image (OCR via Vision)

    /// Extrait le texte d'une image via Vision OCR.
    func extractTextFromImage(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            print("[PDFParser] Impossible de charger l'image: \(url.lastPathComponent)")
            return nil
        }
        return extractTextFromImageData(data)
    }

    /// Chantier C — OCR direct depuis des `Data` en mémoire (PhotosPicker :
    /// `loadTransferable(type: Data.self)`, aucune écriture disque).
    func extractTextFromImageData(_ data: Data) -> String? {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            print("[PDFParser] Data image illisible")
            return nil
        }
        return recognizeText(in: cgImage)
    }

    /// Chantier C — pipeline complet pour une image en mémoire (PhotosPicker).
    /// OCR → parsing IA bi-mode (ordres OU capture de portefeuille).
    @MainActor func parseImageData(_ data: Data) async -> [PDFPageResult] {
        guard let text = extractTextFromImageData(data) else { return [] }
        let parsed = await parsePage(text: text, pageNumber: 1)
        return [PDFPageResult(
            pageNumber: 1, rawText: text,
            orders: parsed.orders, positions: parsed.positions,
            detectedMode: parsed.mode,
            parsingNote: parsed.isEmpty ? "Aucun ordre ni position détecté dans l'image" : nil
        )]
    }

    /// Reconnaissance de texte via Vision.
    private func recognizeText(in image: CGImage) -> String? {
        var result: String?
        let request = VNRecognizeTextRequest { req, error in
            guard error == nil,
                  let observations = req.results as? [VNRecognizedTextObservation]
            else { return }
            result = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["fr-FR", "en-US", "de-DE"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return result
    }

    // MARK: - Extraction texte brut (CSV / TXT)

    /// Lit un fichier texte brut (CSV, TXT, etc.)
    func extractTextFromFile(at url: URL) -> String? {
        if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty { return text }
        if let text = try? String(contentsOf: url, encoding: .windowsCP1252), !text.isEmpty { return text }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1), !text.isEmpty { return text }
        print("[PDFParser] Impossible de lire le fichier texte: \(url.lastPathComponent)")
        return nil
    }

    // MARK: - Parse universel (détecte le type de fichier)

    /// Chantier C — résultat d'un parsing de page/bloc : ordres OU positions
    /// (mode snapshot) + le mode détecté par l'IA.
    struct PageParse {
        var orders: [PDFExtractedOrder] = []
        var positions: [PDFExtractedPosition] = []
        var mode: PDFDocumentMode = .orders
        var isEmpty: Bool { orders.isEmpty && positions.isEmpty }
    }

    /// Point d'entrée universel — détecte le type de fichier et dispatch.
    @MainActor func parseFile(
        from url: URL,
        onPageParsed: @escaping (Int, Int) -> Void
    ) async -> [PDFPageResult] {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return await parseAllPages(from: url, onPageParsed: onPageParsed)

        case "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "webp":
            onPageParsed(0, 1)
            guard let text = extractTextFromImage(at: url) else {
                onPageParsed(1, 1)
                return []
            }
            let parsed = await parsePage(text: text, pageNumber: 1)
            onPageParsed(1, 1)
            return [PDFPageResult(
                pageNumber: 1, rawText: text,
                orders: parsed.orders, positions: parsed.positions, detectedMode: parsed.mode,
                parsingNote: parsed.isEmpty ? "Aucun ordre ni position détecté dans l'image" : nil
            )]

        case "csv", "txt", "tsv":
            // Pour les fichiers texte, on découpe par blocs de ~4000 chars pour
            // ne pas dépasser la capacité du modèle et améliorer la granularité.
            guard let text = extractTextFromFile(at: url) else {
                onPageParsed(1, 1)
                return []
            }
            let chunks = Self.splitTextIntoChunks(text, maxChars: 4000)
            var results: [PDFPageResult] = []
            for (index, chunk) in chunks.enumerated() {
                let parsed = await parsePage(text: chunk, pageNumber: index + 1)
                results.append(PDFPageResult(
                    pageNumber: index + 1, rawText: chunk,
                    orders: parsed.orders, positions: parsed.positions, detectedMode: parsed.mode,
                    parsingNote: parsed.isEmpty ? "Aucun ordre détecté dans ce bloc" : nil
                ))
                onPageParsed(index + 1, chunks.count)
            }
            return results

        default:
            // Tente comme texte brut en dernier recours
            guard let text = extractTextFromFile(at: url) else {
                onPageParsed(1, 1)
                return []
            }
            let parsed = await parsePage(text: text, pageNumber: 1)
            onPageParsed(1, 1)
            return [PDFPageResult(
                pageNumber: 1, rawText: text,
                orders: parsed.orders, positions: parsed.positions, detectedMode: parsed.mode,
                parsingNote: parsed.isEmpty ? "Format non reconnu, aucun ordre détecté" : nil
            )]
        }
    }

    /// Découpe un long texte en chunks d'environ `maxChars`, en coupant sur les sauts de ligne.
    static func splitTextIntoChunks(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var chunks: [String] = []
        var current = ""
        for line in text.components(separatedBy: .newlines) {
            if current.count + line.count + 1 > maxChars && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - Parsing IA page par page

    /// Parse toutes les pages d'un PDF via l'IA. Retourne les résultats page par page.
    /// `onPageParsed` est appelé après chaque page pour le feedback progressif.
    @MainActor func parseAllPages(
        from url: URL,
        onPageParsed: @escaping (Int, Int) -> Void
    ) async -> [PDFPageResult] {
        let pages = extractPages(from: url)
        guard !pages.isEmpty else { return [] }

        var results: [PDFPageResult] = []
        for (index, (pageNumber, text)) in pages.enumerated() {
            let parsed = await parsePage(text: text, pageNumber: pageNumber)
            let note = parsed.isEmpty ? "Aucun ordre détecté sur cette page" : nil
            results.append(PDFPageResult(
                pageNumber: pageNumber,
                rawText: text,
                orders: parsed.orders,
                positions: parsed.positions,
                detectedMode: parsed.mode,
                parsingNote: note
            ))
            onPageParsed(index + 1, pages.count)
        }
        return results
    }

    /// Parse une seule page via Foundation Models. Retourne ordres OU positions
    /// (mode snapshot) selon la classification faite par l'IA.
    @MainActor private func parsePage(text: String, pageNumber: Int) async -> PageParse {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return await parsePageWithAI(text: text, pageNumber: pageNumber)
        }
        #endif
        print("[PDFParser] Foundation Models non disponible — parsing impossible")
        return PageParse()
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func parsePageWithAI(text: String, pageNumber: Int) async -> PageParse {
        guard SystemLanguageModel.default.isAvailable else { return PageParse() }

        let prompt = Self.buildPagePrompt(pageText: text, pageNumber: pageNumber)
        let session = LanguageModelSession(instructions: Self.systemInstructions)

        do {
            let response = try await session.respond(to: prompt)
            let parsed = Self.parsePageResponse(response.content, pageNumber: pageNumber)
            print("[PDFParser] Page \(pageNumber) [\(parsed.mode.rawValue)]: \(parsed.orders.count) ordres, \(parsed.positions.count) positions")
            return parsed
        } catch {
            print("[PDFParser] Erreur IA page \(pageNumber): \(error.localizedDescription)")
            return PageParse()
        }
    }
    #endif

    // MARK: - Prompt système

    static let systemInstructions = """
    Tu es un assistant spécialisé dans l'extraction de données d'investissement depuis des relevés bancaires ET des captures d'écran d'applications de courtage.

    Tu reçois le texte brut d'UNE PAGE (relevé PDF) ou d'UNE CAPTURE D'ÉCRAN (OCR d'un screenshot d'app).

    ÉTAPE 1 — CLASSIFIE D'ABORD LE DOCUMENT dans l'un de ces 2 modes :

    • mode = "orders" → RELEVÉ D'ORDRES / AVIS D'OPÉRÉ : contient des OPÉRATIONS datées
      (achat, vente, dividende) avec une DATE D'EXÉCUTION, un cours d'exécution, une quantité.
      Indices : "Avis d'opéré", "Ordre exécuté le", "Date d'exécution", "Cours d'exécution".

    • mode = "positions" → CAPTURE DE PORTEFEUILLE / ÉTAT DES POSITIONS : une LISTE de lignes
      détenues (une par titre), avec quantité, PRU (prix de revient unitaire) et/ou valeur de
      marché actuelle, SANS dates d'exécution. C'est typiquement un SCREENSHOT de l'écran
      "Portefeuille"/"Positions" d'une app (PEA Boursorama, Trade Republic, Degiro, Fortuneo…).
      Indices : colonnes "PRU", "Prix de revient", "+/- value", "Plus-value", "Valorisation",
      "Quantité" affichées ensemble pour PLUSIEURS titres, sans date d'opération.

    Si le document contient les deux, privilégie "orders" (plus précis pour l'historique).
    Si tu ne peux pas trancher, choisis le mode qui a le plus de données exploitables.

    CONTEXTE :
    - Le document peut venir de N'IMPORTE QUELLE banque ou courtier (Boursorama, Trade Republic, Degiro, Fortuneo, Bourse Direct, Saxo, Interactive Brokers, Binck, etc.)
    - Chaque banque a son propre format, ses propres colonnes, ses propres abréviations
    - Les tableaux sont souvent mal structurés en texte brut (surtout en OCR de screenshot) — tu dois reconstituer les lignes
    - Les montants peuvent utiliser la virgule (FR) ou le point (US/UK) comme séparateur décimal
    - Les dates peuvent être dd/MM/yyyy, yyyy-MM-dd, dd.MM.yyyy, MM/dd/yyyy, etc.

    RÈGLE CRUCIALE — CHAQUE PAGE CONTIENT PROBABLEMENT AU MOINS UN ORDRE :
    - La plupart des relevés d'ordres ont 1 ordre par page (avis d'opéré)
    - Si tu vois un ISIN, un nom de titre, un montant ET une date sur la page → il y a un ordre
    - Cherche TRÈS ATTENTIVEMENT avant de conclure qu'une page est vide
    - Les informations d'un ordre peuvent être éparpillées sur toute la page (en-tête, corps, pied)

    CE QUE TU CHERCHES (les 3 types d'ordres) :
    1. **Achats** → order_type = "BUY"
       - Indices : "Achat", "Acquisition", "Buy", "Kauf", "Souscription", "Ordre d'achat", "ACH"
    2. **Ventes** → order_type = "SELL"
       - Indices : "Vente", "Cession", "Sell", "Verkauf", "Ordre de vente", "VTE", "Rachat"
    3. **Dividendes** → order_type = "DIV"
       - Indices : "Dividende", "Dividend", "Coupon", "Distribution", "Détachement de coupon", "Acompte sur dividende"

    INFORMATIONS À EXTRAIRE PAR ORDRE :
    - **asset_name** : le NOM COMPLET ET RÉEL du titre/instrument (ex: "Amundi MSCI World UCITS ETF Acc", "LVMH Moët Hennessy Louis Vuitton SE", "TotalEnergies SE"). JAMAIS un terme générique comme "Action", "ETF", "Fonds", "Titre" — cherche le vrai nom dans le texte de la page.
    - **isin** : code ISIN 12 caractères (commence par 2 lettres pays : FR, LU, IE, US, DE, NL…). Toujours présent sur les avis d'opéré.
    - **ticker** : symbole boursier court (CW8, AAPL, MC, TTE, BNP…). Peut être absent.
    - **quantity** : nombre de parts/actions (peut être décimal pour les ETF/fonds)
    - **unit_price** : prix unitaire d'exécution (cours d'exécution, PAS le montant total)
    - **fees** : frais/commission. 0 si non indiqué ou non trouvé. Cherche "commission", "frais", "courtage".
    - **executed_at** : date d'exécution. Format OBLIGATOIRE en sortie : yyyy-MM-dd (PAS d'heure, PAS de T)
    - **currency** : devise (EUR par défaut si non précisé)
    - **notes** : infos complémentaires utiles (type de marché, numéro d'ordre, etc.)
    - **confidence** : 0.0 à 1.0

    GESTION DES TABLEAUX ET TEXTE LIBRE :
    - Les colonnes sont souvent séparées par des espaces multiples ou des tabulations
    - Une ligne peut déborder sur la suivante (nom de titre long)
    - L'ISIN et le nom du titre sont souvent sur des lignes différentes — relie-les
    - Sur un avis d'opéré Boursorama, le nom est en haut de page, l'ISIN en dessous, le prix/quantité dans un tableau au milieu
    - Reconstitue la structure en identifiant les patterns récurrents

    EXEMPLES BOURSORAMA (avis d'opéré, 1 page = 1 ordre) :
    - "Avis d'opéré" + "Achat au marché" → BUY
    - "Avis d'opéré" + "Vente au marché" ou "Vente à cours limité" → SELL
    - "Avis de crédit" + "Dividende" → DIV
    - Le nom du titre est souvent en gras/gros en haut : "AMUNDI MSCI WORLD UCITS ETF - EUR (C)"
    - L'ISIN est juste en dessous : "Code ISIN : LU1681043599"
    - Quantité : "Quantité exécutée : 2,000" (attention virgule = séparateur décimal FR)
    - Cours : "Cours d'exécution : 485,30 EUR"
    - Frais : "Commission : 1,99 EUR" ou "Courtage : 0,00 EUR"

    POUR LE MODE "positions" (capture de portefeuille), EXTRAIS CHAQUE LIGNE DÉTENUE :
    - **asset_name** : nom réel du titre (jamais générique)
    - **isin** : ISIN si visible (souvent absent des screenshots d'app — laisse "" sinon)
    - **ticker** : symbole court si visible
    - **quantity** : quantité détenue (nombre de parts/actions, décimal possible)
    - **average_price** : PRU / prix de revient unitaire (colonne "PRU", "Prix de revient")
    - **current_value** : valeur de marché ACTUELLE de la ligne (colonne "Valorisation",
      "Valeur", "Montant") si affichée. Si seul le cours actuel est affiché, multiplie
      par la quantité. Laisse null si vraiment introuvable.
    - **currency** : devise (EUR par défaut)
    - **confidence** : 0.0 à 1.0

    RÈGLE ABSOLUE : réponds UNIQUEMENT en JSON valide. Pas de texte autour, pas de markdown.
    Format (le champ "mode" est OBLIGATOIRE) :
    {
      "mode": "orders",
      "orders": [
        {
          "order_type": "BUY",
          "asset_name": "Amundi MSCI World UCITS ETF Acc",
          "ticker": "CW8",
          "isin": "LU1681043599",
          "quantity": 2.0,
          "unit_price": 485.30,
          "fees": 1.99,
          "executed_at": "2024-03-15",
          "currency": "EUR",
          "notes": "PEA — ordre au marché",
          "confidence": 0.95
        }
      ],
      "positions": [],
      "page_note": "Avis d'opéré achat Boursorama"
    }

    Exemple mode capture de portefeuille (screenshot d'app) :
    {
      "mode": "positions",
      "orders": [],
      "positions": [
        {
          "asset_name": "Amundi MSCI World UCITS ETF Acc",
          "isin": "LU1681043599",
          "ticker": "CW8",
          "quantity": 12.0,
          "average_price": 420.10,
          "current_value": 5823.60,
          "currency": "EUR",
          "confidence": 0.9
        }
      ],
      "page_note": "Capture portefeuille PEA Boursorama"
    }

    Si VRAIMENT rien n'est détecté (page de couverture, CGV, récapitulatif sans détails) :
    { "mode": "unknown", "orders": [], "positions": [], "page_note": "Page sans données exploitables" }

    RAPPELS CRITIQUES :
    - "mode" est TOUJOURS présent : "orders", "positions" ou "unknown"
    - Dates en sortie : TOUJOURS yyyy-MM-dd (jamais d'heure, jamais de T)
    - Montants en sortie : TOUJOURS le point comme séparateur décimal (1234.56 pas 1234,56)
    - asset_name : TOUJOURS le nom réel du titre, JAMAIS "Action" ou "ETF" tout seul
    - order_type : TOUJOURS "BUY", "SELL" ou "DIV" (en anglais)
    - En mode "positions", NE PAS inventer de dates : il n'y en a pas
    """

    static func buildPagePrompt(pageText: String, pageNumber: Int) -> String {
        """
        Voici le texte brut extrait de la PAGE \(pageNumber) d'un relevé d'ordres d'investissement.
        Identifie tous les ordres (achat, vente, dividende) présents.

        --- DÉBUT TEXTE PAGE \(pageNumber) ---
        \(pageText.prefix(8000))
        --- FIN TEXTE PAGE \(pageNumber) ---

        Extrais les ordres au format JSON spécifié.
        """
    }

    // MARK: - JSON Parser

    /// Chantier C — parse la réponse IA bi-mode (ordres OU positions) en `PageParse`.
    static func parsePageResponse(_ raw: String, pageNumber: Int) -> PageParse {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip markdown code fences
        if cleaned.hasPrefix("```") {
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Trouver le JSON
        guard let start = cleaned.firstIndex(of: "{"),
              let end = cleaned.lastIndex(of: "}")
        else {
            print("[PDFParser] Pas de JSON trouvé dans la réponse IA page \(pageNumber)")
            return PageParse()
        }
        let jsonStr = String(cleaned[start...end])

        guard let data = jsonStr.data(using: .utf8),
              let payload = try? JSONDecoder().decode(AIPageResponse.self, from: data)
        else {
            print("[PDFParser] Décodage JSON échoué page \(pageNumber)")
            return PageParse()
        }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // Ordres (tolérant : même sans "mode", on parse les ordres présents)
        let orders: [PDFExtractedOrder] = (payload.orders ?? []).compactMap { raw in
            let date = Self.parseDate(raw.executed_at, formatter: dateFormatter)
            guard let executedAt = date else {
                print("[PDFParser] Date invalide '\(raw.executed_at ?? "nil")' — ordre ignoré")
                return nil
            }
            guard let orderType = Self.normalizeOrderType(raw.order_type) else {
                print("[PDFParser] Type d'ordre inconnu '\(raw.order_type)' — ordre ignoré")
                return nil
            }
            return PDFExtractedOrder(
                orderType: orderType,
                assetName: raw.asset_name ?? "Inconnu",
                ticker: raw.ticker ?? "",
                isin: raw.isin ?? "",
                quantity: raw.quantity ?? 0,
                unitPrice: raw.unit_price ?? 0,
                fees: raw.fees ?? 0,
                executedAt: executedAt,
                currency: raw.currency ?? "EUR",
                notes: raw.notes,
                pageNumber: pageNumber,
                confidence: max(0, min(1, raw.confidence ?? 0.5))
            )
        }

        // Positions (mode snapshot) — on ignore les lignes sans quantité exploitable.
        let positions: [PDFExtractedPosition] = (payload.positions ?? []).compactMap { raw in
            let qty = raw.quantity ?? 0
            guard qty > 0 else { return nil }
            let pru = raw.average_price ?? 0
            return PDFExtractedPosition(
                assetName: raw.asset_name ?? "Inconnu",
                ticker: raw.ticker ?? "",
                isin: raw.isin ?? "",
                quantity: qty,
                averageBuyPrice: pru,
                currentValue: raw.current_value,
                currency: raw.currency ?? "EUR",
                pageNumber: pageNumber,
                confidence: max(0, min(1, raw.confidence ?? 0.5))
            )
        }

        // Mode : celui déclaré par l'IA (l'IA écrit "positions", pas
        // "positionsSnapshot"), avec fallback déduit du contenu.
        let mode: PDFDocumentMode = {
            switch payload.mode?.lowercased() {
            case "orders":               return .orders
            case "positions":            return .positionsSnapshot
            case "positionssnapshot":    return .positionsSnapshot
            default:
                if !orders.isEmpty { return .orders }
                if !positions.isEmpty { return .positionsSnapshot }
                return .unknown
            }
        }()

        return PageParse(orders: orders, positions: positions, mode: mode)
    }

    /// Compat : ancienne signature (ordres seuls) — conservée si un appelant l'utilise.
    static func parseOrdersFromJSON(_ raw: String, pageNumber: Int) -> [PDFExtractedOrder] {
        parsePageResponse(raw, pageNumber: pageNumber).orders
    }

    /// Normalise les types d'ordre retournés par l'IA vers BUY/SELL/DIV.
    /// L'IA peut retourner des variantes FR, EN, ou longues.
    static func normalizeOrderType(_ raw: String) -> String? {
        let upper = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // Achats
        if ["BUY", "ACHAT", "ACH", "PURCHASE", "KAUF", "ACQUISTO", "COMPRA"].contains(upper) { return "BUY" }
        // Ventes
        if ["SELL", "VENTE", "VTE", "SALE", "VERKAUF", "VENDITA", "VENTA"].contains(upper) { return "SELL" }
        // Dividendes
        if ["DIV", "DIVIDEND", "DIVIDENDE", "DIVIDENDO", "COUPON", "DISTRIBUTION"].contains(upper) { return "DIV" }
        // Fallback pattern matching
        if upper.contains("BUY") || upper.contains("ACHAT") { return "BUY" }
        if upper.contains("SELL") || upper.contains("VENT") { return "SELL" }
        if upper.contains("DIV") || upper.contains("COUPON") { return "DIV" }
        return nil
    }

    /// Parse une date avec plusieurs formats courants dans les relevés bancaires.
    static func parseDate(_ string: String?, formatter: DateFormatter) -> Date? {
        guard var s = string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }

        // Strip composante heure si l'IA retourne un ISO 8601 complet (ex: "2025-03-03T14:07:14")
        if let tIndex = s.firstIndex(of: "T"), s.distance(from: s.startIndex, to: tIndex) >= 8 {
            s = String(s[..<tIndex])
        }

        let formats = [
            "yyyy-MM-dd",
            "dd/MM/yyyy",
            "dd.MM.yyyy",
            "MM/dd/yyyy",
            "yyyy/MM/dd",
            "dd-MM-yyyy",
            "d/M/yyyy",
            "d.M.yyyy"
        ]
        for fmt in formats {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: s) { return d }
        }
        return nil
    }

    // MARK: - Agrégation par position

    /// Regroupe les ordres sélectionnés par ISIN (prioritaire) ou ticker.
    static func aggregateByPosition(_ orders: [PDFExtractedOrder]) -> [PDFPositionGroup] {
        let selected = orders.filter { $0.isSelected }
        var groups: [String: PDFPositionGroup] = [:]

        for order in selected {
            // Clé de regroupement : ISIN si disponible, sinon ticker
            let key: String
            if !order.isin.isEmpty {
                key = order.isin.uppercased()
            } else if !order.ticker.isEmpty {
                key = order.ticker.uppercased()
            } else {
                key = order.assetName.uppercased()
            }

            if var existing = groups[key] {
                existing.orders.append(order)
                groups[key] = existing
            } else {
                groups[key] = PDFPositionGroup(
                    isin: order.isin,
                    ticker: order.ticker,
                    assetName: order.assetName,
                    assetType: order.assetType,
                    orders: [order]
                )
            }
        }

        return Array(groups.values).sorted { $0.assetName < $1.assetName }
    }

    /// Chantier C — dédup des positions extraites d'une capture (mode snapshot)
    /// par ISIN > ticker > nom. Additionne les quantités si la même ligne apparaît
    /// sur plusieurs chunks/pages ; garde le PRU et la valeur de la 1re occurrence
    /// (une capture n'affiche qu'une valeur par ligne).
    static func aggregatePositions(_ positions: [PDFExtractedPosition]) -> [PDFExtractedPosition] {
        let selected = positions.filter { $0.isSelected }
        var groups: [String: PDFExtractedPosition] = [:]
        var order: [String] = []

        for position in selected {
            let key: String
            if !position.isin.isEmpty { key = position.isin.uppercased() }
            else if !position.ticker.isEmpty { key = position.ticker.uppercased() }
            else { key = position.assetName.uppercased() }

            if var existing = groups[key] {
                existing.quantity += position.quantity
                if let extra = position.currentValue {
                    existing.currentValue = (existing.currentValue ?? 0) + extra
                }
                groups[key] = existing
            } else {
                groups[key] = position
                order.append(key)
            }
        }
        return order.compactMap { groups[$0] }
    }

    // MARK: - DTO décodage IA

    private struct AIPageResponse: Decodable {
        let mode: String?
        let orders: [AIOrder]?
        let positions: [AIPosition]?
        let page_note: String?
    }

    private struct AIOrder: Decodable {
        let order_type: String
        let asset_name: String?
        let ticker: String?
        let isin: String?
        let quantity: Double?
        let unit_price: Double?
        let fees: Double?
        let executed_at: String?
        let currency: String?
        let notes: String?
        let confidence: Double?
    }

    private struct AIPosition: Decodable {
        let asset_name: String?
        let ticker: String?
        let isin: String?
        let quantity: Double?
        let average_price: Double?
        let current_value: Double?
        let currency: String?
        let confidence: Double?
    }
}
