import Foundation

// MARK: - Lecture d'un classeur XLSX
//
// Moteur PUR — testable via `run_import_pipeline_tests.sh`.
//
// Un XLSX est une archive ZIP de fichiers XML (norme OOXML) :
//   • `xl/workbook.xml`        → la liste des feuilles et leur ordre d'affichage
//   • `xl/_rels/workbook.xml.rels` → où chaque feuille est réellement rangée
//   • `xl/sharedStrings.xml`   → TOUTES les chaînes du classeur, déduplifiées
//   • `xl/worksheets/sheetN.xml` → les cellules, qui référencent l'index ci-dessus
//
// La sortie est une `ImportGrid` par feuille, c'est-à-dire EXACTEMENT ce que
// produit le lecteur CSV : les deux formats posent la même question à
// l'utilisateur (quelle colonne est la date, le montant, le libellé) et
// partagent donc le même écran de mapping.

struct XLSXReaderError: Error, Equatable {
    let reason: String
}

enum XLSXReader {

    /// Une table par feuille non vide, dans l'ordre du classeur.
    static func grids(from data: Data) -> Result<[ImportGrid], XLSXReaderError> {
        let shared: [String]
        switch ZIPArchiveReader.extract(named: "xl/sharedStrings.xml", from: data) {
        case .success(let xml): shared = SharedStringsParser.parse(xml)
        // Un classeur peut n'avoir aucune chaîne partagée (que des nombres) :
        // l'absence du fichier est légitime, pas une erreur.
        case .failure:          shared = []
        }

        let entries: [ZIPArchiveReader.Entry]
        switch ZIPArchiveReader.entries(in: data) {
        case .success(let list): entries = list
        case .failure(let error): return .failure(XLSXReaderError(reason: error.reason))
        }

        let sheetNames = workbookSheetNames(data: data)

        // Tri NUMÉRIQUE sur l'index du fichier : un tri lexicographique classe
        // `sheet10.xml` avant `sheet2.xml`, et les feuilles ressortent dans le
        // désordre — donc associées aux mauvais noms.
        let sheetEntries = entries
            .filter { $0.name.hasPrefix("xl/worksheets/sheet") && $0.name.hasSuffix(".xml") }
            .sorted { sheetIndex($0.name) < sheetIndex($1.name) }

        guard !sheetEntries.isEmpty else {
            return .failure(XLSXReaderError(reason: "aucune feuille trouvée dans le classeur"))
        }

        var grids: [ImportGrid] = []
        for (position, entry) in sheetEntries.enumerated() {
            guard case .success(let xml) = ZIPArchiveReader.extract(entry, from: data) else { continue }
            let matrix = WorksheetParser.parse(xml, sharedStrings: shared)
            guard let grid = grid(from: matrix,
                                  sheetName: position < sheetNames.count ? sheetNames[position] : nil)
            else { continue }
            grids.append(grid)
        }
        return .success(grids)
    }

    // MARK: - Matrice → table

    /// Transforme une matrice de cellules en table exploitable.
    ///
    /// ⚠️ Les lignes vides de TÊTE sont sautées : un export bancaire commence
    /// très souvent par un bloc d'identité (nom du titulaire, IBAN, période),
    /// et prendre la première ligne non vide comme en-tête donnerait une table
    /// à une colonne. On cherche la première ligne qui a la largeur dominante
    /// du document.
    static func grid(from matrix: [[String]], sheetName: String?) -> ImportGrid? {
        let rows = matrix.filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !rows.isEmpty else { return nil }

        // Largeur dominante = celle des lignes de données, pas celle d'un
        // en-tête décoratif isolé.
        var widthCount: [Int: Int] = [:]
        for row in rows {
            let width = row.reduce(into: 0) { result, cell in
                if !cell.trimmingCharacters(in: .whitespaces).isEmpty { result += 1 }
            }
            widthCount[width, default: 0] += 1
        }
        let dominant = widthCount.filter { $0.key >= 2 }.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }?.key ?? rows.map(\.count).max() ?? 0
        guard dominant >= 2 else { return nil }

