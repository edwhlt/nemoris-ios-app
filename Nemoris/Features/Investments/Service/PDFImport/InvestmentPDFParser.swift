import Foundation
import PDFKit
import Vision
import ImageIO
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

    // MARK: - Primitives partagées (OCR, décodage image)

    /// Décode des octets en `CGImage`.
    ///
    /// ⚠️ Par ImageIO, JAMAIS par UIImage/NSImage. Sur macOS, `UIImage` est un
    /// alias de `NSImage` et le shim `.cgImage` appelle
    /// `NSImage.cgImage(forProposedRect:context:hints:)` — une API AppKit à
    /// affinité thread principal. L'invoquer depuis une tâche détachée gelait
    /// l'app entière (symptôme macOS uniquement : sur iOS, `UIImage` n'a pas
    /// cette contrainte). `CGImageSource` est thread-safe et identique sur les
    /// deux plateformes.
    nonisolated static func decodeImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// OCR d'une image en mémoire, appelable HORS du main actor.
    ///
    /// ⚠️ Vision est SYNCHRONE et gourmand (1 à 5 s sur une capture plein
    /// écran). Appelé depuis un contexte `@MainActor`, il bloque le thread
    /// principal : l'app paraît figée et la barre de progression ne se peint
    /// jamais. Les appelants doivent l'exécuter dans un `Task.detached`.
    nonisolated static func ocrText(from data: Data) -> String? {
        guard let cgImage = decodeImage(from: data) else {
            print("[PDFParser] Data image illisible")
            return nil
        }
        return recognizeText(in: cgImage)
    }

    /// Reconnaissance de texte via Vision.
    nonisolated private static func recognizeText(in image: CGImage) -> String? {
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

    // MARK: - Parse universel (détecte le type de fichier)

    /// Chantier C — résultat d'un parsing de page/bloc : ordres OU positions
    /// (mode snapshot) + le mode détecté par l'IA.
    struct PageParse {
        var orders: [PDFExtractedOrder] = []
        var positions: [PDFExtractedPosition] = []
        var mode: PDFDocumentMode = .orders
        var isEmpty: Bool { orders.isEmpty && positions.isEmpty }
    }

    // MARK: - Détection du format par le CONTENU

    /// Délègue au sniffer partagé du pipeline. Conservé comme façade parce que
    /// le nom est utilisé un peu partout, mais la LOGIQUE n'existe plus qu'à un
    /// seul endroit — elle était dupliquée ici et dans les deux extensions de
    /// partage, avec le risque que les copies divergent.
    static func detectKind(data: Data, fileExtension: String = "") -> ImportSourceKind {
        ImportFormatSniffer.detect(data: data, fileExtension: fileExtension)
    }

    static func sniffFileExtension(data: Data) -> String? {
        ImportFormatSniffer.fileExtension(for: data)
    }

    static func looksLikeText(_ data: Data) -> Bool {
        ImportFormatSniffer.looksLikeText(data)
    }

    /// Interprète UNE unité déjà lue, image comprise.
    ///
    /// ⚠️ Ce parseur n'ouvre plus de fichiers et n'orchestre plus de batch : la
    /// lecture appartient à `ImportPipeline`. C'est ce qui répare au passage
    /// une asymétrie réelle — l'ancienne boucle appelait `textUnits`, qui JETAIT
    /// l'image, donc l'import d'investissements faisait systématiquement un OCR
    /// même avec un backend multimodal disponible. La décision AXE V « l'image
    /// passe au modèle, pas son OCR » n'avait été câblée que côté transactions,
    /// alors que la mise en page d'une capture de courtier (colonnes, PRU
    /// aligné à droite) porte exactement le même genre de sens.
    @MainActor func analyze(_ unit: ImportDocumentReader.Unit,
                            unitNumber: Int) async -> PDFPageResult {
        func failed(_ diagnostic: ImportUnitDiagnostic, kind: ImportSourceKind) -> PDFPageResult {
            PDFPageResult(pageNumber: unitNumber, rawText: "", orders: [],
                          detectedMode: .unknown, parsingNote: diagnostic.userMessage,
                          diagnostic: diagnostic, kind: kind)
        }

        switch unit.content {
        // ─── L'unité EST une image et un modèle sait la lire ────────────────
        case .image(let image):
            let raw = await AIEnrichmentBackend.completeText(
                feature: .investmentImport,
                system: Self.systemInstructions,
                user: "Extrais toutes les opérations et lignes de portefeuille visibles sur cette capture.",
                image: image
            )
            guard let raw else {
                return failed(.aiFailed("le modèle n'a pas pu lire l'image"), kind: .image)
            }
            let parsed = Self.parsePageResponse(raw, pageNumber: unitNumber)
            return PDFPageResult(
                pageNumber: unitNumber,
                // Le « texte lu » du diagnostic devient la réponse du modèle :
                // sur ce chemin aucun texte n'est extrait, et c'est la seule
                // chose qui reste exploitable pour comprendre un échec.
                rawText: raw,
                orders: parsed.orders, positions: parsed.positions,
                detectedMode: parsed.mode,
                parsingNote: parsed.isEmpty ? ImportUnitDiagnostic.nothingRecognized.userMessage : nil,
                diagnostic: parsed.isEmpty ? .nothingRecognized : .extracted,
                kind: .image
            )

        // ─── Format structuré (OFX de courtier) ─────────────────────────────
        // Les champs sont nommés par le format : ni modèle, ni ancrage ISIN.
        case .records(let payloads):
            let orders = payloads.compactMap { payload -> PDFExtractedOrder? in
                guard case .investmentOrder(let order) = payload else { return nil }
                return Self.convert(order, pageNumber: unitNumber)
            }
            return PDFPageResult(
                pageNumber: unitNumber, rawText: "", orders: orders,
                detectedMode: orders.isEmpty ? .unknown : .orders,
                parsingNote: orders.isEmpty ? ImportUnitDiagnostic.nothingRecognized.userMessage : nil,
                diagnostic: orders.isEmpty ? .nothingRecognized : .extracted,
                kind: unit.kind, usedDeterministicFallback: true
            )

        // ─── Table (CSV / feuille de classeur) ──────────────────────────────
        // Passe par l'écran de mapping des colonnes, en amont.
        case .grid:
            return failed(.malformedStructure("table non mappée"), kind: unit.kind)

        case .empty(let diagnostic):
            return failed(diagnostic, kind: unit.kind)

        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failed(unit.kind == .unknown ? .notTextContent : .noTextExtracted,
                              kind: unit.kind)
            }
            return await parseUnit(text: text, unitNumber: unitNumber, kind: unit.kind)
        }
    }

    /// Analyse d'une unité TEXTE : IA guidée → IA JSON → extraction
    /// déterministe. Chaque étage rattrape l'échec du précédent.
    @MainActor private func parseUnit(text: String, unitNumber: Int,
                                      kind: ImportSourceKind) async -> PDFPageResult {
        let (parsed, diagnostic) = await parsePage(text: text, pageNumber: unitNumber)

        // Extraction déterministe menée SYSTÉMATIQUEMENT, pas seulement en
        // repli : elle ne coûte rien (aucune I/O) et elle est exacte là où le
        // petit modèle embarqué dérape.
        //
        // ⚠️ Constaté sur une capture réelle à deux lignes : le modèle a
        // recopié le nom et l'ISIN de la PREMIÈRE opération sur la seconde.
        // Associer un libellé au bon code sur un texte OCR en colonne est
        // précisément ce qu'un ancrage par ISIN fait sans se tromper. On
        // réconcilie donc les deux sources plutôt que de choisir un camp.
        let deterministic = InvestmentStatementExtractor.extractOrders(from: text)
            .map { Self.convert($0, pageNumber: unitNumber) }

        let merged = Self.reconcile(ai: parsed.orders, deterministic: deterministic)
        let usedFallback = !deterministic.isEmpty && parsed.orders.isEmpty

        if !merged.isEmpty || !parsed.positions.isEmpty {
            return PDFPageResult(
                pageNumber: unitNumber, rawText: text,
                orders: merged, positions: parsed.positions,
                detectedMode: merged.isEmpty ? parsed.mode : .orders,
                // On garde la trace d'un échec IA même quand le déterministe a
                // sauvé la mise : c'est l'information utile en support.
                parsingNote: diagnostic.isFailure ? diagnostic.userMessage : nil,
                diagnostic: .extracted, kind: kind,
                usedDeterministicFallback: usedFallback
            )
        }

        let finalDiagnostic: ImportUnitDiagnostic = diagnostic.isFailure ? diagnostic : .nothingRecognized
        return PDFPageResult(
            pageNumber: unitNumber, rawText: text,
            orders: [], positions: [],
            detectedMode: .unknown,
            parsingNote: finalDiagnostic.userMessage,
            diagnostic: finalDiagnostic, kind: kind
        )
    }

    /// Fusionne les deux extractions.
    ///
    /// L'extraction déterministe fait AUTORITÉ sur les titres qu'elle a
    /// reconnus (elle lit les champs à leur place exacte autour de l'ISIN) ;
    /// l'IA complète avec ce que l'ancrage ISIN ne peut pas voir : opérations
    /// sans code ISIN, formats en prose, tickers.
    static func reconcile(ai: [PDFExtractedOrder],
                          deterministic: [PDFExtractedOrder]) -> [PDFExtractedOrder] {
        guard !deterministic.isEmpty else { return ai }

        let knownISINs = Set(deterministic.map { $0.isin.uppercased() }.filter { !$0.isEmpty })
        // Le ticker est le seul champ que le déterministe ne cherche pas.
        var tickerByISIN: [String: String] = [:]
        for order in ai where !order.isin.isEmpty && !order.ticker.isEmpty {
            tickerByISIN[order.isin.uppercased()] = order.ticker
        }

        var result = deterministic.map { order -> PDFExtractedOrder in
            var enriched = order
            if enriched.ticker.isEmpty, let ticker = tickerByISIN[order.isin.uppercased()] {
                enriched.ticker = ticker
            }
            return enriched
        }
        // Ajout des opérations que seule l'IA a vues. Filtrer sur l'ISIN évite
        // de réintroduire les doublons dont le modèle a mal recopié le code.
        result.append(contentsOf: ai.filter { !knownISINs.contains($0.isin.uppercased()) })
        return result
    }

    /// Pont moteur déterministe (pur) → modèle d'UI.
    static func convert(_ order: ExtractedStatementOrder, pageNumber: Int) -> PDFExtractedOrder {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return PDFExtractedOrder(
            orderType: order.orderType,
            assetName: order.assetName,
            ticker: "",
            isin: order.isin,
            quantity: order.quantity,
            unitPrice: order.unitPrice,
            fees: order.fees,
            executedAt: formatter.date(from: order.executedAt) ?? Date(),
            currency: order.currency,
            notes: order.notes,
            pageNumber: pageNumber,
            confidence: order.confidence
        )
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

    /// Parse une seule page via Foundation Models. Retourne ordres OU positions
    /// (mode snapshot) selon la classification faite par l'IA, PLUS un
    /// diagnostic — sans lui, un échec du modèle est indiscernable d'un
    /// document réellement vide côté UI.
    @MainActor private func parsePage(text: String, pageNumber: Int) async -> (PageParse, ImportUnitDiagnostic) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return await parsePageWithAI(text: text, pageNumber: pageNumber)
        }
        #endif
        print("[PDFParser] Foundation Models non disponible — repli déterministe")
        return (PageParse(), .aiUnavailable)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func parsePageWithAI(text: String, pageNumber: Int) async -> (PageParse, ImportUnitDiagnostic) {
        guard SystemLanguageModel.default.isAvailable else { return (PageParse(), .aiUnavailable) }

        // Le texte envoyé est borné : la fenêtre de contexte du modèle embarqué
        // est étroite et un dépassement fait échouer TOUTE la page.
        let payload = String(text.prefix(4000))

        // 1er choix : GÉNÉRATION GUIDÉE. Le schéma `@Generable` contraint le
        // décodage côté modèle — plus de JSON à réparer, et mesuré ~3× plus
        // rapide que la génération libre (7,5 s contre 21,4 s sur le même
        // relevé) parce que le modèle n'écrit plus la syntaxe.
        let session = LanguageModelSession(instructions: Self.guidedInstructions)
        do {
            let response = try await session.respond(
                to: Self.buildGuidedPrompt(text: payload),
                generating: AIStatementExtraction.self
            )
            let parsed = Self.convert(response.content, pageNumber: pageNumber)
            print("[PDFParser] Unité \(pageNumber) [guidé/\(parsed.mode.rawValue)] : \(parsed.orders.count) ordres, \(parsed.positions.count) positions")
            if !parsed.isEmpty { return (parsed, .extracted) }
        } catch {
            print("[PDFParser] Génération guidée KO unité \(pageNumber) : \(error)")
        }

        // 2e choix : génération libre + JSON. Conservée parce qu'un modèle peut
        // refuser un schéma qu'il honore mal sur un document atypique.
        let legacySession = LanguageModelSession(instructions: Self.systemInstructions)
        do {
            let response = try await legacySession.respond(
                to: Self.buildPagePrompt(pageText: payload, pageNumber: pageNumber))
            let parsed = Self.parsePageResponse(response.content, pageNumber: pageNumber)
            print("[PDFParser] Unité \(pageNumber) [JSON/\(parsed.mode.rawValue)] : \(parsed.orders.count) ordres, \(parsed.positions.count) positions")
            return (parsed, parsed.isEmpty ? .nothingRecognized : .extracted)
        } catch {
            print("[PDFParser] Erreur IA unité \(pageNumber) : \(error.localizedDescription)")
            return (PageParse(), .aiFailed(Self.humanize(error)))
        }
    }

    /// Message d'erreur lisible par l'utilisateur (les erreurs Foundation
    /// Models sont verbeuses et anglophones).
    @available(iOS 26.0, macOS 26.0, *)
    private static func humanize(_ error: Error) -> String {
        let raw = String(describing: error).lowercased()
        if raw.contains("context") || raw.contains("exceeded") {
            return "document trop long pour l'analyse en une fois"
        }
        if raw.contains("guardrail") || raw.contains("safety") {
            return "contenu refusé par les garde-fous du modèle"
        }
        if raw.contains("unavailable") || raw.contains("notready") {
            return "modèle indisponible pour le moment"
        }
        return "erreur du moteur d'analyse"
    }

    // MARK: - Schéma de génération guidée

    /// Schéma imposé au modèle. Chaque champ est NON optionnel : la génération
    /// guidée les remplit toujours, ce qui supprime la classe de bugs du
    /// décodage JSON (une clé manquante faisait perdre la page ENTIÈRE, pas
    /// seulement la ligne fautive).
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct AIStatementExtraction {
        @Guide(description: "orders si les lignes ont une date d'opération ; positions si c'est un état du portefeuille sans date ; unknown si aucune donnée")
        var mode: String
        @Guide(description: "Opérations datées : achats, ventes, dividendes", .count(0...25))
        var orders: [AIStatementOrder]
        @Guide(description: "Lignes détenues d'une capture de portefeuille", .count(0...25))
        var positions: [AIStatementPosition]
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct AIStatementOrder {
        @Guide(description: "BUY pour un achat, SELL pour une vente, DIV pour un dividende ou coupon")
        var orderType: String
        @Guide(description: "Nom réel du titre tel qu'il apparaît, jamais un mot générique comme Action ou ETF")
        var assetName: String
        @Guide(description: "Code ISIN de 12 caractères commençant par 2 lettres de pays, chaîne vide si absent")
        var isin: String
        @Guide(description: "Symbole boursier court, chaîne vide si absent")
        var ticker: String
        @Guide(description: "Nombre de titres de l'opération")
        var quantity: Double
        @Guide(description: "Prix unitaire d'exécution, 0 si le document ne le donne pas")
        var unitPrice: Double
        @Guide(description: "Frais ou commission, 0 si absent")
        var fees: Double
        @Guide(description: "Date d'exécution au format yyyy-MM-dd")
        var executedAt: String
        @Guide(description: "Code devise à 3 lettres, EUR par défaut")
        var currency: String
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct AIStatementPosition {
        @Guide(description: "Nom réel du titre détenu")
        var assetName: String
        @Guide(description: "Code ISIN de 12 caractères, chaîne vide si absent")
        var isin: String
        @Guide(description: "Symbole boursier court, chaîne vide si absent")
        var ticker: String
        @Guide(description: "Quantité détenue")
        var quantity: Double
        @Guide(description: "Prix de revient unitaire (PRU), 0 si absent")
        var averagePrice: Double
        @Guide(description: "Valorisation actuelle de la ligne, 0 si absente")
        var currentValue: Double
        @Guide(description: "Code devise à 3 lettres, EUR par défaut")
        var currency: String
    }

    /// Instructions de la génération guidée — volontairement COURTES (~500
    /// caractères contre 7 600 pour la génération libre) : le schéma porte
    /// déjà la structure, et chaque token d'instruction est pris sur la
    /// fenêtre de contexte disponible pour le document lui-même.
    @available(iOS 26.0, macOS 26.0, *)
    static let guidedInstructions = """
    Tu extrais des opérations d'investissement depuis un relevé bancaire, un avis d'opéré ou une capture d'écran d'application de courtage (le texte peut venir d'un OCR, donc être en colonne et mal aligné).

    Classement : mode = "orders" si les lignes portent une date d'opération ; "positions" si c'est un état du portefeuille (quantité + PRU, sans date) ; "unknown" si le document ne contient ni l'un ni l'autre.

    Correspondances : ACHAT, ACHAT COMPTANT, SOUSCRIPTION, BUY → BUY ; VENTE, CESSION, SELL → SELL ; COUPON, COUPONS, DIVIDENDE → DIV.
    Les dates sortent en yyyy-MM-dd. Les nombres sortent avec un point décimal (34.53, jamais 34,53).
    Un ISIN fait 12 caractères et commence par deux lettres de pays (FR, LU, IE, US, DE, NL).
    N'invente jamais une ligne : n'extrais que ce qui est écrit.
    """

    static func buildGuidedPrompt(text: String) -> String {
        """
        Extrais toutes les opérations de ce document :

        \(text)
        """
    }

    /// Conversion schéma guidé → modèle interne, avec les mêmes filtres de
    /// validité que le chemin JSON (date parsable, type d'ordre reconnu).
    @available(iOS 26.0, macOS 26.0, *)
    static func convert(_ extraction: AIStatementExtraction, pageNumber: Int) -> PageParse {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let orders: [PDFExtractedOrder] = extraction.orders.compactMap { raw in
            guard let executedAt = Self.parseDate(raw.executedAt, formatter: formatter),
                  let orderType = Self.normalizeOrderType(raw.orderType) else { return nil }
            return PDFExtractedOrder(
                orderType: orderType,
                assetName: raw.assetName.isEmpty ? "Inconnu" : raw.assetName,
                ticker: raw.ticker, isin: raw.isin.uppercased(),
                quantity: raw.quantity, unitPrice: raw.unitPrice, fees: raw.fees,
                executedAt: executedAt,
                currency: raw.currency.isEmpty ? "EUR" : raw.currency,
                notes: nil, pageNumber: pageNumber, confidence: 0.9
            )
        }

        let positions: [PDFExtractedPosition] = extraction.positions.compactMap { raw in
            guard raw.quantity > 0 else { return nil }
            return PDFExtractedPosition(
                assetName: raw.assetName.isEmpty ? "Inconnu" : raw.assetName,
                ticker: raw.ticker, isin: raw.isin.uppercased(),
                quantity: raw.quantity, averageBuyPrice: raw.averagePrice,
                currentValue: raw.currentValue > 0 ? raw.currentValue : nil,
                currency: raw.currency.isEmpty ? "EUR" : raw.currency,
                pageNumber: pageNumber, confidence: 0.9
            )
        }

        let mode: PDFDocumentMode = {
            switch extraction.mode.lowercased() {
            case "orders":    return .orders
            case "positions": return .positionsSnapshot
            default:          return orders.isEmpty ? (positions.isEmpty ? .unknown : .positionsSnapshot) : .orders
            }
        }()
        return PageParse(orders: orders, positions: positions, mode: mode)
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
        // Même réparation que côté transactions : isolement de l'objet ET
        // recollage des chaînes coupées par la mise en forme du modèle.
        let jsonStr = LenientJSON.extractObject(from: raw)
        guard jsonStr.contains("{") else {
            print("[PDFParser] Pas de JSON trouvé dans la réponse IA page \(pageNumber)")
            return PageParse()
        }
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
            guard let orderType = Self.normalizeOrderType(raw.order_type ?? "") else {
                print("[PDFParser] Type d'ordre inconnu '\(raw.order_type ?? "nil")' — ordre ignoré")
                return nil
            }
            return PDFExtractedOrder(
                orderType: orderType,
                assetName: raw.asset_name ?? "Inconnu",
                ticker: raw.ticker ?? "",
                isin: raw.isin ?? "",
                quantity: raw.quantity?.value ?? 0,
                unitPrice: raw.unit_price?.value ?? 0,
                fees: raw.fees?.value ?? 0,
                executedAt: executedAt,
                currency: raw.currency ?? "EUR",
                notes: raw.notes,
                pageNumber: pageNumber,
                confidence: max(0, min(1, raw.confidence?.value ?? 0.5))
            )
        }

        // Positions (mode snapshot) — on ignore les lignes sans quantité exploitable.
        let positions: [PDFExtractedPosition] = (payload.positions ?? []).compactMap { raw in
            let qty = raw.quantity?.value ?? 0
            guard qty > 0 else { return nil }
            let pru = raw.average_price?.value ?? 0
            return PDFExtractedPosition(
                assetName: raw.asset_name ?? "Inconnu",
                ticker: raw.ticker ?? "",
                isin: raw.isin ?? "",
                quantity: qty,
                averageBuyPrice: pru,
                currentValue: raw.current_value?.value,
                currency: raw.currency ?? "EUR",
                pageNumber: pageNumber,
                confidence: max(0, min(1, raw.confidence?.value ?? 0.5))
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

    /// Clé de regroupement commune : ISIN (prioritaire), sinon ticker, sinon nom.
    /// Partagée par les deux agrégations ET par l'UI, qui doit pouvoir cocher /
    /// décocher TOUS les éléments bruts d'un même groupe affiché.
    static func groupKey(isin: String, ticker: String, assetName: String) -> String {
        if !isin.isEmpty { return isin.uppercased() }
        if !ticker.isEmpty { return ticker.uppercased() }
        return assetName.uppercased()
    }

    /// Regroupe les ordres par ISIN (prioritaire) ou ticker.
    ///
    /// ⚠️ NE FILTRE PAS sur `isSelected` : c'est à l'appelant de le faire avant
    /// l'import. Filtrer ici faisait DISPARAÎTRE une ligne de l'aperçu dès
    /// qu'on la décochait (l'aperçu est construit depuis cette agrégation) —
    /// impossible de la re-cocher ensuite.
    static func aggregateByPosition(_ orders: [PDFExtractedOrder]) -> [PDFPositionGroup] {
        var groups: [String: PDFPositionGroup] = [:]

        for order in orders {
            let key = groupKey(isin: order.isin, ticker: order.ticker, assetName: order.assetName)

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
    ///
    /// ⚠️ NE FILTRE PAS sur `isSelected` (même raison que `aggregateByPosition`).
    static func aggregatePositions(_ positions: [PDFExtractedPosition]) -> [PDFExtractedPosition] {
        var groups: [String: PDFExtractedPosition] = [:]
        var order: [String] = []

        for position in positions {
            let key = groupKey(isin: position.isin, ticker: position.ticker,
                               assetName: position.assetName)

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

    /// Nombre tolérant : un petit modèle écrit souvent `"quantity": "7"` ou
    /// `"unit_price": "34,53"` au lieu d'un littéral numérique.
    ///
    /// ⚠️ Sans ça, `JSONDecoder` lève sur la ligne fautive et **toute la page**
    /// est perdue, pas seulement l'opération concernée — un document de dix
    /// opérations était jeté pour un seul champ mal typé.
    struct LenientDouble: Decodable {
        let value: Double?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let d = try? container.decode(Double.self) { value = d; return }
            if let i = try? container.decode(Int.self) { value = Double(i); return }
            if let s = try? container.decode(String.self) {
                value = InvestmentStatementExtractor.parseNumber(s)
                return
            }
            value = nil
        }
    }

    private struct AIPageResponse: Decodable {
        let mode: String?
        let orders: [AIOrder]?
        let positions: [AIPosition]?
        let page_note: String?
    }

    private struct AIOrder: Decodable {
        /// Optionnel : une clé absente ne doit pas invalider le lot entier.
        let order_type: String?
        let asset_name: String?
        let ticker: String?
        let isin: String?
        let quantity: LenientDouble?
        let unit_price: LenientDouble?
        let fees: LenientDouble?
        let executed_at: String?
        let currency: String?
        let notes: String?
        let confidence: LenientDouble?
    }

    private struct AIPosition: Decodable {
        let asset_name: String?
        let ticker: String?
        let isin: String?
        let quantity: LenientDouble?
        let average_price: LenientDouble?
        let current_value: LenientDouble?
        let currency: String?
        let confidence: LenientDouble?
    }
}
