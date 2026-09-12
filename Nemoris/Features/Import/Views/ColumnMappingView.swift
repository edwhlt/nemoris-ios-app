import SwiftUI

/// Step 2 of the import flow: column mapping.
/// Shows the detected headers + 3 pickers (date / amount / label) + a preview.
/// If a mapping already exists for the header signature, it's preloaded and
/// the user can just confirm.
struct ColumnMappingView: View {
    @Environment(\.dismiss) private var dismiss

    /// Result of the INITIAL parse (auto-detected separator).
    let parsed: CSVParser.Parsed
    /// Other sheets of the same workbook, if any.
    ///
    /// ⚠️ A workbook must NOT produce one mapping step per sheet:
    /// the user would then have to map "Notes" and every side tab before
    /// reaching the one they care about, with no way to pick one.
    /// Here they pick, and only the chosen sheet is imported.
    var siblingSheets: [ImportGrid] = []
    /// Raw text, to re-parse if the user corrects the separator.
    /// `nil` = separator not editable (a caller that doesn't have the content).
    var rawContent: String? = nil
    let accountId: Int
    let sourceFile: String?
    /// Single-file path: this view creates the session itself.
    var onSessionCreated: ((ImportSessionSummary) -> Void)? = nil
    /// Multi-file path: this view only RENDERS the rows, it's the
    /// entry screen that aggregates them with those of other files before
    /// creating ONE single session.
    var onRowsReady: (([ImportSessionRow]) -> Void)? = nil
    /// Starting number for global row numbering (multi-file).
    var startingRowNumber: Int = 1

    @State private var dateColumn: Int? = nil
    @State private var amountColumn: Int? = nil
    @State private var labelColumn: Int? = nil
    @State private var amountDecimal: String = ","
    @State private var dateFormat: String?
    @State private var mappingFound = false
    @State private var savingError: String?

    private let sessionRepo = ImportSessionRepository()

    /// Re-parse after changing the separator. `nil` until the user
    /// has touched it: we then show the initial parse.
    @State private var reparsed: CSVParser.Parsed?
    @State private var separator: String = ""

    /// Chosen sheet when the source is a workbook (`nil` = the first one).
    @State private var selectedSheet: ImportGrid?

    /// All the workbook's sheets, in file order.
    private var allSheets: [ImportGrid] { [parsed] + siblingSheets }

    /// Source of truth for the screen: a CSV's re-parse if there is one, else
    /// the chosen sheet, else the first one.
    private var effective: CSVParser.Parsed { reparsed ?? selectedSheet ?? parsed }

    private var headers: [String] { effective.headers }
    private var signature: String { ColumnMappingSignature.compute(headers: headers) }

    private var canConfirm: Bool {
        dateColumn != nil && amountColumn != nil && labelColumn != nil
            && dateColumn != amountColumn && dateColumn != labelColumn && amountColumn != labelColumn
    }

