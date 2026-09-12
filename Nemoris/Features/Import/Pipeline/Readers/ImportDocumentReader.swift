import Foundation
import PDFKit
import CoreGraphics

/// A document to analyze, already loaded into memory. The name is used to
/// trace each row's origin when an import aggregates several files.
struct ImportDocumentSource: Sendable {
    let data: Data
    let displayName: String

    init(data: Data, displayName: String) {
        self.data = data
        self.displayName = displayName
    }

    var fileExtension: String { (displayName as NSString).pathExtension }
}

/// Splitting a document into analyzable UNITS, shared by both imports.
///
/// The actual type is sniffed from the bytes (never the extension), then:
///   • a PDF yields one unit per page,
///   • an image yields one unit — the image itself if a model can read it,
///     its OCR otherwise,
///   • long text is chunked into blocks that fit the model's
///     context window,
///   • a workbook yields one table per sheet,
///   • a CAMT/OFX statement directly yields structured records.
///
/// Shared because it's strictly identical on both sides — only
/// interpretation differs afterward (bank operations versus stock
/// market orders).
enum ImportDocumentReader {

    /// A unit's content.
    ///
    /// ⚠️ An enum, not a bag of optional fields: the four
    /// shapes are mutually exclusive, and a struct with four optionals
    /// leaves the compiler indifferent to a caller who forgets to handle
    /// one. Here, adding a format BREAKS every `switch` — which is what we want.
    enum Content {
        /// Text to interpret (PDF page, OCR, block).
        case text(String)
        /// The image itself, for a multimodal model.
        ///
        /// ⚠️ Passing the image rather than its OCR is a change of nature,
        /// not an optimization: the layout (columns, day
        /// headers, category subtitles) carries meaning that
        /// flattening to text destroys — and that no line-ordering heuristic
        /// reconstructs in a general way, since it differs
        /// from one banking app to another.
        case image(CGImage)
        /// A table to map (CSV, workbook sheet): the structure is there,
        /// but column SEMANTICS need the user.
        case grid(ImportGrid)
        /// Records already structured AND named (CAMT.053, OFX): neither
        /// model nor mapping — fields are designated by the format.
        case records([ImportPayload])
        /// Nothing usable, with the reason.
        case empty(ImportUnitDiagnostic)
    }

    struct Unit {
        var content: Content
        var kind: ImportSourceKind
        /// The unit's rank within its file (1-indexed): page number, sheet
        /// rank, block index.
        var indexInSource: Int = 1
        /// A table's source text, kept for a possible re-parse with
        /// another separator.
        ///
        /// ⚠️ Carried BY THE UNIT because it's decoded here, off the main actor.
        /// Re-decoding it later from `source.data` — what
        /// `ImportPipeline.read` used to do — redid the work a second time, AND
        /// on the main thread: a visible freeze on a large CSV.
        var sourceText: String?

        /// Source PDF + ORIGINAL PAGE index (0-based, before filtering out
        /// blank pages) — carried ONLY by PDF units, for image rendering
        /// ON DEMAND (see `InvestmentPDFParser.renderPageImage`) if
        /// the text PDFKit flattened turns out insufficient on a poorly
        /// linearized table. Do NOT render the image HERE: most pages never
        /// need it (the deterministic engine is enough), and rendering blindly
        /// would cost CPU time for nothing on a statement with several
        /// dozen pages. `Data` is copy-on-write: carrying it on every
        /// unit of the same PDF doesn't duplicate the bytes.
        var pdfSourceData: Data?
        var pdfPageIndex: Int?

        /// Original bytes of an IMAGE unit, kept for an OCR fallback if
        /// the multimodal model returns nothing usable.
        ///
        /// ⚠️ The image path had NO safety net at all: the model is the only
        /// source there, so a truncated response or unrepairable JSON produced
        /// "no operations" — and since generation isn't
        /// deterministic, the SAME screenshot sometimes gave N operations, sometimes
        /// zero. The fallback OCR brings back text, so both deterministic
        /// extraction AND a second chance for the model. Not OCR UP FRONT
        /// though: Vision costs 1 to 5 seconds per screenshot, no point paying for it
        /// when reading the image is enough.
        var imageSourceData: Data?

        /// Read shortcut — empty for non-text shapes.
        var text: String {
            if case .text(let value) = content { return value }
            return ""
        }

        var image: CGImage? {
            if case .image(let value) = content { return value }
            return nil
        }
    }

    // MARK: - Entry point

