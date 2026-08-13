import Foundation

/// Parseur CSV minimal pour le nouveau parcours d'import.
/// Autodétection séparateur + lecture des cellules en respectant les guillemets.
enum CSVParser {

    /// Le CSV n'a plus son propre modèle de sortie : il produit la table
    /// COMMUNE aux sources tabulaires (`ImportGrid`), la même que le lecteur de
    /// classeurs XLSX. C'est ce qui permet aux deux formats de partager
    /// l'écran de mapping des colonnes au lieu d'en avoir chacun un.
    typealias Parsed = ImportGrid

    static let separatorCandidates: [Character] = [";", "\t", ","]

    static let dateFormatCandidates: [String] = [
        "dd/MM/yyyy", "yyyy-MM-dd", "MM/dd/yyyy",
        "dd-MM-yyyy", "yyyy/MM/dd", "dd.MM.yyyy"
    ]

    // MARK: - High level

    /// `forcedSeparator` : imposé par l'utilisateur depuis l'écran de mapping.
    /// L'autodétection se trompe sur les fichiers où un autre séparateur est
    /// plus fréquent dans l'en-tête (libellés contenant des virgules, colonne
    /// unique…), et le mapping devient alors inexploitable — il faut donc
    /// pouvoir la corriger à la main.
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

    /// Détecte le format de date le plus probable à partir d'un échantillon.
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

    /// Parse un montant en respectant le décimal (`,` ou `.`).
    /// Gère les espaces (séparateurs de milliers) et les parenthèses (négatifs comptables).
    static func parseAmount(_ raw: String, decimal: String = ",") -> Double? {
        var s = raw
            .replacingOccurrences(of: "\u{00A0}", with: "")     // espace insécable
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

    // MARK: - Construction des lignes de session

    /// Applique un mapping de colonnes et produit les lignes de session.
    ///
    /// Extrait de `ColumnMappingView` parce qu'un import multi-fichiers réutilise
    /// AUTOMATIQUEMENT le mapping mémorisé d'un format déjà connu, sans jamais
    /// afficher l'écran de mapping : le même code doit servir les deux chemins.
    ///
    /// `startingAt` continue une numérotation GLOBALE : deux fichiers repartant
    /// chacun à 1 produiraient des `sourceRowNumber` en collision dans une
    /// session agrégée, et les rapports d'échec au commit désigneraient une
    /// ligne ambiguë.
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
