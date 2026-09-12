import Foundation

// MARK: - Exchange model for the unified import pipeline
//
// PURE engine (`import Foundation` ONLY — no PDFKit, no Vision, no
// FoundationModels, no SwiftUI), same doctrine as `PortfolioEvolutionBuilder`,
// `BankStatementExtractor` and `MerchantQueryPlanner`: testable outside Xcode via
// `run_import_pipeline_tests.sh`. The purity safety net IS the harness — a
// forbidden import breaks it at compile time.
//
// ─── Why an exchange model ──────────────────────────────────────────────────
//
// Five input sub-pipelines (image, PDF, CSV, XLSX, XML) feed two
// business resolutions (transactions, investments). Without a mandatory
// crossing point, every combination ends up with its own path: that's
// exactly what happened (two parsers with two reconciliations, two
// JSON decoders, and a THIRD CSV import buried inside the
// Investments module).
//
// `ImportElement` is that crossing point. Everything that comes in comes
// back out in this shape, and everything that consumes an import starts here.
//
// ─── No business-classification step ───────────────────────────────────────
//
// The scoping diagram called for a CLASSIFY node (Transaction /
// Investment / Ambiguous) AFTER extraction. It doesn't exist here, and
// that's deliberate: the destination is chosen by the user BEFORE
// analysis, and it's what calibrates the instructions given to the model
// (the same PDF can be a bank statement or a trade confirmation). Reclassifying
// afterward would introduce a second source of truth on a question already
// settled, one that could contradict it.
//
// What CLASSIFY was useful for — detecting that a file doesn't look
// like anything usable — comes for free: it's an `ImportUnitReport`
// whose diagnosis is `.nothingRecognized`, and the UI already shows it.
// The buy/sell/dividend sub-classification, meanwhile, stays where it's always
// been: in the investments payload.

// MARK: - Destination

/// Where the read data lands. The choice is made UPSTREAM of analysis,
/// and that's what lets AI instructions be calibrated: the same
/// PDF can be a bank statement or a trade confirmation, and guessing the type
/// from the content is exactly what the small embedded model gets
/// wrong most often.
enum ImportDestination: String, CaseIterable, Identifiable, Codable, Sendable {
    case transactions
    case investments

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transactions: return "Transactions"
        case .investments:  return "Investissements"
        }
    }

    var icon: String {
        switch self {
        case .transactions: return "list.bullet.rectangle"
        case .investments:  return "chart.line.uptrend.xyaxis"
        }
    }

    /// What the user is expected to supply, shown under the picker.
    var hint: String {
        switch self {
        case .transactions:
            return "Relevé de compte, export CSV de ta banque, ou capture d'écran de la liste des opérations."
        case .investments:
            return "Avis d'opéré, relevé de portefeuille, ou capture d'écran de ton PEA/CTO."
        }
    }
}

// MARK: - Source nature

/// A document's real nature, determined by SNIFFING its header
/// bytes and never by its extension.
///
/// ⚠️ Trusting the extension is a bug already paid for in production: a
/// screenshot shared via the share sheet arrives named `<uuid>.dat` (the
/// abstract `public.image` type has no `preferredFilenameExtension`), fell
/// into the "plain text" branch, and
/// `String(contentsOf:encoding:.isoLatin1)` — which NEVER fails, any
/// byte sequence being valid Latin-1 — produced 670,000 characters
/// of binary sent to the model as if it were a statement.
///
/// Also feeds the UI's wording: talking about a "page" for a screenshot
/// or a spreadsheet makes no sense now that import is multi-format.
enum ImportSourceKind: String, Codable, Hashable, Sendable {
    case pdf
    case image
    /// Plain text: CSV, TSV, a statement exported as .txt.
    case text
    /// Classeur XLSX (ZIP + XML).
    case spreadsheet
    /// Structured statement: CAMT.053 (ISO 20022) or OFX/QFX.
    case xml
    case unknown

