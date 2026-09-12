import Foundation

// MARK: - Reading an XLSX workbook
//
// PURE engine — testable via `run_import_pipeline_tests.sh`.
//
// An XLSX is a ZIP archive of XML files (the OOXML standard):
//   • `xl/workbook.xml`        → the list of sheets and their display order
//   • `xl/_rels/workbook.xml.rels` → where each sheet is actually stored
//   • `xl/sharedStrings.xml`   → ALL of the workbook's strings, deduplicated
//   • `xl/worksheets/sheetN.xml` → the cells, which reference the index above
//
// The output is one `ImportGrid` per sheet, i.e. EXACTLY what the CSV
// reader produces: both formats ask the user the same
// question (which column is the date, the amount, the label) and
// therefore share the same mapping screen.

struct XLSXReaderError: Error, Equatable {
    let reason: String
}

enum XLSXReader {

    /// One table per non-empty sheet, in workbook order.
    static func grids(from data: Data) -> Result<[ImportGrid], XLSXReaderError> {
        let shared: [String]
        switch ZIPArchiveReader.extract(named: "xl/sharedStrings.xml", from: data) {
        case .success(let xml): shared = SharedStringsParser.parse(xml)
        // A workbook can have no shared strings at all (numbers only):
        // the file being absent is legitimate, not an error.
        case .failure:          shared = []
        }

        let entries: [ZIPArchiveReader.Entry]
        switch ZIPArchiveReader.entries(in: data) {
        case .success(let list): entries = list
        case .failure(let error): return .failure(XLSXReaderError(reason: error.reason))
        }

        let sheetNames = workbookSheetNames(data: data)

        // NUMERIC sort on the file's index: a lexicographic sort ranks
        // `sheet10.xml` before `sheet2.xml`, and the sheets end up out of
        // order — so matched to the wrong names.
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

    /// Turns a matrix of cells into a usable table.
    ///
    /// ⚠️ Blank LEADING rows are skipped: a bank export very often
    /// starts with an identity block (holder's name, IBAN, period),
    /// and taking the first non-blank row as the header would give a
    /// one-column table. We look for the first row that has the document's
    /// dominant width.
    static func grid(from matrix: [[String]], sheetName: String?) -> ImportGrid? {
        let rows = matrix.filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !rows.isEmpty else { return nil }

        // Dominant width = that of the data rows, not that of a
        // decorative, isolated header.
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

        let isHeader = CSVParser.looksLikeHeader(first)
        let headers = isHeader ? first : (0..<first.count).map { "Colonne \($0 + 1)" }
        let dataRows = isHeader ? Array(body.dropFirst()) : body

        return ImportGrid(headers: headers,
                          hasExplicitHeader: isHeader,
                          rows: dataRows,
                          separator: "",
                          sheetName: sheetName)
    }

    /// `xl/worksheets/sheet12.xml` → 12. Returns `Int.max` if the index isn't
    /// readable, so those sheets end up last without breaking the sort.
    static func sheetIndex(_ path: String) -> Int {
        let digits = path
            .replacingOccurrences(of: "xl/worksheets/sheet", with: "")
            .replacingOccurrences(of: ".xml", with: "")
        return Int(digits) ?? Int.max
    }

    /// Tab names declared by the workbook, in display order.
    static func workbookSheetNames(data: Data) -> [String] {
        guard case .success(let xml) = ZIPArchiveReader.extract(named: "xl/workbook.xml", from: data) else {
            return []
        }
        return WorkbookParser.sheetNames(xml)
    }
}

// MARK: - sharedStrings.xml

/// The workbook's strings, deduplicated and referenced by index.
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
            // ⚠️ An entry can be split across SEVERAL `<t>`s by formatting
            // runs (`<r>`): "Transfer" + "SEPA" are two
            // fragments of a single string. They must be concatenated, otherwise the
            // label arrives truncated at its first style change.
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

/// Extracts the cell matrix of a sheet.
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
        /// `<is><t>`: a string written in plain sight INSIDE the cell rather than in
        /// the shared table (what several exporters produce).
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
                // ⚠️ An EMPTY cell simply isn't written in the
                // XML: without the `r` reference ("C7"), columns shift
                // left as soon as a gap appears, and mapping then
                // points at the wrong column for the rest of the file.
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

        /// Renders a cell's display value.
        private func resolve() -> String {
            let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if insideInlineString || cellType == "inlineStr" { return raw }
            if cellType == "s", let index = Int(raw), index >= 0, index < sharedStrings.count {
                return sharedStrings[index]
            }
            if cellType == "b" { return raw == "1" ? "VRAI" : "FAUX" }
            // ⚠️ Excel does NOT store dates as text: it's a number
            // of days since 1900-01-01, and only the cell's STYLE says
            // it's a date. Without this conversion, a workbook's date
            // column arrives as "45865" and no date format
            // recognizes it.
            if let style = cellStyle, XLSXCellReference.isDateStyle(style),
               let serial = Double(raw), let date = XLSXCellReference.date(fromSerial: serial) {
                return XLSXCellReference.isoFormatter.string(from: date)
            }
            return raw
        }
    }
}

// MARK: - OOXML utilities

enum XLSXCellReference {

    /// "BC12" → 54 (0-indexed column index).
    static func columnIndex(from reference: String) -> Int {
        var index = 0
        for character in reference.uppercased() {
            guard let ascii = character.asciiValue, ascii >= 65, ascii <= 90 else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(0, index - 1)
    }

    /// Date styles among Excel's BUILT-IN formats (14-22 for dates and
    /// times, 45-47 for durations).
    ///
    /// ⚠️ Accepted approximation: a workbook that defines a CUSTOM date
    /// format declares it in `xl/styles.xml`, which this reader doesn't open.
    /// Such a column will come out as a raw number — the user will
    /// see it in the mapping preview and can correct it, which a silently
    /// wrong conversion would not allow.
    static func isDateStyle(_ style: Int) -> Bool {
        (14...22).contains(style) || (45...47).contains(style)
    }

    /// Excel serial number → date.
    ///
    /// ⚠️ The offset is 25,569 days between the Excel epoch (1900-01-01 = 1)
    /// and the Unix epoch (1970-01-01), not 25,567: Excel treats 1900
    /// as a leap year — a Lotus 1-2-3 bug deliberately kept for
    /// compatibility. The phantom day ("February 29, 1900") shifts every
    /// later date by exactly one day, and that shift is baked into
    /// the constant. Any date on a bank statement falls after it.
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

/// Element name without its namespace prefix.
///
/// ⚠️ `XMLParser` is NOT configured in namespace mode here: OOXML
/// and ISO 20022 documents use prefixes that vary by
/// producer (`x:row`, `ns2:Ntry`…), and comparing the full qualified name
/// would fail parsing on half of real-world files.
func localName(_ qualified: String) -> String {
    guard let colon = qualified.lastIndex(of: ":") else { return qualified }
    return String(qualified[qualified.index(after: colon)...])
}