    var body: some View {
        Form {
            if mappingFound {
                Section {
                    Label("Format connu — mapping pré-rempli depuis un import précédent.",
                          systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.success)
                }
            }

            Section("Mapping des colonnes") {
                columnPicker("Date", selection: $dateColumn)
                columnPicker("Montant", selection: $amountColumn)
                columnPicker("Libellé", selection: $labelColumn)
            }

            Section("Format détecté") {
                Picker("Décimal du montant", selection: $amountDecimal) {
                    Text("Virgule (1,23)").tag(",")
                    Text("Point (1.23)").tag(".")
                }
                .pickerStyle(.segmented)

                LabeledContent("Format de date") {
                    Text(dateFormat ?? "Auto")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                if rawContent != nil {
                    // Editable: auto-detection gets it wrong on some
                    // files, and the columns then become unusable.
                    Picker("Séparateur", selection: $separator) {
                        Text("Point-virgule ( ; )").tag(";")
                        Text("Virgule ( , )").tag(",")
                        Text("Tabulation").tag("\t")
                    }
                    .onChange(of: separator) { _, newValue in
                        reparse(with: newValue)
                    }
                } else if !effective.separator.isEmpty {
                    LabeledContent("Séparateur CSV") {
                        Text(separatorLabel(effective.separator))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                // A workbook has no separator: its cells are
                // delimited by the format itself. Showing an empty field
                // would suggest a failed detection.
                if allSheets.count > 1 {
                    Picker("Feuille", selection: Binding(
                        get: { effective.sheetName ?? "" },
                        set: { name in selectSheet(named: name) }
                    )) {
                        ForEach(allSheets, id: \.sheetName) { sheet in
                            Text(sheet.sheetName ?? "Feuille")
                                .tag(sheet.sheetName ?? "")
                        }
                    }
                } else if let sheet = effective.sheetName, !sheet.isEmpty {
                    LabeledContent("Feuille") {
                        Text(sheet).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }

            Section("Aperçu (3 premières lignes)") {
                ForEach(Array(effective.rows.prefix(3).enumerated()), id: \.offset) { _, row in
                    previewRow(row)
                }
            }

            if let savingError {
                Section { Text(savingError).foregroundStyle(AppTheme.Colors.danger) }
            }
        }
        .nemorisFormStyle()
        // The title follows the source: "CSV Mapping" on a workbook
        // sheet would make the user doubt they picked the right file.
        .localizedNavigationTitle(effective.sheetName == nil ? "Mapping CSV" : "Mapping du tableau")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { createSession() } label: {
                    Label("Continuer", systemImage: "arrow.right")
                }
                .disabled(!canConfirm)
            }
        }
        .task { loadOrAutoDetect() }
    }

    // MARK: Sub-views

    @ViewBuilder
    private func columnPicker(_ title: String, selection: Binding<Int?>) -> some View {
        Picker(title, selection: selection) {
            Text("—").tag(Int?.none)
            ForEach(Array(headers.enumerated()), id: \.offset) { idx, name in
                Text("\(name) (col \(idx + 1))").tag(Int?.some(idx))
            }
        }
    }

    @ViewBuilder
    private func previewRow(_ row: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                preview("Date", value: cell(row, dateColumn))
                preview("Montant", value: cell(row, amountColumn))
            }
            preview("Libellé", value: cell(row, labelColumn), monospaced: true)
            // Tentative de parsing live
            if let dateRaw = cell(row, dateColumn),
               let parsedDate = CSVParser.parseDate(dateRaw, hintFormat: dateFormat) {
                (Text("→ ") + Text(parsedDate, format: Date.FormatStyle(date: .abbreviated, time: .omitted)))
                    .font(.caption2).foregroundStyle(AppTheme.Colors.success)
            }
            if let amountRaw = cell(row, amountColumn),
               let parsedAmount = CSVParser.parseAmount(amountRaw, decimal: amountDecimal) {
                (Text("→ ") + Text(parsedAmount, format: .currency(code: "EUR")))
                    .font(.caption2).foregroundStyle(parsedAmount >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
            }
        }
        .padding(.vertical, 4)
    }

    private func preview(_ label: LocalizedStringKey, value: String?, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.caption2.bold()).foregroundStyle(AppTheme.Colors.textSecondary)
            if let value, !value.isEmpty {
                Text(value)
                    .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                    .lineLimit(2)
            } else {
                Text("—").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
        }
    }

    private func cell(_ row: [String], _ index: Int?) -> String? {
        guard let i = index, i >= 0, i < row.count else { return nil }
        return row[i]
    }

    private func separatorLabel(_ sep: String) -> String {
        switch sep {
        case ";": return "Point-virgule (;)"
        case ",": return "Virgule (,)"
        case "\t": return "Tabulation"
        default: return sep
        }
    }

    // MARK: Logic

    /// Re-parses the file with the separator the user set, then
    /// re-runs detection: changing the separator changes the headers,
    /// so the previous column indices no longer mean anything.
    private func reparse(with newSeparator: String) {
        guard let rawContent, newSeparator != effective.separator else { return }
        guard let result = CSVParser.parse(content: rawContent, forcedSeparator: newSeparator) else { return }
        reparsed = result
        dateColumn = nil
        amountColumn = nil
        labelColumn = nil
        mappingFound = false
        loadOrAutoDetect()
    }

    /// Sheet switch: the columns change, so the previous selection
    /// no longer makes sense — same reason as changing the separator.
    private func selectSheet(named name: String) {
        guard let sheet = allSheets.first(where: { ($0.sheetName ?? "") == name }) else { return }
        selectedSheet = sheet
        reparsed = nil
        dateColumn = nil
        amountColumn = nil
        labelColumn = nil
        mappingFound = false
        loadOrAutoDetect()
    }

    private func loadOrAutoDetect() {
        if separator.isEmpty { separator = effective.separator }
        if let existing = sessionRepo.findMapping(headerSignature: signature) {
            dateColumn = existing.dateColumnIndex
            amountColumn = existing.amountColumnIndex
            labelColumn = existing.labelColumnIndex
            amountDecimal = existing.amountDecimal
            dateFormat = existing.dateFormat
            mappingFound = true
            return
        }
        // Simple heuristic on header names.
        let lower = headers.map { $0.lowercased().folding(options: .diacriticInsensitive, locale: .current) }
        dateColumn = lower.firstIndex(where: { $0.contains("date") })
        amountColumn = lower.firstIndex(where: { $0.contains("montant") || $0.contains("amount") || $0.contains("debit") || $0.contains("credit") })
        labelColumn = lower.firstIndex(where: { $0.contains("libelle") || $0.contains("label") || $0.contains("description") || $0.contains("wording") || $0.contains("operation") })

        // Date-format detection on the first 5 lines
        if let dCol = dateColumn {
            let samples = effective.rows.prefix(5).compactMap { row -> String? in
                guard dCol < row.count else { return nil }
                return row[dCol]
            }
            dateFormat = CSVParser.detectDateFormat(samples: samples)
        }
    }

    private func createSession() {
        guard let dCol = dateColumn, let aCol = amountColumn, let lCol = labelColumn else { return }

        // 1. Persists the mapping for next time
        let mapping = ColumnMapping(
            headerSignature: signature,
            dateColumnIndex: dCol,
            amountColumnIndex: aCol,
            labelColumnIndex: lCol,
            separator: effective.separator,
            dateFormat: dateFormat,
            amountDecimal: amountDecimal
        )
        sessionRepo.saveMapping(mapping)

        // 2. Builds the rows (logic shared with the "format already
        //    known" path, which never shows this screen).
        let (rows, _) = CSVParser.buildRows(parsed: effective,
                                              mapping: mapping,
                                              startingAt: startingRowNumber,
                                              sourceFile: sourceFile)
        guard !rows.isEmpty else {
            savingError = "Aucune ligne exploitable (vérifiez le format date/montant)."
            return
        }

        // 3a. Multi-file: hand off, aggregation and session creation
        //     happen upstream.
        if let onRowsReady {
            onRowsReady(rows)
            return
        }

        // 3b. Single file: create directly.
        guard let summary = sessionRepo.createSession(rows: rows,
                                                      accountId: accountId,
                                                      sourceFile: sourceFile) else {
            savingError = "Échec de la sauvegarde de la session."
            return
        }
        onSessionCreated?(summary)
    }
}