    /// Name of the analyzed unit. The UI composes "3 screenshots analyzed".
    func unitLabel(count: Int) -> String {
        let plural = count > 1
        switch self {
        case .pdf:         return plural ? "pages analysées" : "page analysée"
        case .image:       return plural ? "captures analysées" : "capture analysée"
        case .text:        return plural ? "blocs analysés" : "bloc analysé"
        case .spreadsheet: return plural ? "feuilles analysées" : "feuille analysée"
        case .xml:         return plural ? "relevés analysés" : "relevé analysé"
        case .unknown:     return plural ? "éléments analysés" : "élément analysé"
        }
    }

    /// True for formats whose STRUCTURE is already explicit and therefore
    /// needs no interpretation by a model: fields are named
    /// (CSV columns, CAMT/OFX tags, spreadsheet cells).
    ///
    /// This decides whether a unit goes through the AI stage or not — not
    /// whether a model happens to be available. Sending a CAMT.053 to an LLM
    /// would be both slower and less reliable than reading its tags.
    var isStructured: Bool {
        switch self {
        case .text, .spreadsheet, .xml: return true
        case .pdf, .image, .unknown:    return false
        }
    }
}

// MARK: - Diagnostic

/// Why a unit produced nothing.
///
/// Without this, the UI could only show an undifferentiated "Nothing to
/// import": impossible for the user (or for us in support) to tell apart a
/// silent OCR, an unavailable AI, a failed AI, and a document that
/// really has no operations.
enum ImportUnitDiagnostic: Equatable, Hashable, Codable, Sendable {
    /// Extraction OK, operations found.
    case extracted
    /// No text could be extracted (unreadable image, empty scanned PDF…).
    case noTextExtracted
    /// The content isn't usable text (binary mistaken for text).
    case notTextContent
    /// The AI engine isn't available on this device.
    case aiUnavailable
    /// The AI engine failed (context exceeded, safety net, internal error…).
    case aiFailed(String)
    /// The structured format was read, but its content wasn't usable
    /// (empty workbook, unknown XML dialect…).
    case malformedStructure(String)
    /// Document read and engine OK, but no recognizable operation in it.
    case nothingRecognized

    var isFailure: Bool { self != .extracted }

    /// Short message shown to the user.
    var userMessage: String {
        switch self {
        case .extracted:        return "Opérations extraites."
        case .noTextExtracted:  return "Aucun texte n'a pu être lu dans ce document. Si c'est une photo, vérifie qu'elle est nette et bien cadrée."
        case .notTextContent:   return "Le format du fichier n'a pas été reconnu (contenu binaire). Réessaie en exportant un PDF, une capture d'écran, un CSV ou un relevé XML."
        case .aiUnavailable:    return "L'analyse intelligente n'est pas disponible sur cet appareil (Apple Intelligence requis). L'extraction automatique a été utilisée à la place."
        case .aiFailed(let r):  return "L'analyse intelligente a échoué : \(r)"
        case .malformedStructure(let r): return "Le fichier a été ouvert mais son contenu n'a pas pu être exploité : \(r)"
        // ⚠️ Message SHARED by both imports: it must mention neither
        // "buy / sell / dividend" (investments vocabulary), nor
        // "the text" — on the image path, no text is extracted at all, it's
        // the model that reads the screenshot.
        case .nothingRecognized: return "Le document a bien été lu, mais aucune opération n'y a été reconnue."
        }
    }
}

// MARK: - Origine

/// Where an item comes from. Kept until review so the user
/// can check that NO source got lost along the way on a multi-file
/// import — the end-of-analysis banner's per-source detail is
/// built on top of this.
struct ImportElementOrigin: Codable, Hashable, Sendable {
    /// Readable name of the source file.
    var sourceName: String
    /// The file's rank in the batch (0-indexed), for a stable sort when two
    /// files share the same name.
    var sourceIndex: Int
    /// GLOBAL unit number in the batch (1-indexed). Global, not per
    /// file: two files each restarting at 1 would produce colliding
    /// numbers, and failure reports would then point at an ambiguous unit.
    var unitNumber: Int
    /// Unit's rank WITHIN its file (1-indexed) — a PDF's page number,
    /// a workbook sheet's rank.
    var unitIndexInSource: Int
    var kind: ImportSourceKind

    init(sourceName: String, sourceIndex: Int = 0,
         unitNumber: Int = 1, unitIndexInSource: Int = 1,
         kind: ImportSourceKind = .unknown) {
        self.sourceName = sourceName
        self.sourceIndex = sourceIndex
        self.unitNumber = unitNumber
        self.unitIndexInSource = unitIndexInSource
        self.kind = kind
    }
}

