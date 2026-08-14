import SwiftUI

/// Relecture du résultat d'une analyse de document (relevé PDF, capture) avant
/// création de la session d'import.
///
/// Elle n'analyse RIEN elle-même : le travail a été fait par
/// `DocumentImportCoordinator`, en arrière-plan, pendant que l'utilisateur
/// continuait à se servir de l'app. Cet écran ne fait que présenter le résultat
/// — c'est ce qui permet de le fermer et de le rouvrir depuis le bandeau sans
/// rien perdre.
///
/// La revue détaillée (tiers, catégories, doublons) reste `ImportSessionView`,
/// inchangée : ici on valide seulement que la lecture est correcte.
struct TransactionDocumentReviewView: View {

    let coordinator: DocumentImportCoordinator
    let onConfirm: (ImportSessionSummary) -> Void
    let onCancel: () -> Void

    @State private var savingError: String?
    private let sessionRepo = ImportSessionRepository()

    private var units: [AnalysisUnit] { coordinator.batch.analysisUnits() }
    private var rows: [ImportSessionRow] { coordinator.transactionRows }

    /// Vocabulaire adapté au format réel : parler de « pages » pour une capture
    /// d'écran n'a aucun sens depuis que l'import est multi-format.
    private var unitLabel: String {
        (units.first?.kind ?? .unknown).unitLabel(count: units.count)
    }

    /// Ce que CHAQUE source a produit, tables mappées comprises.
    ///
    /// ⚠️ Construit depuis le pipeline et non depuis les lignes retenues : une
    /// source qui n'a RIEN donné est justement celle qu'il faut voir, et elle
    /// n'apparaît par définition dans aucune ligne. C'est ce qui manquait pour
    /// repérer qu'un fichier ne remontait pas dans un import multi-format.
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
        // Tint posé par vue (cf. convention notée dans `ImportEntryView`).
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
                // Le détail par fichier vit dans sa propre section
                // (`ImportSourceBreakdownSection`), partagée avec les autres
                // écrans de revue.
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
                // Aperçu borné : la revue complète, ligne par ligne, c'est
                // l'écran de session qui la fait.
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

    // MARK: - Création de la session

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
