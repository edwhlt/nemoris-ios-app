import Foundation

// MARK: - Modèle d'échange du pipeline d'import unifié
//
// Moteur PUR (`import Foundation` UNIQUEMENT — ni PDFKit, ni Vision, ni
// FoundationModels, ni SwiftUI), même doctrine que `PortfolioEvolutionBuilder`,
// `BankStatementExtractor` et `MerchantQueryPlanner` : testable hors Xcode via
// `run_import_pipeline_tests.sh`. Le garde-fou de pureté EST le harnais — un
// import interdit le casse à la compilation.
//
// ─── Pourquoi un modèle d'échange ──────────────────────────────────────────
//
// Cinq sous-pipelines d'entrée (image, PDF, CSV, XLSX, XML) alimentent deux
// résolutions métier (transactions, investissements). Sans point de passage
// obligé, chaque combinaison finit par avoir son propre chemin : c'est ce qui
// s'était produit (deux parseurs avec deux réconciliations, deux décodeurs
// JSON, et un TROISIÈME import CSV enfoui dans le module Investissements).
//
// `ImportElement` est ce point de passage. Tout ce qui entre en ressort sous
// cette forme, et tout ce qui consomme un import part de là.
//
// ─── Pas d'étape de classification métier ──────────────────────────────────
//
// Le diagramme de cadrage prévoyait un nœud CLASSIFY (Transaction /
// Investissement / Ambigu) APRÈS extraction. Il n'existe pas ici, et c'est
// délibéré : la destination est choisie par l'utilisateur AVANT l'analyse, et
// c'est elle qui calibre les instructions données au modèle (le même PDF peut
// être un relevé bancaire ou un avis d'opéré). Reclassifier après coup
// introduirait une seconde source de vérité sur une question déjà tranchée,
// qui pourrait la contredire.
//
// Ce que CLASSIFY apportait d'utile — détecter qu'un fichier ne ressemble à
// rien d'exploitable — est obtenu gratuitement : c'est un `ImportUnitReport`
// dont le diagnostic vaut `.nothingRecognized`, et l'UI le montre déjà.
// La sous-classification achat/vente/dividende, elle, reste où elle a toujours
// été : dans le payload investissements.

// MARK: - Destination

/// Où atterrissent les données lues. Le choix est fait EN AMONT de l'analyse,
/// et c'est ce qui permet de calibrer les instructions données à l'IA : le même
/// PDF peut être un relevé bancaire ou un avis d'opéré, et deviner le type à
/// partir du contenu est exactement ce que le petit modèle embarqué rate le
/// plus souvent.
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

    /// Ce que l'utilisateur est censé fournir, affiché sous le sélecteur.
    var hint: String {
        switch self {
        case .transactions:
            return "Relevé de compte, export CSV de ta banque, ou capture d'écran de la liste des opérations."
        case .investments:
            return "Avis d'opéré, relevé de portefeuille, ou capture d'écran de ton PEA/CTO."
        }
    }
}

// MARK: - Nature de la source

/// Nature réelle d'un document, déterminée par SNIFFING de ses octets d'en-tête
/// et jamais par son extension.
///
/// ⚠️ Se fier à l'extension est un bug déjà payé en production : une capture
/// partagée par la share sheet arrive nommée `<uuid>.dat` (le type abstrait
/// `public.image` n'a pas de `preferredFilenameExtension`), tombait dans la
/// branche « texte brut », et `String(contentsOf:encoding:.isoLatin1)` — qui
/// n'échoue JAMAIS, toute suite d'octets étant du Latin-1 valide — produisait
/// 670 000 caractères de binaire envoyés au modèle comme s'il s'agissait d'un
/// relevé.
///
/// Sert aussi au vocabulaire de l'UI : parler de « page » pour une capture
/// d'écran ou un tableur n'a pas de sens depuis que l'import est multi-format.
enum ImportSourceKind: String, Codable, Hashable, Sendable {
    case pdf
    case image
    /// Texte brut : CSV, TSV, relevé exporté en .txt.
    case text
    /// Classeur XLSX (ZIP + XML).
    case spreadsheet
    /// Relevé structuré : CAMT.053 (ISO 20022) ou OFX/QFX.
    case xml
    case unknown

    /// Nom de l'unité analysée. L'UI compose « 3 captures analysées ».
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

