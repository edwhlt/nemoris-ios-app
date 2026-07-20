import Foundation

// MARK: - Modèles pour l'import PDF d'ordres d'investissement

/// Un ordre extrait du PDF par l'IA, avant validation user.
struct PDFExtractedOrder: Identifiable, Hashable {
    let id = UUID()
    var orderType: String       // "BUY" | "SELL" | "DIV"
    var assetName: String       // Nom lisible (ex: "Amundi MSCI World")
    var ticker: String          // Ticker / symbole (ex: "CW8")
    var isin: String            // ISIN si détecté (ex: "LU1681043599")
    var quantity: Double
    var unitPrice: Double       // Prix unitaire d'exécution
    var fees: Double            // Frais de courtage
    var executedAt: Date
    var currency: String        // EUR, USD, etc.
    var notes: String?          // Infos complémentaires extraites
    var pageNumber: Int         // Page source dans le PDF
    var confidence: Double      // 0…1 — confiance de l'IA sur cet ordre
    var isSelected: Bool = true // L'user peut décocher avant import

    /// Coût total brut
    var totalCost: Double { quantity * unitPrice + fees }

    /// Asset type déduit du nom / ISIN
    var assetType: String {
        let upper = (assetName + " " + ticker).uppercased()
        if upper.contains("ETF") || upper.contains("TRACKER") { return "ETF" }
        if upper.contains("OPCVM") || upper.contains("SICAV") || upper.contains("FCP") { return "FUND" }
        if upper.contains("OBLIG") || upper.contains("BOND") { return "BOND" }
        if upper.contains("CRYPTO") || upper.contains("BTC") || upper.contains("ETH") { return "CRYPTO" }
        return "STOCK"
    }
}

/// Mode détecté par l'IA pour un document/page : relevé d'ORDRES (avis d'opéré)
/// ou CAPTURE DE PORTEFEUILLE (liste de positions avec qté/PRU/valeur, sans dates
/// d'exécution — typiquement un screenshot d'app PEA/CTO).
enum PDFDocumentMode: String, Codable {
    case orders
    case positionsSnapshot
    case unknown
}

/// Une position extraite d'une capture de portefeuille (Chantier C — mode snapshot).
/// Contrairement à un ordre, il n'y a pas de date d'exécution : on connaît l'état
/// courant (qté détenue, PRU, valeur de marché) mais pas l'historique.
struct PDFExtractedPosition: Identifiable, Hashable {
    let id = UUID()
    var assetName: String        // Nom lisible (ex: "Amundi MSCI World")
    var ticker: String           // Ticker / symbole
    var isin: String             // ISIN si détecté
    var quantity: Double         // Quantité détenue
    var averageBuyPrice: Double  // PRU (prix de revient unitaire)
    var currentValue: Double?    // Valeur de marché actuelle si affichée (sinon nil)
    var currency: String
    var pageNumber: Int
    var confidence: Double
    var isSelected: Bool = true  // L'user peut décocher avant import

    /// Coût d'acquisition estimé (qté × PRU). Sert de valeur par défaut si la
    /// capture n'affiche pas de valeur de marché.
    var investedCost: Double { quantity * averageBuyPrice }

    /// Asset type déduit du nom / ticker (même heuristique que PDFExtractedOrder).
    var assetType: String {
        let upper = (assetName + " " + ticker).uppercased()
        if upper.contains("ETF") || upper.contains("TRACKER") { return "ETF" }
        if upper.contains("OPCVM") || upper.contains("SICAV") || upper.contains("FCP") { return "FUND" }
        if upper.contains("OBLIG") || upper.contains("BOND") { return "BOND" }
        if upper.contains("CRYPTO") || upper.contains("BTC") || upper.contains("ETH") { return "CRYPTO" }
        return "STOCK"
    }
}

/// Résultat du parsing d'une page PDF/image.
struct PDFPageResult: Identifiable {
    let id = UUID()
    let pageNumber: Int
    let rawText: String
    var orders: [PDFExtractedOrder]
    /// Chantier C — positions extraites si la page est une capture de portefeuille.
    var positions: [PDFExtractedPosition] = []
    /// Mode détecté par l'IA pour cette page.
    var detectedMode: PDFDocumentMode = .orders
    var parsingNote: String?    // Commentaire IA (ex: "page de résumé, pas d'ordres")
}

/// Résumé de l'import final.
struct PDFImportResult {
    let positionsCreated: Int
    let ordersInserted: Int
    let positionsReused: Int    // Positions existantes auxquelles on a rattaché des ordres
    let errors: [String]
}

/// Agrégation : regroupe les ordres par ISIN/ticker pour créer ou réutiliser des positions.
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
