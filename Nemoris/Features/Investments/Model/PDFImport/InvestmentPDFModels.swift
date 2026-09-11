import Foundation

// MARK: - Models for importing investment orders from documents

/// An order extracted from the document, before user validation.
struct PDFExtractedOrder: Identifiable, Hashable {
    let id = UUID()
    var orderType: String       // "BUY" | "SELL" | "DIV"
    var assetName: String       // Nom lisible (ex: "Epargne MSCI World")
    var ticker: String          // Ticker / symbole (ex: "CW8")
    var isin: String            // ISIN when detected (e.g. "LU1681043599")
    var quantity: Double
    var unitPrice: Double       // Execution unit price
    var fees: Double            // Frais de courtage
    var executedAt: Date
    var currency: String        // EUR, USD, etc.
    var notes: String?          // Additional extracted info
    var pageNumber: Int         // Source page in the PDF
    var confidence: Double      // 0…1 — the extraction's confidence in this order
    var isSelected: Bool = true // the user can untick it before importing

    /// Gross total cost
    var totalCost: Double { quantity * unitPrice + fees }

    /// Asset type inferred from the name / ISIN
    var assetType: String {
        let upper = (assetName + " " + ticker).uppercased()
        if upper.contains("ETF") || upper.contains("TRACKER") { return "ETF" }
        if upper.contains("OPCVM") || upper.contains("SICAV") || upper.contains("FCP") { return "FUND" }
        if upper.contains("OBLIG") || upper.contains("BOND") { return "BOND" }
        if upper.contains("CRYPTO") || upper.contains("BTC") || upper.contains("ETH") { return "CRYPTO" }
        return "STOCK"
    }
}

/// Conformance to the PURE merge engine (`StatementReconciler`), so the rule
/// "is this second reading about the same operation?" is written ONCE and
/// applies to the UI model as well as to the pure model.
extension PDFExtractedOrder: StatementOrderFields {
    private static let isoDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    var isoDay: String { Self.isoDay.string(from: executedAt) }
}

/// Mode detected for a document/page: ORDER statement (trade confirmation) or
/// PORTFOLIO CAPTURE (list of positions with quantity/average cost/value, no
/// execution dates — typically a screenshot of a PEA/brokerage app).
enum PDFDocumentMode: String, Codable {
    case orders
    case positionsSnapshot
    case unknown
}

/// A position extracted from a portfolio capture (snapshot mode).
/// Unlike an order, there is no execution date: the current state (quantity
/// held, average cost, market value) is known, but not the history.
struct PDFExtractedPosition: Identifiable, Hashable {
    let id = UUID()
    var assetName: String        // Nom lisible (ex: "Epargne MSCI World")
    var ticker: String           // Ticker / symbole
    var isin: String             // ISIN when detected
    var quantity: Double         // Quantity held
    var averageBuyPrice: Double  // PRU (prix de revient unitaire)
    var currentValue: Double?    // Current market value when displayed (otherwise nil)
    var currency: String
    var pageNumber: Int
    var confidence: Double
    var isSelected: Bool = true  // the user can untick it before importing

    /// Estimated acquisition cost (quantity × average cost). Serves as the
    /// default value when the capture shows no market value.
    var investedCost: Double { quantity * averageBuyPrice }

    /// Asset type inferred from the name / ticker (same heuristic as PDFExtractedOrder).
    var assetType: String {
        let upper = (assetName + " " + ticker).uppercased()
        if upper.contains("ETF") || upper.contains("TRACKER") { return "ETF" }
        if upper.contains("OPCVM") || upper.contains("SICAV") || upper.contains("FCP") { return "FUND" }
        if upper.contains("OBLIG") || upper.contains("BOND") { return "BOND" }
        if upper.contains("CRYPTO") || upper.contains("BTC") || upper.contains("ETH") { return "CRYPTO" }
        return "STOCK"
    }
}

// `ImportSourceKind` and `ImportUnitDiagnostic` are shared by both imports
// and live in `Features/Import/Pipeline/ImportElement.swift`, the common
// base of the unified pipeline.

/// Result of parsing a PDF page / capture / text block.
struct PDFPageResult: Identifiable {
    let id = UUID()
    let pageNumber: Int
    let rawText: String
    var orders: [PDFExtractedOrder]
    /// Positions extracted when the page is a portfolio capture.
    var positions: [PDFExtractedPosition] = []
    /// Mode detected for this page.
    var detectedMode: PDFDocumentMode = .orders
    var parsingNote: String?    // AI comment (e.g. "summary page, no orders")
    /// Why this page yielded nothing (diagnostic shown in the UI).
    var diagnostic: ImportUnitDiagnostic = .extracted
    /// Actual nature of the document (sniffed), for the UI's wording.
    var kind: ImportSourceKind = .unknown
    /// True if the operations come from the deterministic extractor (no AI).
    var usedDeterministicFallback: Bool = false
    /// Source file, when the import aggregates several documents. Feeds the
    /// diagnostic block shared with the transaction import.
    var sourceName: String = ""
}

/// Summary of the final import.
struct PDFImportResult {
    let positionsCreated: Int
    let ordersInserted: Int
    let positionsReused: Int    // Existing positions that orders were attached to
    let errors: [String]
}

/// Aggregation: groups orders by ISIN/ticker to create or reuse positions.
struct PDFPositionGroup: Identifiable {
    let id = UUID()
    let isin: String
    let ticker: String
    let assetName: String
    let assetType: String
    var orders: [PDFExtractedOrder]

    var totalQuantityBuy: Double {
        orders.filter { $0.orderType == "BUY" }.reduce(0) { $0 + $1.quantity }
    }
    var totalQuantitySell: Double {
        orders.filter { $0.orderType == "SELL" }.reduce(0) { $0 + $1.quantity }
    }
    var netQuantity: Double { totalQuantityBuy - totalQuantitySell }
}