        let startIndex = rows.firstIndex { row in
            row.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= dominant
        } ?? 0
        let body = Array(rows[startIndex...])
        guard let first = body.first else { return nil }

        let isHeader = CSVParserV3.looksLikeHeader(first)
        let headers = isHeader ? first : (0..<first.count).map { "Colonne \($0 + 1)" }
        let dataRows = isHeader ? Array(body.dropFirst()) : body

        return ImportGrid(headers: headers,
                          hasExplicitHeader: isHeader,
                          rows: dataRows,
                          separator: "",
                          sheetName: sheetName)
    }

    /// `xl/worksheets/sheet12.xml` → 12. Renvoie `Int.max` si l'index n'est pas
    /// lisible, pour que ces feuilles finissent en queue sans casser le tri.
    static func sheetIndex(_ path: String) -> Int {
        let digits = path
            .replacingOccurrences(of: "xl/worksheets/sheet", with: "")
            .replacingOccurrences(of: ".xml", with: "")
        return Int(digits) ?? Int.max
    }

    /// Noms d'onglets déclarés par le classeur, dans l'ordre d'affichage.
    static func workbookSheetNames(data: Data) -> [String] {
        guard case .success(let xml) = ZIPArchiveReader.extract(named: "xl/workbook.xml", from: data) else {
            return []
        }
        return WorkbookParser.sheetNames(xml)
    }
}

// MARK: - sharedStrings.xml

/// Les chaînes du classeur, déduplifiées et référencées par index.
enum SharedStringsParser {

    static func parse(_ xml: Data) -> [String] {
        let delegate = Delegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var insideItem = false
        private var insideText = false

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch localName(name) {
            case "si": insideItem = true; current = ""
            // ⚠️ Une entrée peut être découpée en PLUSIEURS `<t>` par des runs
            // de mise en forme (`<r>`) : « Virement » + « SEPA » sont deux
            // fragments d'une seule chaîne. Il faut les concaténer, sinon le
            // libellé arrive tronqué à son premier changement de style.
            case "t":  insideText = true
            default:   break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if insideItem && insideText { current += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            switch localName(name) {
            case "si": strings.append(current); insideItem = false; current = ""
            case "t":  insideText = false
            default:   break
            }
        }
    }
}

// MARK: - workbook.xml

enum WorkbookParser {

    static func sheetNames(_ xml: Data) -> [String] {
        let delegate = Delegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.names
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var names: [String] = []
        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            guard localName(name) == "sheet", let sheetName = attributes["name"] else { return }
            names.append(sheetName)
        }
    }
}

// MARK: - worksheet.xml

/// Extrait la matrice de cellules d'une feuille.
enum WorksheetParser {