    /// ⚠️ All heavy work (opening a PDF, Vision OCR, ZIP inflate) runs
    /// in `Task.detached`: these calls are SYNCHRONOUS and costly, leaving
    /// them on the main actor freezes the app and the progress bar never
    /// draws.
    ///
    /// `feature`: the feature on whose behalf we're reading.
    ///
    /// ⚠️ It decides whether a screenshot is passed AS-IS to the model or
    /// OCR'd: the backend is chosen per feature, so statement import
    /// can read images (multimodal local server) while
    /// portfolio import is reduced to OCR, or vice versa. Asking the
    /// question globally would give the wrong answer to one of the two.
    ///
    /// `allowsImagePassthrough`: at `false`, a screenshot is always OCR'd
    /// even if a multimodal model exists. Useful for formats where
    /// deterministic extraction is wanted (the anchoring engine needs text).
    static func units(for source: ImportDocumentSource,
                      feature: AIFeature,
                      allowsImagePassthrough: Bool = true) async -> [Unit] {
        let data = source.data
        let kind = ImportFormatSniffer.detect(data: data, fileExtension: source.fileExtension)

        switch kind {
        case .pdf:         return await pdfUnits(data)
        case .image:       return await imageUnits(data, feature: feature,
                                                   allowsPassthrough: allowsImagePassthrough)
        case .text:        return textUnits(data)
        case .spreadsheet: return await spreadsheetUnits(data)
        case .xml:         return await structuredUnits(data)
        case .unknown:     return [Unit(content: .empty(.notTextContent), kind: .unknown)]
        }
    }

    // MARK: - PDF

    private static func pdfUnits(_ data: Data) async -> [Unit] {
        // ⚠️ The ORIGINAL PAGE index (0-based, before filtering) is kept
        // alongside the text — the blank-page filtering that follows shifts
        // positions in the resulting array, but `renderPageImage` needs
        // the REAL index in the PDF, not the rank among non-blank pages.
        let pages: [(index: Int, text: String)] = await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(data: data) else { return [] }
            return (0..<document.pageCount).compactMap { index in
                guard let text = document.page(at: index)?.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return nil }
                return (index, text)
            }
        }.value
        guard !pages.isEmpty else {
            return [Unit(content: .empty(.noTextExtracted), kind: .pdf)]
        }
        return pages.enumerated().map { position, page in
            Unit(content: .text(page.text), kind: .pdf, indexInSource: position + 1,
                 pdfSourceData: data, pdfPageIndex: page.index)
        }
    }

    // MARK: - Image

    private static func imageUnits(_ data: Data, feature: AIFeature,
                                   allowsPassthrough: Bool) async -> [Unit] {
        if allowsPassthrough, await AIEnrichmentBackend.supportsImageInput(for: feature),
           let cgImage = await Task.detached(priority: .userInitiated, operation: {
               InvestmentPDFParser.decodeImage(from: data)
           }).value {
            return [Unit(content: .image(cgImage), kind: .image, imageSourceData: data)]
        }
        let text = await Task.detached(priority: .userInitiated) {
            InvestmentPDFParser.ocrText(from: data)
        }.value ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [Unit(content: .empty(.noTextExtracted), kind: .image)]
        }
        return [Unit(content: .text(text), kind: .image)]
    }

    // MARK: - Texte

    private static func textUnits(_ data: Data) -> [Unit] {
        guard let text = decodeText(data), !text.isEmpty else {
            return [Unit(content: .empty(.noTextExtracted), kind: .text)]
        }
        // Genuinely tabular text goes to column mapping; the rest
        // (prose statement, unstructured export) goes to the document parser.
        if let grid = CSVParser.parse(content: text), grid.isTabular {
            return [Unit(content: .grid(grid), kind: .text, sourceText: text)]
        }
        // The embedded model's context window is narrow: sending a whole
        // statement in one block overflows it and the unit is lost.
        let chunks = InvestmentPDFParser.splitTextIntoChunks(text, maxChars: 4000)
        return chunks.enumerated().map { index, chunk in
            Unit(content: .text(chunk), kind: .text, indexInSource: index + 1)
        }
    }

    // MARK: - Classeur

    private static func spreadsheetUnits(_ data: Data) async -> [Unit] {
        let sheets = await Task.detached(priority: .userInitiated) {
            XLSXReader.grids(from: data)
        }.value
        switch sheets {
        case .success(let grids) where !grids.isEmpty:
            return grids.enumerated().map { index, grid in
                Unit(content: .grid(grid), kind: .spreadsheet, indexInSource: index + 1)
            }
        case .success:
            return [Unit(content: .empty(.malformedStructure("le classeur ne contient aucune feuille exploitable")),
                         kind: .spreadsheet)]
        case .failure(let error):
            return [Unit(content: .empty(.malformedStructure(error.reason)), kind: .spreadsheet)]
        }
    }

    // MARK: - Structured statement (CAMT.053 / OFX)

    private static func structuredUnits(_ data: Data) async -> [Unit] {
        let parsed = await Task.detached(priority: .userInitiated) {
            LedgerXMLReader.parse(data: data)
        }.value
        switch parsed {
        case .success(let payloads) where !payloads.isEmpty:
            return [Unit(content: .records(payloads), kind: .xml)]
        case .success:
            return [Unit(content: .empty(.nothingRecognized), kind: .xml)]
        case .failure(let error):
            return [Unit(content: .empty(.malformedStructure(error.reason)), kind: .xml)]
        }
    }

    // MARK: - Text decoding

    /// Facade over the sniffer's decoding — which is PURE, so covered by the
    /// harness, whereas this reader depends on PDFKit and Vision.
    static func decodeText(_ data: Data) -> String? {
        ImportFormatSniffer.decodeText(data)
    }
}
