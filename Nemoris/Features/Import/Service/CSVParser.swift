import Foundation

/// Minimal CSV parser for the import flow.
/// Separator auto-detection + reading cells while honoring quotes.
enum CSVParser {

    /// CSV has no output model of its own: it produces the table COMMON to
    /// tabular sources (`ImportGrid`), the same as the XLSX workbook reader.
    /// That's what lets both formats share the column mapping screen instead of
    /// each having one.
    typealias Parsed = ImportGrid

    static let separatorCandidates: [Character] = [";", "\t", ","]

    static let dateFormatCandidates: [String] = [
        "dd/MM/yyyy", "yyyy-MM-dd", "MM/dd/yyyy",
        "dd-MM-yyyy", "yyyy/MM/dd", "dd.MM.yyyy"
    ]

    // MARK: - High level

    /// `forcedSeparator`: imposed by the user from the mapping screen.
    /// Auto-detection gets it wrong on files where another separator is more
    /// frequent in the header (labels containing commas, a single column…), and
    /// the mapping then becomes unusable — so it must be correctable by hand.
    static func parse(content: String, forcedSeparator: String? = nil) -> Parsed? {
        let lines = content
            .split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return nil }

        let separator = forcedSeparator.flatMap(\.first) ?? detectSeparator(in: first)
        let firstCols = parseLine(first, separator: separator)
        let isHeader = looksLikeHeader(firstCols)

        let headers: [String]
        let body: [[String]]
        if isHeader {
            headers = firstCols
            body = lines.dropFirst().map { parseLine($0, separator: separator) }
        } else {
            headers = (0..<firstCols.count).map { "Colonne \($0 + 1)" }
            body = lines.map { parseLine($0, separator: separator) }
        }
        return Parsed(headers: headers,
                      hasExplicitHeader: isHeader,
                      rows: body,
                      separator: String(separator))
    }

    static func detectSeparator(in line: String) -> Character {
        for c in separatorCandidates where line.contains(c) { return c }
        return ";"
    }

    static func looksLikeHeader(_ cols: [String]) -> Bool {
        let keywords = ["libelle", "libellé", "description", "label", "wording",
                        "operation", "date", "montant", "amount", "debit", "credit",
                        "libelle_brut", "categorie"]
        return cols.contains { col in
            let lower = col.lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)
            return keywords.contains { lower.contains($0) }
        }
    }

    // MARK: - Cell parsing (quoted)

    static func parseLine(_ line: String, separator: Character) -> [String] {
        var cols: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if inQuotes {
                if ch == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex, line[next] == "\"" {
                        current.append("\""); i = next
                    } else {
                        inQuotes = false
                    }
                } else { current.append(ch) }
            } else {
                if ch == separator { cols.append(current); current = "" }
                else if ch == "\"" { inQuotes = true }
                else { current.append(ch) }
            }
            i = line.index(after: i)
        }
        cols.append(current)
        return cols.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Field parsing

    static func parseDate(_ raw: String, hintFormat: String? = nil) -> Date? {
        let cleaned = raw.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")

        if let hint = hintFormat {
            formatter.dateFormat = hint
            if let d = formatter.date(from: cleaned) { return d }
        }
        for fmt in dateFormatCandidates {
            formatter.dateFormat = fmt
            if let d = formatter.date(from: cleaned) { return d }
        }
        return nil
    }

    /// Detects the most likely date format from a sample.
    static func detectDateFormat(samples: [String]) -> String? {
        for fmt in dateFormatCandidates {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = fmt
            let okCount = samples.compactMap { formatter.date(from: $0.trimmingCharacters(in: .whitespaces)) }.count
            if okCount > samples.count / 2 { return fmt }
        }
        return nil
    }

    /// Parses an amount honoring the decimal separator (`,` or `.`).
    /// Handles spaces (thousands separators) and parentheses (accounting negatives).
    static func parseAmount(_ raw: String, decimal: String = ",") -> Double? {
        var s = raw
            .replacingOccurrences(of: "\u{00A0}", with: "")     // non-breaking space
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        if decimal == "," {
            s = s.replacingOccurrences(of: ".", with: "")
                 .replacingOccurrences(of: ",", with: ".")
        } else {
            s = s.replacingOccurrences(of: ",", with: "")
        }
        guard let value = Double(s) else { return nil }
        return negative ? -value : value
    }

    // MARK: - Building session rows

    /// Applies a column mapping and produces the session rows.
    ///
    /// Separate from `ColumnMappingView` so the same code can serve every path
    /// that builds rows from a mapping.
    ///
    /// `startingAt` continues a GLOBAL numbering: two files each restarting at 1
    /// would produce colliding `sourceRowNumber`s in an aggregated session, and
    /// the commit's failure reports would point at an ambiguous row.
    static func buildRows(parsed: Parsed,
                          mapping: ColumnMapping,
                          startingAt startNumber: Int = 1,
                          sourceFile: String? = nil) -> (rows: [ImportSessionRow], rejected: Int) {
        var rows: [ImportSessionRow] = []
        rows.reserveCapacity(parsed.rows.count)
        var rejected = 0
        var number = startNumber

        for raw in parsed.rows {
            let dateRaw = (mapping.dateColumnIndex < raw.count) ? raw[mapping.dateColumnIndex] : ""
            let amountRaw = (mapping.amountColumnIndex < raw.count) ? raw[mapping.amountColumnIndex] : ""
            let labelRaw = (mapping.labelColumnIndex < raw.count) ? raw[mapping.labelColumnIndex] : ""
            guard let date = parseDate(dateRaw, hintFormat: mapping.dateFormat),
                  let amount = parseAmount(amountRaw, decimal: mapping.amountDecimal),
                  !labelRaw.isEmpty
            else { rejected += 1; continue }

            rows.append(ImportSessionRow(
                sourceRowNumber: number,
                rawLabel: labelRaw,
                date: date,
                amount: amount,
                sourceFile: sourceFile
            ))
            number += 1
        }
        return (rows, rejected)
    }
}
