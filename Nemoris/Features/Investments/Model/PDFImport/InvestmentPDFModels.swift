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

/// Nature réelle du document analysé, déterminée par SNIFFING du contenu et non
/// par l'extension du fichier (cf. `InvestmentPDFParser.detectKind`).
///
/// Sert aussi au vocabulaire de l'UI : parler de « page » pour une capture
/// d'écran ou un CSV n'a pas de sens depuis que l'import est multi-format.
enum InvestmentDocumentKind: String {
    case pdf
    case image
    case text
    case unknown

    /// Nom de l'unité analysée, au singulier. L'UI compose « 3 captures analysées ».
    func unitLabel(count: Int) -> String {
        let plural = count > 1
        switch self {
        case .pdf:     return plural ? "pages analysées" : "page analysée"
        case .image:   return plural ? "captures analysées" : "capture analysée"
        case .text:    return plural ? "blocs analysés" : "bloc analysé"
        case .unknown: return plural ? "éléments analysés" : "élément analysé"
        }
    }
}

/// Pourquoi une page n'a rien donné. Sans ça, l'UI ne peut afficher qu'un
/// « Rien à importer » indifférencié : impossible pour l'utilisateur (ou pour
/// nous en support) de distinguer un OCR muet, une IA indisponible, une IA qui
/// a échoué, et un document réellement sans opérations.
enum PDFPageDiagnostic: Equatable {
    /// Extraction OK, opérations trouvées.
    case extracted
    /// Aucun texte n'a pu être extrait (image illisible, PDF scanné vide…).
    case noTextExtracted
    /// Le contenu n'est pas du texte exploitable (binaire pris pour du texte).
    case notTextContent
    /// Le moteur IA n'est pas disponible sur cet appareil.
    case aiUnavailable
    /// Le moteur IA a échoué (contexte dépassé, garde-fou, erreur interne…).
    case aiFailed(String)
    /// Texte lu et IA OK, mais aucune opération reconnaissable dedans.
    case nothingRecognized

    var isFailure: Bool { self != .extracted }

    /// Message court affiché à l'utilisateur.
    var userMessage: String {
        switch self {
        case .extracted:        return "Opérations extraites."
        case .noTextExtracted:  return "Aucun texte n'a pu être lu dans ce document. Si c'est une photo, vérifie qu'elle est nette et bien cadrée."
        case .notTextContent:   return "Le format du fichier n'a pas été reconnu (contenu binaire). Réessaie en exportant un PDF, une capture d'écran ou un CSV."
        case .aiUnavailable:    return "L'analyse intelligente n'est pas disponible sur cet appareil (Apple Intelligence requis). L'extraction automatique a été utilisée à la place."
        case .aiFailed(let r):  return "L'analyse intelligente a échoué : \(r)"
        case .nothingRecognized: return "Le texte a bien été lu, mais aucune opération (achat, vente, dividende) n'y a été reconnue."
        }
    }
}

/// Résultat du parsing d'une page PDF / capture / bloc de texte.
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
    /// Pourquoi cette page n'a rien donné (diagnostic affiché dans l'UI).
    var diagnostic: PDFPageDiagnostic = .extracted
    /// Nature réelle du document (sniffée), pour le vocabulaire de l'UI.
    var kind: InvestmentDocumentKind = .unknown
    /// Vrai si les opérations viennent de l'extracteur déterministe (sans IA).
    var usedDeterministicFallback: Bool = false
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
