import SwiftUI

/// Review of a document analysis result (PDF statement, capture) before the
/// import session is created.
///
/// It analyzes NOTHING itself: the work was done by
/// `DocumentImportCoordinator`, in the background, while the user kept using
/// the app. This screen only presents the result — which is what allows
/// closing it and reopening it from the banner without losing anything.
///
/// The detailed review (payees, categories, duplicates) remains
/// `ImportSessionView`: here only the reading itself is validated.
struct TransactionDocumentReviewView: View {

    let coordinator: DocumentImportCoordinator
    let onConfirm: (ImportSessionSummary) -> Void
    let onCancel: () -> Void

    @State private var savingError: String?
    private let sessionRepo = ImportSessionRepository()

    private var units: [AnalysisUnit] { coordinator.batch.analysisUnits() }
    private var rows: [ImportSessionRow] { coordinator.transactionRows }

    /// Wording matched to the real format: "pages" means nothing for a screenshot.
    private var unitLabel: String {
        (units.first?.kind ?? .unknown).unitLabel(count: units.count)
    }

    /// What EACH source produced, mapped tables included.
    ///
    /// Built from the pipeline, not from the kept rows: a source that yielded
    /// NOTHING is exactly the one to see, and by definition it appears in no row.
    /// That's what makes a file that didn't come through visible in a
    /// multi-format import.
    private var sourceBreakdown: [ImportSourceSummary] {
        let summaries = coordinator.sourceBreakdown
        guard summaries.count > 1 else { return [] }
        return summaries
    }

    var body: some View {
        Form {
            resultsSection
            ImportSourceBreakdownSection(
                summaries: sourceBreakdown,
                noun: "opération",
                debugJSON: { coordinator.batch.debugJSON(sourceIndex: $0.sourceIndex) })
            DocumentAnalysisDiagnosticsSection(units: units)
            if let savingError {
                Section {
                    Text(savingError)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.danger)
                }
            }
            Section {
                Button {
                    createSession()
                } label: {
                    HStack {
                        Spacer()
                        Label("Importer \(rows.count) opération(s)", systemImage: "square.and.arrow.down.fill")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .disabled(rows.isEmpty)
                .tint(AppTheme.Colors.accent)
            }
        }
        .nemorisFormStyle()
        // Tint set per view (see the convention noted in `ImportEntryView`).
        .tint(AppTheme.Colors.accent)
        .paneChrome("Résultat de l'analyse", cancelLabel: "Annuler", onCancel: onCancel)
    }

    // MARK: - Sections

    @ViewBuilder
    private var resultsSection: some View {
        Section {
            if rows.isEmpty {
                EmptyStateView(
                    icon: "doc.questionmark",
                    title: "Aucune opération reconnue",
                    message: "Le détail ci-dessous indique ce qui a été lu. Un export CSV depuis ta banque reste le format le plus fiable."
                )
            } else {
                LabeledContent("Opérations trouvées") {
                    Text("\(rows.count)")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                LabeledContent("Documents analysés") {
                    Text("\(units.count) \(unitLabel)")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                // The per-file detail lives in its own section (`ImportSourceBreakdownSection`),
                // shared with the other review screens.
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
            if !rows.isEmpty {
                Text("Vérifie l'aperçu ci-dessous, puis importe : tu pourras corriger chaque ligne (tier, catégorie) à l'étape suivante.")
            }
        }

        if !rows.isEmpty {
            Section("Aperçu") {
                // Bounded preview: the full row-by-row review is the session screen's job.
                ForEach(rows.prefix(20)) { row in
                    previewRow(row)
                }
                if rows.count > 20 {
                    Text("+ \(rows.count - 20) autre(s) opération(s)")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
    }

    private func previewRow(_ row: ImportSessionRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.rawLabel)
                    .font(.subheadline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(row.date, format: .dateTime.day().month().year())
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    if let hint = row.paymentTypeHint {
                        Text(hint)
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(AppTheme.Colors.accent.opacity(0.15), in: Capsule())
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(row.amount, format: .currency(code: "EUR"))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(row.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Session creation

    private func createSession() {
        guard let summary = sessionRepo.createSession(rows: rows,
                                                      accountId: coordinator.accountId,
                                                      sourceFile: coordinator.sourceLabel) else {
            savingError = "Échec de la sauvegarde de la session."
            return
        }
        onConfirm(summary)
    }
}