    /// Vrai pour les formats dont la STRUCTURE est déjà explicite et n'a donc
    /// besoin d'aucune interprétation par un modèle : les champs sont nommés
    /// (colonnes CSV, balises CAMT/OFX, cellules de tableur).
    ///
    /// C'est ce qui décide si une unité passe par l'étage IA ou pas — pas le
    /// fait qu'un modèle soit disponible. Envoyer un CAMT.053 à un LLM serait
    /// à la fois plus lent et moins fiable que de lire ses balises.
    var isStructured: Bool {
        switch self {
        case .text, .spreadsheet, .xml: return true
        case .pdf, .image, .unknown:    return false
        }
    }
}

// MARK: - Diagnostic

/// Pourquoi une unité n'a rien donné.
///
/// Sans ça, l'UI ne peut afficher qu'un « Rien à importer » indifférencié :
/// impossible pour l'utilisateur (ou pour nous en support) de distinguer un OCR
/// muet, une IA indisponible, une IA qui a échoué, et un document réellement
/// sans opérations.
enum ImportUnitDiagnostic: Equatable, Hashable, Codable, Sendable {
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
    /// Le format structuré a été lu, mais son contenu n'était pas exploitable
    /// (classeur vide, XML d'un dialecte inconnu…).
    case malformedStructure(String)
    /// Document lu et moteur OK, mais aucune opération reconnaissable dedans.
    case nothingRecognized

    var isFailure: Bool { self != .extracted }

    /// Message court affiché à l'utilisateur.
    var userMessage: String {
        switch self {
        case .extracted:        return "Opérations extraites."
        case .noTextExtracted:  return "Aucun texte n'a pu être lu dans ce document. Si c'est une photo, vérifie qu'elle est nette et bien cadrée."
        case .notTextContent:   return "Le format du fichier n'a pas été reconnu (contenu binaire). Réessaie en exportant un PDF, une capture d'écran, un CSV ou un relevé XML."
        case .aiUnavailable:    return "L'analyse intelligente n'est pas disponible sur cet appareil (Apple Intelligence requis). L'extraction automatique a été utilisée à la place."
        case .aiFailed(let r):  return "L'analyse intelligente a échoué : \(r)"
        case .malformedStructure(let r): return "Le fichier a été ouvert mais son contenu n'a pas pu être exploité : \(r)"
        // ⚠️ Message PARTAGÉ par les deux imports : il ne doit citer ni
        // « achat / vente / dividende » (vocabulaire investissements), ni
        // « le texte » — sur le chemin image, aucun texte n'est extrait, c'est
        // le modèle qui lit la capture.
        case .nothingRecognized: return "Le document a bien été lu, mais aucune opération n'y a été reconnue."
        }
    }
}

// MARK: - Origine

/// D'où vient un élément. Conservé jusqu'à la revue pour que l'utilisateur
/// puisse vérifier qu'AUCUNE source n'a été perdue en route sur un import
/// multi-fichiers — le détail par source du bandeau de fin d'analyse est
/// construit là-dessus.
struct ImportElementOrigin: Codable, Hashable, Sendable {
    /// Nom lisible du fichier d'origine.
    var sourceName: String
    /// Rang du fichier dans le batch (0-indexé), pour un tri stable quand deux
    /// fichiers portent le même nom.
    var sourceIndex: Int
    /// Numéro d'unité GLOBAL dans le batch (1-indexé). Global et non par
    /// fichier : deux fichiers repartant à 1 produisent des numéros en
    /// collision, et les rapports d'échec désignent alors une unité ambiguë.
    var unitNumber: Int
    /// Rang de l'unité DANS son fichier (1-indexé) — le n° de page d'un PDF,
    /// le rang d'une feuille de classeur.
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

// MARK: - Position détenue (pendant pur de `PDFExtractedPosition`)

/// Une ligne détenue extraite d'une capture de portefeuille.
///
/// Volontairement distincte de `PDFExtractedPosition`, qui porte de l'état d'UI
/// (`id`, `isSelected`) : le pipeline reste pur, l'état d'écran est ajouté à la
/// frontière de la revue.
struct ExtractedStatementPosition: Equatable, Codable, Hashable, Sendable {
    var assetName: String
    var ticker: String
    var isin: String
    var quantity: Double
    var averageBuyPrice: Double
    /// Valeur de marché si la capture l'affiche.
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

/// Ce qu'un élément transporte réellement.
///
/// Le type est FIXÉ par la destination choisie en amont, il n'est jamais
/// deviné : un pipeline lancé vers les transactions ne produit que des
/// `.transaction`.
enum ImportPayload: Equatable, Codable, Hashable, Sendable {
    case transaction(ExtractedBankTransaction)
    case investmentOrder(ExtractedStatementOrder)
    case investmentPosition(ExtractedStatementPosition)