// MARK: - Held position (pure counterpart of `PDFExtractedPosition`)

/// A held position row extracted from a portfolio screenshot.
///
/// Deliberately distinct from `PDFExtractedPosition`, which carries UI
/// state (`id`, `isSelected`): the pipeline stays pure, screen state is
/// added at the review boundary.
struct ExtractedStatementPosition: Equatable, Codable, Hashable, Sendable {
    var assetName: String
    var ticker: String
    var isin: String
    var quantity: Double
    var averageBuyPrice: Double
    /// Market value if the screenshot shows it.
    var currentValue: Double?
    var currency: String
    var confidence: Double

    init(assetName: String, ticker: String = "", isin: String = "",
         quantity: Double, averageBuyPrice: Double = 0,
         currentValue: Double? = nil, currency: String = "EUR",
         confidence: Double = 0.5) {
        self.assetName = assetName
        self.ticker = ticker
        self.isin = isin
        self.quantity = quantity
        self.averageBuyPrice = averageBuyPrice
        self.currentValue = currentValue
        self.currency = currency
        self.confidence = confidence
    }
}

// MARK: - Payload

/// What an item actually carries.
///
/// The type is FIXED by the destination chosen upstream, it's never
/// guessed: a pipeline run toward transactions only produces
/// `.transaction`.
enum ImportPayload: Equatable, Codable, Hashable, Sendable {
    case transaction(ExtractedBankTransaction)
    case investmentOrder(ExtractedStatementOrder)
    case investmentPosition(ExtractedStatementPosition)

    /// Destination this payload belongs to.
    var destinationKind: ImportPayloadKind {
        switch self {
        case .transaction:        return .transaction
        case .investmentOrder:    return .investmentOrder
        case .investmentPosition: return .investmentPosition
        }
    }
}

/// Lightweight discriminant, useful for counting/filtering without unpacking the payload.
enum ImportPayloadKind: String, Codable, Hashable, Sendable {
    case transaction
    case investmentOrder
    case investmentPosition
}

// MARK: - Element

/// The pipeline's output unit, whatever the input format.
struct ImportElement: Identifiable, Equatable, Codable, Hashable, Sendable {
    var id: UUID
    var origin: ImportElementOrigin
    var payload: ImportPayload
    /// 0…1. Copied from the payload at construction, but kept at this
    /// level: reconciling two sources (AI + deterministic) adjusts it,
    /// and the UI sorts on it without needing to know the payload's type.
    var confidence: Double

    init(id: UUID = UUID(), origin: ImportElementOrigin,
         payload: ImportPayload, confidence: Double? = nil) {
        self.id = id
        self.origin = origin
        self.payload = payload
        self.confidence = confidence ?? Self.confidence(of: payload)
    }

    private static func confidence(of payload: ImportPayload) -> Double {
        switch payload {
        case .transaction(let t):        return t.confidence
        case .investmentOrder(let o):    return o.confidence
        case .investmentPosition(let p): return p.confidence
        }
    }

    var kind: ImportPayloadKind { payload.destinationKind }
}

// MARK: - Per-unit report

/// What happened for ONE analyzed unit (a PDF page, a
/// screenshot, a sheet, a block of text). Carried separately from the
/// elements because a unit that produces NOTHING is exactly the one worth
/// talking about.
struct ImportUnitReport: Identifiable, Equatable, Codable, Hashable, Sendable {
    var id: UUID
    var origin: ImportElementOrigin
    /// What the app actually read — this is what lets us tell a
    /// silent OCR apart from a botched interpretation. On the image path
    /// (multimodal model), this is the model's raw response, since no
    /// text is extracted at all.
    var rawText: String
    var recognizedCount: Int
    var diagnostic: ImportUnitDiagnostic
    /// True when the result comes from deterministic extraction, no AI.
    var usedDeterministicFallback: Bool

