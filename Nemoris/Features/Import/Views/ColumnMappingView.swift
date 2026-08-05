import SwiftUI

/// Étape 2 du nouveau parcours d'import (AXE D) : mapping des colonnes.
/// Affiche les en-têtes détectés + 3 pickers (date / montant / libellé) + preview.
/// Si un mapping existe déjà pour la signature du header, il est préchargé et
/// l'utilisateur peut juste valider.
struct ColumnMappingView: View {
    @Environment(\.dismiss) private var dismiss

    /// Résultat du parsing INITIAL (séparateur autodétecté).
    let parsed: CSVParserV3.Parsed
    /// Texte brut, pour re-parser si l'utilisateur corrige le séparateur.
    /// `nil` = séparateur non modifiable (appelant qui n'a pas le contenu).
    var rawContent: String? = nil
    let accountId: Int
    let sourceFile: String?
    /// Chemin mono-fichier : cette vue crée la session elle-même.
    var onSessionCreated: ((ImportSessionSummary) -> Void)? = nil
    /// Chemin multi-fichiers : cette vue ne fait que RENDRE les lignes, c'est
    /// l'écran d'entrée qui les agrège avec celles des autres fichiers avant de
    /// créer UNE session unique.
    var onRowsReady: (([ImportSessionRow]) -> Void)? = nil
    /// Numéro de départ pour la numérotation globale des lignes (multi-fichiers).
    var startingRowNumber: Int = 1

    @State private var dateColumn: Int? = nil
    @State private var amountColumn: Int? = nil
    @State private var labelColumn: Int? = nil
    @State private var amountDecimal: String = ","
    @State private var dateFormat: String?
    @State private var mappingFound = false
    @State private var savingError: String?

    private let sessionRepo = ImportSessionRepository()

    /// Re-parsing après changement de séparateur. `nil` tant que l'utilisateur
    /// n'y a pas touché : on affiche alors le parsing initial.
    @State private var reparsed: CSVParserV3.Parsed?
    @State private var separator: String = ""

    /// Source de vérité de l'écran : le re-parsing s'il existe, sinon l'initial.
    private var effective: CSVParserV3.Parsed { reparsed ?? parsed }

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
                    // Modifiable : l'autodétection se trompe sur certains
                    // fichiers, et les colonnes deviennent alors inexploitables.
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
                // Un classeur n'a pas de séparateur : ses cellules sont
                // délimitées par le format lui-même. Afficher un champ vide
                // laisserait croire à une détection ratée.
                if let sheet = effective.sheetName, !sheet.isEmpty {
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
        // Le titre suit la source : « Mapping CSV » sur une feuille de classeur
        // ferait douter l'utilisateur d'avoir choisi le bon fichier.
        .navigationTitle(effective.sheetName == nil ? "Mapping CSV" : "Mapping du tableau")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Continuer") { createSession() }
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
               let parsedDate = CSVParserV3.parseDate(dateRaw, hintFormat: dateFormat) {
                Text("→ \(parsedDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2).foregroundStyle(AppTheme.Colors.success)
            }
            if let amountRaw = cell(row, amountColumn),
               let parsedAmount = CSVParserV3.parseAmount(amountRaw, decimal: amountDecimal) {
                Text("→ \(parsedAmount.formatted(.currency(code: "EUR")))")
                    .font(.caption2).foregroundStyle(parsedAmount >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
            }
        }
        .padding(.vertical, 4)
    }

    private func preview(_ label: String, value: String?, monospaced: Bool = false) -> some View {
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

    /// Re-parse le fichier avec le séparateur imposé par l'utilisateur, puis
    /// ré-applique la détection : changer de séparateur change les en-têtes,
    /// donc les index de colonnes précédents n'ont plus aucun sens.
    private func reparse(with newSeparator: String) {
        guard let rawContent, newSeparator != effective.separator else { return }
        guard let result = CSVParserV3.parse(content: rawContent, forcedSeparator: newSeparator) else { return }
        reparsed = result
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
        // Heuristique simple sur les noms d'en-têtes.
        let lower = headers.map { $0.lowercased().folding(options: .diacriticInsensitive, locale: .current) }
        dateColumn = lower.firstIndex(where: { $0.contains("date") })
        amountColumn = lower.firstIndex(where: { $0.contains("montant") || $0.contains("amount") || $0.contains("debit") || $0.contains("credit") })
        labelColumn = lower.firstIndex(where: { $0.contains("libelle") || $0.contains("label") || $0.contains("description") || $0.contains("wording") || $0.contains("operation") })

        // Détection du format de date sur 5 premières lignes
        if let dCol = dateColumn {
            let samples = effective.rows.prefix(5).compactMap { row -> String? in
                guard dCol < row.count else { return nil }
                return row[dCol]
            }
            dateFormat = CSVParserV3.detectDateFormat(samples: samples)
        }
    }

    private func createSession() {
        guard let dCol = dateColumn, let aCol = amountColumn, let lCol = labelColumn else { return }

        // 1. Persiste le mapping pour la prochaine fois
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

        // 2. Construit les rows (logique partagée avec le chemin « format déjà
        //    connu », qui n'affiche jamais cet écran).
        let (rows, _) = CSVParserV3.buildRows(parsed: effective,
                                              mapping: mapping,
                                              startingAt: startingRowNumber,
                                              sourceFile: sourceFile)
        guard !rows.isEmpty else {
            savingError = "Aucune ligne exploitable (vérifiez le format date/montant)."
            return
        }

        // 3a. Multi-fichiers : on rend la main, l'agrégation et la création de
        //     session se font en amont.
        if let onRowsReady {
            onRowsReady(rows)
            return
        }

        // 3b. Mono-fichier : création directe.
        guard let summary = sessionRepo.createSession(rows: rows,
                                                      accountId: accountId,
                                                      sourceFile: sourceFile) else {
            savingError = "Échec de la sauvegarde de la session."
            return
        }
        onSessionCreated?(summary)
    }
}
