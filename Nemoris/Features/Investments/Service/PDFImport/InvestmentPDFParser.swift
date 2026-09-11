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

/// Extractor + AI parser for investment order statements.
/// Supports PDF, images (OCR via Vision), CSV and plain text.
///
/// **Pipeline:**
/// 1. PDFKit extracts the raw text page by page
/// 2. The configured AI backend analyzes each page and identifies the orders
/// 3. Orders are aggregated by ISIN/ticker for the preview
///
/// **Universal:** the AI prompt is designed to handle any bank format
/// (Boursorama, Trade Republic, Degiro, Fortuneo, Bourse Direct, etc.)
/// The prompt text stays in French: it is content for a model asked to answer
/// the user in their own language.
final class InvestmentPDFParser: Sendable {

    @MainActor static let shared = InvestmentPDFParser()

    /// Whether AI parsing is available (Foundation Models iOS 26+).
    @MainActor var isAIAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    // MARK: - Shared primitives (OCR, image decoding)

    /// Decodes bytes into a `CGImage`.
    ///
    /// Through ImageIO, NEVER through UIImage/NSImage. On macOS, `UIImage` is an
    /// alias of `NSImage` and the `.cgImage` shim calls
    /// `NSImage.cgImage(forProposedRect:context:hints:)` — an AppKit API with
    /// main-thread affinity. Invoking it from a detached task freezes the whole
    /// app (macOS only: on iOS, `UIImage` has no such constraint). `CGImageSource`
    /// is thread-safe and identical on both platforms.
    nonisolated static func decodeImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// OCR of an in-memory image, callable OFF the main actor.
    ///
    /// Vision is SYNCHRONOUS and expensive (1 to 5 s on a full-screen capture).
    /// Called from a `@MainActor` context, it blocks the main thread: the app
    /// looks frozen and the progress bar never paints. Callers must run it in a
    /// `Task.detached`.
    nonisolated static func ocrText(from data: Data) -> String? {
        guard let cgImage = decodeImage(from: data) else {
            print("[PDFParser] Data image illisible")
            return nil
        }
        return recognizeText(in: cgImage)
    }

    /// Rasterizes ONE PDF page into a `CGImage`, to hand it to a multimodal model
    /// — the real layout (columns, table) stays visible, unlike the text that
    /// `PDFPage.string` flattens into a sequence of lines with no notion of
    /// columns left.
    ///
    /// Through a raw bitmap `CGContext` + `PDFPage.draw(with:to:)`, never through
    /// `PDFPage.thumbnail(of:for:)`: that API returns a `UIImage`/`NSImage`, and
    /// getting a `CGImage` out of it falls into the same trap as `decodeImage`
    /// above (`.cgImage` of an `NSImage` is an AppKit API with main-thread
    /// affinity on macOS). `CGContext`/`PDFDocument` are thread-safe, so this is
    /// callable from a `Task.detached`.
    ///
    /// No vertical flip needed: a bitmap `CGContext` created via
    /// `CGContext(data:...)` has, like PDF space, its origin at the bottom left —
    /// it's `UIGraphicsImageRenderer` (UIKit-style top-left origin) that would
    /// have required the opposite.
    nonisolated static func renderPageImage(pdfData: Data, pageIndex: Int, scale: CGFloat = 2.0) -> CGImage? {
        guard let document = PDFDocument(data: pdfData),
              pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex)
        else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
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

    // MARK: - Universal parse (detects the file type)

    /// Result of parsing a page/block: orders OR positions (snapshot mode) + the
    /// mode detected by the AI.
    struct PageParse {
        var orders: [PDFExtractedOrder] = []
        var positions: [PDFExtractedPosition] = []
        var mode: PDFDocumentMode = .orders
        var isEmpty: Bool { orders.isEmpty && positions.isEmpty }
    }

    // MARK: - Format detection by CONTENT