    init(id: UUID = UUID(), origin: ImportElementOrigin, rawText: String = "",
         recognizedCount: Int = 0, diagnostic: ImportUnitDiagnostic = .extracted,
         usedDeterministicFallback: Bool = false) {
        self.id = id
        self.origin = origin
        self.rawText = rawText
        self.recognizedCount = recognizedCount
        self.diagnostic = diagnostic
        self.usedDeterministicFallback = usedDeterministicFallback
    }
}

// MARK: - Batch result

/// The full output of an import: the elements, and the log of what
/// happened unit by unit.
struct ImportBatchResult: Equatable, Codable, Sendable {
    var elements: [ImportElement]
    var units: [ImportUnitReport]

    init(elements: [ImportElement] = [], units: [ImportUnitReport] = []) {
        self.elements = elements
        self.units = units
    }

    var isEmpty: Bool { elements.isEmpty }

    /// Breakdown per source file, in batch order.
    ///
    /// This is what makes the merge VERIFIABLE at a glance: on an import
    /// mixing CSV and analyzed documents, a missing source didn't
    /// show up in an aggregate total.
    func perSource() -> [ImportSourceSummary] {
        var order: [Int] = []
        var byIndex: [Int: ImportSourceSummary] = [:]

        func slot(_ origin: ImportElementOrigin) -> ImportSourceSummary {
            if let existing = byIndex[origin.sourceIndex] { return existing }
            order.append(origin.sourceIndex)
            return ImportSourceSummary(sourceIndex: origin.sourceIndex,
                                       sourceName: origin.sourceName,
                                       kind: origin.kind)
        }

        for unit in units {
            var summary = slot(unit.origin)
            summary.unitCount += 1
            if unit.diagnostic.isFailure { summary.failedUnitCount += 1 }
            byIndex[unit.origin.sourceIndex] = summary
        }
        for element in elements {
            var summary = slot(element.origin)
            summary.elementCount += 1
            byIndex[element.origin.sourceIndex] = summary
        }
        return order.compactMap { byIndex[$0] }
    }

    /// Indented JSON of one source's elements — the debug inspection at
    /// the end of analysis.
    ///
    /// ⚠️ On the NORMALIZED structure, not the raw OCR text: it's the
    /// only format that also covers sources with no OCR (CSV, spreadsheet, XML),
    /// for which "view the text read" makes no sense.
    func debugJSON(sourceIndex: Int? = nil) -> String {
        let subset = sourceIndex.map { index in
            elements.filter { $0.origin.sourceIndex == index }
        } ?? elements
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(subset),
              let text = String(data: data, encoding: .utf8) else {
            return "// encodage impossible"
        }
        return text
    }

    /// Merges two results while keeping order and renumbering the
    /// units in sequence — used when the same session aggregates several
    /// passes (already-mapped CSVs, then analyzed documents).
    static func merge(_ first: ImportBatchResult, _ second: ImportBatchResult) -> ImportBatchResult {
        let unitOffset = first.units.count
        let sourceOffset = (first.units.map(\.origin.sourceIndex)
                            + first.elements.map(\.origin.sourceIndex)).max().map { $0 + 1 } ?? 0

        func shift(_ origin: ImportElementOrigin) -> ImportElementOrigin {
            var moved = origin
            moved.unitNumber += unitOffset
            moved.sourceIndex += sourceOffset
            return moved
        }

        var merged = first
        merged.units += second.units.map { unit in
            var copy = unit
            copy.origin = shift(unit.origin)
            return copy
        }
        merged.elements += second.elements.map { element in
            var copy = element
            copy.origin = shift(element.origin)
            return copy
        }
        return merged
    }
}

/// What a source produced. Feeds the banner's expandable detail.
struct ImportSourceSummary: Identifiable, Equatable, Codable, Hashable, Sendable {
    var sourceIndex: Int
    var sourceName: String
    var kind: ImportSourceKind
    var unitCount: Int = 0
    var failedUnitCount: Int = 0
    var elementCount: Int = 0

    var id: Int { sourceIndex }

    /// True when the source produced NOTHING — the case worth seeing.
    var isEmptyResult: Bool { elementCount == 0 }

    /// "42 operations" / "no operations".
    func summaryLabel(noun: String) -> String {
        switch elementCount {
        case 0:  return "aucune \(noun)"
        case 1:  return "1 \(noun)"
        default: return "\(elementCount) \(noun)s"
        }
    }
}