    /// Destination à laquelle ce payload appartient.
    var destinationKind: ImportPayloadKind {
        switch self {
        case .transaction:        return .transaction
        case .investmentOrder:    return .investmentOrder
        case .investmentPosition: return .investmentPosition
        }
    }
}

/// Discriminant léger, utile pour compter/filtrer sans déballer le payload.
enum ImportPayloadKind: String, Codable, Hashable, Sendable {
    case transaction
    case investmentOrder
    case investmentPosition
}

// MARK: - Élément

/// L'unité de sortie du pipeline, quel que soit le format d'entrée.
struct ImportElement: Identifiable, Equatable, Codable, Hashable, Sendable {
    var id: UUID
    var origin: ImportElementOrigin
    var payload: ImportPayload
    /// 0…1. Reprise du payload à la construction, mais gardée à ce niveau : la
    /// réconciliation de deux sources (IA + déterministe) la relève, et l'UI
    /// trie dessus sans avoir à connaître le type de payload.
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

// MARK: - Rapport par unité

/// Ce qui s'est passé sur UNE unité analysée (page PDF, capture, feuille,
/// bloc de texte). Porté séparément des éléments parce qu'une unité qui ne
/// produit RIEN est justement celle dont il faut parler.
struct ImportUnitReport: Identifiable, Equatable, Codable, Hashable, Sendable {
    var id: UUID
    var origin: ImportElementOrigin
    /// Ce que l'app a réellement lu — c'est LUI qui permet de distinguer un OCR
    /// muet d'une interprétation ratée. Sur le chemin image (modèle multimodal),
    /// c'est la réponse brute du modèle, puisqu'aucun texte n'est extrait.
    var rawText: String
    var recognizedCount: Int
    var diagnostic: ImportUnitDiagnostic
    /// Vrai quand le résultat vient de l'extraction déterministe, sans IA.
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

// MARK: - Résultat de batch

/// La sortie complète d'un import : les éléments, et le journal de ce qui s'est
/// passé unité par unité.
struct ImportBatchResult: Equatable, Codable, Sendable {
    var elements: [ImportElement]
    var units: [ImportUnitReport]

    init(elements: [ImportElement] = [], units: [ImportUnitReport] = []) {
        self.elements = elements
        self.units = units
    }

    var isEmpty: Bool { elements.isEmpty }

    /// Répartition par fichier source, dans l'ordre du batch.
    ///
    /// C'est ce qui rend la fusion VÉRIFIABLE d'un coup d'œil : sur un import
    /// mêlant CSV et documents analysés, l'absence d'une source ne se voyait
    /// pas dans un total agrégé.
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

    /// JSON indenté des éléments d'une source — l'inspection de debug de la fin
    /// d'analyse.
    ///
    /// ⚠️ Sur la structure NORMALISÉE, pas sur le texte OCR brut : c'est le
    /// seul format qui couvre aussi les sources sans OCR (CSV, tableur, XML),
    /// pour lesquelles « voir le texte lu » n'a aucun sens.
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

    /// Fusionne deux résultats en conservant l'ordre et en renumérotant les
    /// unités à la suite — utilisé quand une même session agrège plusieurs
    /// passes (des CSV déjà mappés, puis des documents analysés).
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

/// Ce qu'une source a produit. Alimente le détail dépliable du bandeau.
struct ImportSourceSummary: Identifiable, Equatable, Codable, Hashable, Sendable {
    var sourceIndex: Int
    var sourceName: String
    var kind: ImportSourceKind
    var unitCount: Int = 0
    var failedUnitCount: Int = 0
    var elementCount: Int = 0

    var id: Int { sourceIndex }

    /// Vrai quand la source n'a RIEN produit — le cas qu'il faut voir.
    var isEmptyResult: Bool { elementCount == 0 }

    /// « 42 opérations » / « aucune opération ».
    func summaryLabel(noun: String) -> String {
        switch elementCount {
        case 0:  return "aucune \(noun)"
        case 1:  return "1 \(noun)"
        default: return "\(elementCount) \(noun)s"
        }
    }
}