    /// Delegates to the pipeline's shared sniffer. Kept as a façade because the
    /// name is used in many places, but the LOGIC exists in one place only.
    static func detectKind(data: Data, fileExtension: String = "") -> ImportSourceKind {
        ImportFormatSniffer.detect(data: data, fileExtension: fileExtension)
    }

    static func sniffFileExtension(data: Data) -> String? {
        ImportFormatSniffer.fileExtension(for: data)
    }

    static func looksLikeText(_ data: Data) -> Bool {
        ImportFormatSniffer.looksLikeText(data)
    }

    /// Interprets ONE already-read unit, images included.
    ///
    /// This parser neither opens files nor orchestrates batches: reading belongs
    /// to `ImportPipeline`. An image unit goes to the model as an image when a
    /// backend can read one — the layout of a broker capture (columns, average
    /// cost right-aligned) carries meaning that OCR would flatten, exactly as for
    /// the transaction import.
    @MainActor func analyze(_ unit: ImportDocumentReader.Unit,
                            unitNumber: Int) async -> PDFPageResult {
        func failed(_ diagnostic: ImportUnitDiagnostic, kind: ImportSourceKind) -> PDFPageResult {
            PDFPageResult(pageNumber: unitNumber, rawText: "", orders: [],
                          detectedMode: .unknown, parsingNote: diagnostic.userMessage,
                          diagnostic: diagnostic, kind: kind)
        }

        switch unit.content {
        // ─── The unit IS an image and a model can read it ───────────────────
        case .image(let image):
            let raw = await AIEnrichmentBackend.completeText(
                feature: .investmentImport,
                system: Self.systemInstructions,
                user: "Extrais toutes les opérations et lignes de portefeuille visibles sur cette capture.",
                image: image
            )
            let parsed = raw.map { Self.parsePageResponse($0, pageNumber: unitNumber) } ?? PageParse()

            // OCR fallback when reading the image yields NOTHING. The model is otherwise
            // the only source, so a truncated answer or an unrepairable JSON would give
            // "0 operations" — and since generation isn't deterministic, the SAME capture
            // would sometimes give N operations, sometimes none. OCR brings back text,
            // hence the deterministic extraction AND a second chance for the model.
            if parsed.isEmpty, let data = unit.imageSourceData,
               let text = await Task.detached(priority: .userInitiated, operation: {
                   Self.ocrText(from: data)
               }).value,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                print("[PDFParser] Unité \(unitNumber) : lecture image sans résultat, repli OCR")
                // The diagnostic's "text read" becomes the OCR, not the model's empty
                // answer: that's what shows what the app actually saw in the capture.
                return await parseUnit(text: text, unitNumber: unitNumber, kind: .image)
            }

            guard raw != nil else {
                return failed(.aiFailed("le modèle n'a pas pu lire l'image"), kind: .image)
            }
            return PDFPageResult(
                pageNumber: unitNumber,
                // The diagnostic's "text read" becomes the model's answer: no text is
                // extracted on this path, and it's the only thing left to understand a
                // failure.
                rawText: raw ?? "",
                orders: StatementReconciler.dedupe(parsed.orders),
                positions: parsed.positions,
                detectedMode: parsed.mode,
                parsingNote: parsed.isEmpty ? ImportUnitDiagnostic.nothingRecognized.userMessage : nil,
                diagnostic: parsed.isEmpty ? .nothingRecognized : .extracted,
                kind: .image
            )

        // ─── Structured format (broker OFX) ─────────────────────────────────
        // The fields are named by the format: no model, no ISIN anchoring.
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

        // ─── Table (CSV / spreadsheet sheet) ────────────────────────────────
        // Goes through the column mapping screen, upstream.
        case .grid:
            return failed(.malformedStructure("table non mappée"), kind: unit.kind)

        case .empty(let diagnostic):
            return failed(diagnostic, kind: unit.kind)

        case .text(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return failed(unit.kind == .unknown ? .notTextContent : .noTextExtracted,
                              kind: unit.kind)
            }
            return await parseUnit(text: text, unitNumber: unitNumber, kind: unit.kind,
                                   pdfSourceData: unit.pdfSourceData, pdfPageIndex: unit.pdfPageIndex)
        }
    }

    /// Analysis of a TEXT unit.
    ///
    /// ─── Reading order: THE IMAGE FIRST when a model can read it ────────
    ///
    /// A trade confirmation page is a TABLE. `PDFPage.string` flattens it into a
    /// sequence of lines where the columns are irretrievably mixed — on a real
    /// BoursoBank confirmation, the quantity "4" ends up three lines below its
    /// header, on the other side of the ISIN code. No search window around a
    /// label will cover every layout of every broker, and each new format would
    /// demand yet another one.
    ///
    /// The multimodal model sees the GRID. It's the same rule as for screenshots
    /// ("the image goes to the model, not its OCR"); it applies just as much to a
    /// PDF page, which is an image that happens to be readable as text too.
    ///
    /// The flattened text is attached TO THE IMAGE rather than dropped: it carries
    /// the EXACT characters (amounts to the cent, ISINs), where a purely visual
    /// reading may confuse a digit. The model thus gets the structure on one side
    /// and the reliable values on the other.
    ///
    /// Three stages, each catching the previous one:
    ///   1. VISUAL reading of the page (if a multimodal backend is active);
    ///   2. TEXT reading (Apple guided generation, otherwise JSON);
    ///   3. DETERMINISTIC extraction, always run — it costs no I/O, works without
    ///      any backend, and checks the arithmetic (`quantity × price = amount`)
    ///      that no model guarantees.
    ///
    /// `pdfSourceData`/`pdfPageIndex`: present ONLY for a PDF page (never for a
    /// raw text block or a capture's OCR).
    @MainActor private func parseUnit(text: String, unitNumber: Int,
                                      kind: ImportSourceKind,
                                      pdfSourceData: Data? = nil,
                                      pdfPageIndex: Int? = nil) async -> PDFPageResult {
        var parsed = PageParse()
        var diagnostic: ImportUnitDiagnostic = .nothingRecognized
        var readVisually = false

        if let pdfSourceData, let pdfPageIndex,
           AIEnrichmentBackend.supportsImageInput(for: .investmentImport) {
            let visual = await Self.parsePageImage(
                pdfSourceData: pdfSourceData, pdfPageIndex: pdfPageIndex,
                pageText: text, pageNumber: unitNumber)
            if !visual.isEmpty {
                parsed = visual
                diagnostic = .extracted
                readVisually = true
            }
        }

        // Text fallback: no multimodal backend, rendering impossible, or a silent
        // visual reading.
        if !readVisually {
            (parsed, diagnostic) = await parsePage(text: text, pageNumber: unitNumber)
        }

        // Deterministic extraction run SYSTEMATICALLY, not only as a fallback: it
        // costs nothing (no I/O) and it's exact where the small on-device model slips.
        //
        // On a two-row capture, a model can copy the FIRST operation's name and ISIN
        // onto the second. Associating a label with the right code on column OCR
        // text is precisely what ISIN anchoring does without error. The two sources
        // are therefore reconciled rather than picking one side.
        let deterministic = InvestmentStatementExtractor.extractOrders(from: text)
            .map { Self.convert($0, pageNumber: unitNumber) }

        let merged = StatementReconciler.reconcile(
            ai: parsed.orders, deterministic: deterministic,
            tag: readVisually ? StatementReconciler.imageTag : StatementReconciler.textTag)

        let usedFallback = !deterministic.isEmpty && parsed.orders.isEmpty

        // Orders AND positions are mutually exclusive for a given unit. The model
        // sometimes returns both on an operations statement — the same securities,
        // seen once as operations and once as holdings. Keeping both would count
        // each security TWICE in the review, and at import would create a position
        // duplicating its own order. The prompt already favors orders (more precise
        // for history); the same rule is applied in code rather than trusting the
        // model to have followed it.
        let positions = merged.isEmpty ? parsed.positions : []

        if !merged.isEmpty || !positions.isEmpty {
            return PDFPageResult(
                pageNumber: unitNumber, rawText: text,
                orders: merged, positions: positions,
                detectedMode: merged.isEmpty ? parsed.mode : .orders,
                // An AI failure is recorded even when the deterministic pass saved the day:
                // it's the useful information for support.
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

    /// Renders the PDF page as an image and has the multimodal model read it.
    ///
    /// This is the PRIMARY path for a PDF page as soon as a backend can read an
    /// image: a trade confirmation's layout IS the information (Date | Quantity |
    /// Security | Execution columns), and `PDFPage.string` destroys it.
    ///
    /// The flattened text accompanies the image in the prompt. It isn't
    /// redundancy: the image gives the STRUCTURE, the text gives the EXACT
    /// CHARACTERS (an amount to the cent, a 12-character ISIN) that even a good
    /// vision model can alter. Bounded, because the context window serves the
    /// image first.
    @MainActor private static func parsePageImage(
        pdfSourceData: Data, pdfPageIndex: Int, pageText: String, pageNumber: Int
    ) async -> PageParse {
        let renderedImage = await Task.detached(priority: .userInitiated) {
            renderPageImage(pdfData: pdfSourceData, pageIndex: pdfPageIndex)
        }.value
        guard let image = renderedImage else {
            print("[PDFParser] Unité \(pageNumber) : rendu image impossible, lecture texte")
            return PageParse()
        }

        let raw = await AIEnrichmentBackend.completeText(
            feature: .investmentImport,
            system: Self.systemInstructions,
            user: """
            Voici l'image d'une page de relevé d'investissement. C'est un TABLEAU : \
            lis chaque colonne (date, quantité, informations sur la valeur, cours \
            d'exécution, montant) à sa position RÉELLE dans la grille.

            Le texte ci-dessous est le même contenu extrait automatiquement, mais sa \
            mise en page a été perdue : les cellules y sont mélangées. Sers-t'en \
            uniquement pour lire les caractères exacts (montants au centime, codes \
            ISIN), et de l'image pour savoir à quelle colonne chacun appartient.

            --- TEXTE EXTRAIT ---
            \(pageText.prefix(3000))
            --- FIN ---
            """,
            image: image
        )
        guard let raw else { return PageParse() }
        let parsed = Self.parsePageResponse(raw, pageNumber: pageNumber)
        print("[PDFParser] Unité \(pageNumber) [image/\(parsed.mode.rawValue)] : \(parsed.orders.count) ordres, \(parsed.positions.count) positions")
        return parsed
    }

    /// Bridge from the (pure) deterministic engine → UI model.
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

    /// Splits a long text into chunks of about `maxChars`, cutting on line breaks.
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

    /// Parses a single page. Returns orders OR positions (snapshot mode)
    /// depending on the AI's classification, PLUS a diagnostic — without it, a
    /// model failure is indistinguishable from a genuinely empty document in the
    /// UI.
    ///
    /// Goes through `AIEnrichmentBackend`, the per-feature dispatch point: a user
    /// who configured a local server or a cloud key for "Portfolio import" gets
    /// AI on the page text even without Apple Intelligence.
    ///
    /// This TEXT path isn't the first attempt for a PDF page: `parseUnit` first
    /// has the page's IMAGE read when a multimodal backend is active (see
    /// `parsePageImage`). It remains the path for every other case — no
    /// multimodal backend, rendering impossible, raw text blocks, a capture's OCR.
    @MainActor private func parsePage(text: String, pageNumber: Int) async -> (PageParse, ImportUnitDiagnostic) {
        // A PDF page is NOT split by the reader, unlike raw text
        // (`ImportDocumentReader.textUnits`): it arrives WHOLE. A statement listing
        // dozens of operations far exceeds the on-device model's window, and the
        // `prefix(...)` set below would then silently cut off the end of the page —
        // the model would only see part of the rows. It's also a source of
        // variability: depending on exactly where the cut falls, the last visible
        // operation is complete or truncated, hence read or lost.
        let chunks = Self.splitTextIntoChunks(text, maxChars: Self.aiChunkSize)
            .prefix(Self.maxAIChunks)
        guard chunks.count > 1 else {
            return await parseChunk(text: text, pageNumber: pageNumber)
        }

        var merged = PageParse()
        var diagnostic: ImportUnitDiagnostic = .nothingRecognized
        for chunk in chunks {
            let (parsed, chunkDiagnostic) = await parseChunk(text: chunk, pageNumber: pageNumber)
            merged.orders += parsed.orders
            merged.positions += parsed.positions
            if parsed.mode != .unknown { merged.mode = parsed.mode }
            if chunkDiagnostic == .extracted {
                diagnostic = .extracted
            } else if diagnostic != .extracted, chunkDiagnostic != .nothingRecognized {
                diagnostic = chunkDiagnostic
            }
        }
        // Blocks are read independently: an operation straddling a cut may be
        // returned by both.
        merged.orders = StatementReconciler.dedupe(merged.orders)
        return (merged, merged.isEmpty ? diagnostic : .extracted)
    }

    /// Size of a block sent to the model. Below the on-device model's window, and
    /// below the guard `prefix` of both call paths.
    private static let aiChunkSize = 3500
    /// Cap on blocks per unit: beyond it, analyzing a single document would take
    /// several minutes for a marginal gain — the deterministic extraction sees
    /// the whole text anyway.
    private static let maxAIChunks = 8

    /// One block, one model call — through the backend resolved for portfolio
    /// import.
    ///
    /// `usesGuidedGeneration` reflects the backend RESOLVED for this feature
    /// (user preference + real availability) — not a mere platform test: an
    /// iOS 26+ iPhone whose user chose "Local server" must take the generic path
    /// too, not Foundation Models against their setting.
    @MainActor private func parseChunk(text: String, pageNumber: Int) async -> (PageParse, ImportUnitDiagnostic) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), AIEnrichmentBackend.usesGuidedGeneration(for: .investmentImport) {
            return await parsePageWithAI(text: text, pageNumber: pageNumber)
        }
        #endif
        return await parsePageWithGenericBackend(text: text, pageNumber: pageNumber)
    }

    /// Non-Apple path (local server, Claude, OpenAI): no guided generation
    /// possible (`@Generable` is specific to Foundation Models), hence free-text
    /// JSON — the same `parsePageResponse`/`systemInstructions` as the image
    /// fallback, so there are never two prompts or two parsers to diverge.
    @MainActor private func parsePageWithGenericBackend(text: String, pageNumber: Int) async -> (PageParse, ImportUnitDiagnostic) {
        let payload = String(text.prefix(8000))
        let raw = await AIEnrichmentBackend.completeText(
            feature: .investmentImport,
            system: Self.systemInstructions,
            user: Self.buildPagePrompt(pageText: payload, pageNumber: pageNumber)
        )
        guard let raw else {
            print("[PDFParser] Unité \(pageNumber) : aucun backend IA disponible pour l'import de portefeuille")
            return (PageParse(), .aiUnavailable)
        }
        let parsed = Self.parsePageResponse(raw, pageNumber: pageNumber)
        print("[PDFParser] Unité \(pageNumber) [backend générique/\(parsed.mode.rawValue)] : \(parsed.orders.count) ordres, \(parsed.positions.count) positions")
        return (parsed, parsed.isEmpty ? .nothingRecognized : .extracted)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func parsePageWithAI(text: String, pageNumber: Int) async -> (PageParse, ImportUnitDiagnostic) {
        guard SystemLanguageModel.default.isAvailable else { return (PageParse(), .aiUnavailable) }

        // The text sent is bounded: the on-device model's context window is narrow,
        // and overflowing it fails the WHOLE page.
        let payload = String(text.prefix(4000))

        // 1st choice: GUIDED GENERATION. The `@Generable` schema constrains decoding
        // on the model side — no JSON to repair, and measured ~3× faster than free
        // generation (7.5 s vs 21.4 s on the same statement) because the model no
        // longer writes the syntax.
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

        // 2nd choice: free generation + JSON. Kept because a model may reject a
        // schema it honors poorly on an atypical document.
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

    /// User-readable error message (Foundation Models errors are verbose).
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

    // MARK: - Guided generation schema

    /// Schema imposed on the model. Every field is NON-optional: guided generation
    /// always fills them, which removes the JSON decoding class of bugs (a
    /// missing key would lose the WHOLE page, not just the faulty row).
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

    /// Guided generation instructions — deliberately SHORT (~500 characters vs
    /// 7,600 for free generation): the schema already carries the structure, and
    /// every instruction token is taken from the context window available for the
    /// document itself.
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

    /// Guided schema → internal model conversion, with the same validity filters
    /// as the JSON path (parsable date, recognized order type).
    @available(iOS 26.0, macOS 26.0, *)
    static func convert(_ extraction: AIStatementExtraction, pageNumber: Int) -> PageParse {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let orders: [PDFExtractedOrder] = extraction.orders.compactMap { raw in
            guard let executedAt = Self.parseDate(raw.executedAt, formatter: formatter),
                  let orderType = Self.normalizeOrderType(raw.orderType) else { return nil }
            // Same valuation as the deterministic extraction: a dividend is worth its
            // AMOUNT, not "quantity × price" (which would give €0).
            let valued = InvestmentStatementExtractor.valuation(
                orderType: orderType, quantity: raw.quantity,
                unitPrice: raw.unitPrice, gross: raw.unitPrice * raw.quantity)
            return PDFExtractedOrder(
                orderType: orderType,
                assetName: raw.assetName.isEmpty ? "Inconnu" : raw.assetName,
                ticker: raw.ticker, isin: raw.isin.uppercased(),
                quantity: valued.quantity, unitPrice: valued.unitPrice, fees: raw.fees,
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

    // MARK: - System prompt

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
    - **asset_name** : le NOM COMPLET ET RÉEL du titre/instrument (ex: "Epargne MSCI World UCITS ETF Acc", "LVMH Moët Hennessy Louis Vuitton SE", "TotalEnergies SE"). JAMAIS un terme générique comme "Action", "ETF", "Fonds", "Titre" — cherche le vrai nom dans le texte de la page.
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
    - Le nom du titre est souvent en gras/gros en haut : "EPARGNE MSCI WORLD UCITS ETF - EUR (C)"
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
          "asset_name": "Epargne MSCI World UCITS ETF Acc",
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
          "asset_name": "Epargne MSCI World UCITS ETF Acc",
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

    /// Parses the dual-mode AI answer (orders OR positions) into a `PageParse`.
    static func parsePageResponse(_ raw: String, pageNumber: Int) -> PageParse {
        // Same repair as on the transaction side: isolating the object AND
        // re-joining strings split by the model's formatting.
        let jsonStr = LenientJSON.extractObject(from: raw)
        guard jsonStr.contains("{") else {
            print("[PDFParser] Pas de JSON trouvé dans la réponse IA page \(pageNumber)")
            return PageParse()
        }
        // Fast path: the whole document is valid.
        var payload = jsonStr.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(AIPageResponse.self, from: $0) }

        // OBJECT-BY-OBJECT fallback when it isn't. A single punctuation mistake from
        // the model (trailing comma, forgotten key quote) would otherwise lose EVERY
        // operation of the page, including the perfectly formed ones. A broken row
        // must cost only one row.
        if payload == nil {
            let decoder = JSONDecoder()
            let salvagedOrders = LenientJSON.innermostObjects(in: raw).compactMap { object in
                object.data(using: .utf8).flatMap { try? decoder.decode(AIOrder.self, from: $0) }
            }
            let salvagedPositions = LenientJSON.innermostObjects(in: raw).compactMap { object in
                object.data(using: .utf8).flatMap { try? decoder.decode(AIPosition.self, from: $0) }
            }
            guard !salvagedOrders.isEmpty || !salvagedPositions.isEmpty else {
                print("[PDFParser] Décodage JSON échoué page \(pageNumber)")
                return PageParse()
            }
            print("[PDFParser] JSON invalide page \(pageNumber) — récupération objet par objet")
            payload = AIPageResponse(mode: nil, orders: salvagedOrders,
                                     positions: salvagedPositions, page_note: nil)
        }
        guard let payload else { return PageParse() }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        // Orders (tolerant: even without "mode", the orders present are parsed)
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
            // The model readily returns a dividend with `quantity: 1` and
            // `unit_price: 0` — an amount of €0. The `total` field, when present,
            // carries the real value: the shared valuation restores an exact product.
            let valued = InvestmentStatementExtractor.valuation(
                orderType: orderType,
                quantity: raw.quantity?.value,
                unitPrice: raw.unit_price?.value,
                gross: raw.total?.value ?? raw.amount?.value)
            return PDFExtractedOrder(
                orderType: orderType,
                assetName: raw.asset_name ?? "Inconnu",
                ticker: raw.ticker ?? "",
                isin: raw.isin ?? "",
                quantity: valued.quantity,
                unitPrice: valued.unitPrice,
                fees: raw.fees?.value ?? 0,
                executedAt: executedAt,
                currency: raw.currency ?? "EUR",
                notes: raw.notes,
                pageNumber: pageNumber,
                confidence: max(0, min(1, raw.confidence?.value ?? 0.5))
            )
        }

        // Positions (snapshot mode) — rows without a usable quantity are ignored.
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

        // Mode: the one declared by the AI (the AI writes "positions", not
        // "positionsSnapshot"), with a fallback inferred from the content.
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

    /// Normalizes the order types returned by the AI to BUY/SELL/DIV.
    /// The AI may return French, English or long variants.
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

    /// Parses a date with several formats common in bank statements.
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

    // MARK: - Aggregation by position

    /// Shared grouping key: ISIN (preferred), otherwise ticker, otherwise name.
    /// Shared by both aggregations AND by the UI, which must be able to tick /
    /// untick ALL the raw items of a displayed group.
    static func groupKey(isin: String, ticker: String, assetName: String) -> String {
        if !isin.isEmpty { return isin.uppercased() }
        if !ticker.isEmpty { return ticker.uppercased() }
        return assetName.uppercased()
    }

    /// Groups orders by ISIN (preferred) or ticker.
    ///
    /// Does NOT filter on `isSelected`: that's up to the caller before the
    /// import. Filtering here would make a row DISAPPEAR from the preview as soon
    /// as it's unticked (the preview is built from this aggregation) — and it
    /// could never be ticked again.
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

    /// Deduplicates positions extracted from a capture (snapshot mode) by ISIN >
    /// ticker > name. Adds up quantities if the same row appears on several
    /// chunks/pages; keeps the first occurrence's average cost and value (a
    /// capture shows only one value per row).
    ///
    /// Does NOT filter on `isSelected` (same reason as `aggregateByPosition`).
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

    // MARK: - AI decoding DTOs

    /// Tolerant number: a small model often writes `"quantity": "7"` or
    /// `"unit_price": "34,53"` instead of a numeric literal.
    ///
    /// Without it, `JSONDecoder` throws on the faulty row and **the whole page**
    /// is lost, not just the operation concerned — a ten-operation document
    /// would be discarded for a single mistyped field.
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
        /// Optional: a missing key must not invalidate the whole batch.
        let order_type: String?
        let asset_name: String?
        let ticker: String?
        let isin: String?
        let quantity: LenientDouble?
        let unit_price: LenientDouble?
        /// Total amount of the operation. The only field filled on a dividend row,
        /// which has neither quantity nor price.
        let total: LenientDouble?
        let amount: LenientDouble?
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
