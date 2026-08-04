import SwiftUI

/// Étape d'analyse d'un relevé PDF / d'une capture d'écran dans le parcours
/// d'import de transactions — l'équivalent de `ColumnMappingView` pour les
/// documents non tabulaires.
///
/// Elle ne demande AUCUN mapping : les colonnes n'existent pas dans un PDF. Elle
/// analyse, montre ce qui a été compris (et pourquoi, en cas d'échec), puis rend
/// les lignes au parcours qui les agrège. La revue réelle — résolution des
/// tiers, catégories, doublons — reste `ImportSessionView`, inchangée.
struct TransactionDocumentParseView: View {

    let sources: [TransactionDocumentParser.DocumentSource]
    /// Numéro de départ de la numérotation globale des lignes.
    var startingRowNumber: Int = 1
    let onRowsReady: ([ImportSessionRow]) -> Void

    @State private var units: [TransactionDocumentParser.UnitResult] = []
    @State private var isParsing = true
    @State private var progress: (done: Int, total: Int) = (0, 1)
    @State private var expandedText: UUID?

    private var allTransactions: [ExtractedBankTransaction] {
        units.flatMap(\.transactions)
    }

    /// Vocabulaire adapté au format réel : parler de « pages » pour une capture
    /// d'écran n'a aucun sens depuis que l'import est multi-format.
    private var unitLabel: String {
        let kind = units.first?.kind ?? .unknown
        return kind.unitLabel(count: units.count)
    }

    var body: some View {
        Form {
            if isParsing {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Analyse en cours…")
                            .font(.subheadline.weight(.semibold))
                        // Barre déterminée dès que le nombre d'unités est connu ;
                        // indéterminée pendant l'extraction du texte (OCR / pages
                        // PDF), où le total ne l'est pas encore.
                        if progress.total > 0 {
                            ProgressView(value: Double(progress.done),
                                         total: Double(progress.total))
                                .tint(AppTheme.Colors.accent)
                            Text("\(progress.done) / \(progress.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        } else {
                            ProgressView()
                                .tint(AppTheme.Colors.accent)
                            Text("Lecture du document…")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                resultsSection
                diagnosticsSection
            }
        }
        .nemorisFormStyle()
        .navigationTitle("Analyse du document")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Continuer") {
                    onRowsReady(TransactionDocumentParser.rows(from: units,
                                                               startingAt: startingRowNumber))
                }
                .disabled(isParsing || allTransactions.isEmpty)
            }
        }
        .task { await runParsing() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var resultsSection: some View {
        Section {
            if allTransactions.isEmpty {
                ContentUnavailableView(
                    "Aucune opération reconnue",
                    systemImage: "doc.questionmark",
                    description: Text("Le détail ci-dessous indique ce qui a été lu. Un export CSV depuis ta banque reste le format le plus fiable.")
                )
            } else {
                LabeledContent("Opérations trouvées") {
                    Text("\(allTransactions.count)")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                LabeledContent("Documents analysés") {
                    Text("\(units.count) \(unitLabel)")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                if units.contains(where: \.usedDeterministicFallback) {
                    Label("Extraction automatique utilisée (sans IA) sur une partie du document.",
                          systemImage: "gearshape.2")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        } header: {
            Text("Résultat")
        } footer: {
            if !allTransactions.isEmpty {
                Text("Vérifie l'aperçu ci-dessous, puis continue : tu pourras corriger chaque ligne (tier, catégorie) à l'étape suivante.")
            }
        }

        if !allTransactions.isEmpty {
            Section("Aperçu") {
                // Aperçu borné : la revue complète, ligne par ligne, c'est
                // l'écran de session qui la fait.
                ForEach(Array(allTransactions.prefix(20).enumerated()), id: \.offset) { _, tx in
                    previewRow(tx)
                }
                if allTransactions.count > 20 {
                    Text("+ \(allTransactions.count - 20) autre(s) opération(s)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
    }

    private func previewRow(_ tx: ExtractedBankTransaction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.label)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(tx.date)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    if let hint = tx.paymentTypeHint {
                        Text(hint)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(AppTheme.Colors.accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(tx.amount, format: .currency(code: "EUR"))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(tx.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
        }
        .padding(.vertical, 2)
    }

    /// Ce qui a échoué et POURQUOI. Sans ce détail, un OCR muet, une IA
    /// indisponible et un document réellement vide donnent le même écran —
    /// impossible pour l'utilisateur de savoir quoi corriger.
    @ViewBuilder
    private var diagnosticsSection: some View {
        let problems = units.filter { $0.diagnostic.isFailure || $0.transactions.isEmpty }
        if !problems.isEmpty {
            Section("Détail de l'analyse") {
                ForEach(problems) { unit in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(unit.sourceName) · unité \(unit.unitNumber)")
                            .font(.caption.weight(.semibold))
                        Text(unit.diagnostic.userMessage)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !unit.rawText.isEmpty {
                            Button {
                                expandedText = (expandedText == unit.id) ? nil : unit.id
                            } label: {
                                Label(expandedText == unit.id
                                      ? "Masquer le texte lu"
                                      : "Voir le texte lu (\(unit.rawText.count) caractères)",
                                      systemImage: "text.alignleft")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(AppTheme.Colors.accent)
                            if expandedText == unit.id {
                                ScrollView {
                                    Text(unit.rawText)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 220)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Analyse

    private func runParsing() async {
        guard units.isEmpty else { return }   // `.task` peut rejouer sur re-render
        isParsing = true
        // total = 0 tant que l'extraction du texte tourne : le nombre d'unités
        // n'est connu qu'une fois les PDF ouverts et les images océrisées.
        progress = (0, 0)
        let results = await TransactionDocumentParser.shared.parse(sources: sources) { done, total in
            progress = (done, total)
        }
        units = results
        isParsing = false
    }
}