    static func parse(_ xml: Data, sharedStrings: [String]) -> [[String]] {
        let delegate = Delegate(sharedStrings: sharedStrings)
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        let sharedStrings: [String]
        var rows: [[String]] = []

        private var row: [String] = []
        private var value = ""
        private var cellType = ""
        private var cellStyle: Int?
        private var columnIndex = 0
        private var capturing = false
        /// `<is><t>` : chaîne écrite en clair DANS la cellule plutôt que dans
        /// la table partagée (ce que produisent plusieurs exporteurs).
        private var insideInlineString = false

        init(sharedStrings: [String]) {
            self.sharedStrings = sharedStrings
        }

        func parser(_ parser: XMLParser, didStartElement name: String,
                    namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch localName(name) {
            case "row":
                row = []
                columnIndex = 0
            case "c":
                cellType = attributes["t"] ?? ""
                cellStyle = attributes["s"].flatMap(Int.init)
                value = ""
                // ⚠️ Une cellule VIDE n'est tout simplement pas écrite dans le
                // XML : sans la référence `r` (« C7 »), les colonnes se
                // décalent vers la gauche dès qu'un trou apparaît, et le
                // mapping désigne alors la mauvaise colonne pour toute la
                // suite du fichier.
                if let reference = attributes["r"] {
                    let target = XLSXCellReference.columnIndex(from: reference)
                    while columnIndex < target {
                        row.append("")
                        columnIndex += 1
                    }
                }
            case "v", "t":
                capturing = true
            case "is":
                insideInlineString = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { value += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String,
                    namespaceURI: String?, qualifiedName: String?) {
            switch localName(name) {
            case "v", "t":
                capturing = false
            case "is":
                insideInlineString = false
            case "c":
                row.append(resolve())
                columnIndex += 1
            case "row":
                rows.append(row)
                row = []
            default:
                break
            }
        }

        /// Rend la valeur d'affichage d'une cellule.
        private func resolve() -> String {
            let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if insideInlineString || cellType == "inlineStr" { return raw }
            if cellType == "s", let index = Int(raw), index >= 0, index < sharedStrings.count {
                return sharedStrings[index]
            }
            if cellType == "b" { return raw == "1" ? "VRAI" : "FAUX" }
            // ⚠️ Excel ne stocke PAS les dates comme du texte : c'est un nombre
            // de jours depuis le 1900-01-01, et seul le STYLE de la cellule dit
            // qu'il s'agit d'une date. Sans cette conversion, la colonne date
            // d'un classeur arrive en « 45865 » et aucun format de date ne la
            // reconnaît.
            if let style = cellStyle, XLSXCellReference.isDateStyle(style),
               let serial = Double(raw), let date = XLSXCellReference.date(fromSerial: serial) {
                return XLSXCellReference.isoFormatter.string(from: date)
            }
            return raw
        }
    }
}

// MARK: - Utilitaires OOXML

enum XLSXCellReference {

    /// « BC12 » → 54 (index de colonne 0-indexé).
    static func columnIndex(from reference: String) -> Int {
        var index = 0
        for character in reference.uppercased() {
            guard let ascii = character.asciiValue, ascii >= 65, ascii <= 90 else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(0, index - 1)
    }

    /// Styles de date des formats INTÉGRÉS d'Excel (14-22 pour les dates et
    /// heures, 45-47 pour les durées).
    ///
    /// ⚠️ Approximation assumée : un classeur qui définit un format de date
    /// PERSONNALISÉ le déclare dans `xl/styles.xml`, que ce lecteur n'ouvre pas.
    /// Une telle colonne ressortira comme un nombre brut — l'utilisateur la
    /// verra dans l'aperçu du mapping et pourra corriger, ce qu'une conversion
    /// silencieusement fausse ne permettrait pas.
    static func isDateStyle(_ style: Int) -> Bool {
        (14...22).contains(style) || (45...47).contains(style)
    }

    /// Numéro de série Excel → date.
    ///
    /// ⚠️ Le décalage est de 25 569 jours entre l'époque Excel (1900-01-01 = 1)
    /// et l'époque Unix (1970-01-01), et non 25 567 : Excel considère 1900
    /// comme bissextile — un bug de Lotus 1-2-3 délibérément conservé pour la
    /// compatibilité. Le jour fantôme (« 29 février 1900 ») décale toutes les
    /// dates postérieures d'exactement un jour, et c'est ce décalage qu'intègre
    /// la constante. Toute date d'un relevé bancaire y est postérieure.
    static func date(fromSerial serial: Double) -> Date? {
        guard serial > 1, serial < 2_958_466 else { return nil }   // 1900 … 9999
        let seconds = (serial - 25_569) * 86_400
        return Date(timeIntervalSince1970: seconds)
    }

    static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// Nom d'élément sans son préfixe de namespace.
///
/// ⚠️ `XMLParser` n'est PAS configuré en mode namespace ici : les documents
/// OOXML et ISO 20022 utilisent des préfixes variables selon le producteur
/// (`x:row`, `ns2:Ntry`…), et comparer le nom qualifié complet ferait échouer
/// le parsing sur la moitié des fichiers réels.
func localName(_ qualified: String) -> String {
    guard let colon = qualified.lastIndex(of: ":") else { return qualified }
    return String(qualified[qualified.index(after: colon)...])
}
