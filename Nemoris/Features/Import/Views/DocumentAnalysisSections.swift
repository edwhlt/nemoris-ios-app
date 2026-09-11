import SwiftUI

// `ImportDocumentSource` and `ImportDocumentReader` live in
// `Features/Import/Pipeline/Readers/`: they are reading engines, not views.

/// UI blocks SHARED by both document imports (transactions and investments):
/// the analysis progress bar and the per-unit detail on failure.
///
/// **Why share them:** both imports read the same formats (PDF, capture,
/// text), with the same splitting into units and the same failure modes
/// (`ImportUnitDiagnostic`). Letting each module reinvent its processing
/// screen guarantees they diverge.

/// Neutral view of an analyzed unit, fed by either parser.
struct AnalysisUnit: Identifiable {
    let id: UUID
    let unitNumber: Int
    /// Source file (a session can aggregate several documents).
    let sourceName: String
    /// Text actually extracted — IT is what tells a silent OCR from a failed
    /// interpretation.
    let rawText: String
    /// Number of items recognized in this unit (operations, orders…).
    let recognizedCount: Int
    let diagnostic: ImportUnitDiagnostic
    let kind: ImportSourceKind
    /// True if the result comes from the deterministic extraction, without AI.
    let usedDeterministicFallback: Bool
}

/// Analysis progress.
///
/// The bar is DETERMINATE only when it has something to tell, i.e. when there
/// is more than one unit to process:
///   • unknown total (0) → the document is still being read, the duration is
///     unpredictable;
///   • a single unit → the bar would jump from 0% to 100% without ever
///     moving, while the real wait (OCR + AI generation) happens INSIDE that
///     single unit.
/// In both cases an indeterminate bar is more honest.
struct DocumentAnalysisProgressSection: View {
    let done: Int
    let total: Int
    /// Waiting sentence adapted to the import type.
    var subtitle: LocalizedStringKey

    private var showsDeterminate: Bool { total > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Analyse en cours…")
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if showsDeterminate {
                ProgressView(value: Double(done), total: Double(total))
                    .tint(AppTheme.Colors.accent)
                Text("\(done) / \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(AppTheme.Colors.accent)
                Text(total == 0 ? "Lecture du document…" : "Extraction en cours…")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// PER-SOURCE detail of what the import produced, with inspection of the
/// normalized JSON.
///
/// **Why per source rather than a total:** on a multi-file import mixing
/// several formats, an aggregated total doesn't say whether ALL sources
/// contributed. A silent source appears in no imported row — by definition —
/// so only a per-file count can reveal it.
///
/// **Why the `ImportElement` JSON rather than the OCR text:** it's the only
/// form that exists for EVERY format. A CSV, a workbook or a CAMT statement
/// has no "text read" to show, yet they do produce elements.
struct ImportSourceBreakdownSection: View {
    let summaries: [ImportSourceSummary]
    /// Name of what is counted ("operation", "row").
    var noun: String = "opération"
    /// Normalized JSON of a source, on demand.
    let debugJSON: (ImportSourceSummary) -> String

    @State private var inspected: ImportSourceSummary?

    var body: some View {
        if summaries.count > 1 {
            Section {
                ForEach(summaries) { summary in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: summary.kind))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.sourceName)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(summary.summaryLabel(noun: noun))
                                .font(.caption.monospacedDigit())
                                // A source that yielded nothing is highlighted: that's the useful
                                // information.
                                .foregroundStyle(summary.isEmptyResult
                                                 ? AppTheme.Colors.warning
                                                 : AppTheme.Colors.textSecondary)
                        }
                        Spacer()
                        Button {
                            inspected = summary
                        } label: {
                            Image(systemName: "curlybraces")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .localizedAccessibilityLabel("Inspecter les données lues")
                    }
                }
            } header: {
                Text("Détail par fichier")
            } footer: {
                Text("Vérifie qu'aucun fichier n'a été laissé de côté. L'icône { } montre les données brutes lues pour ce fichier.")
            }
            .sheet(item: $inspected) { summary in
                // Re-injecting \.locale is mandatory, and so is `\.paneHostContext`: this
                // section lives in a view itself hosted in the macOS inspector
                // (`.inspector`) — without a reset to `.modal`, `ImportDebugJSONView`'s
                // `.paneChrome` would publish its buttons into the system bar instead of
                // drawing them in THIS separate window (no visible button).
                ImportDebugJSONView(title: summary.sourceName, json: debugJSON(summary))
                    .environment(\.locale, AppLocalization.locale)
                    .environment(\.paneHostContext, .modal)
            }
        }
    }

    private func icon(for kind: ImportSourceKind) -> String {
        switch kind {
        case .pdf:         return "doc.text"
        case .image:       return "photo"
        case .text:        return "tablecells"
        case .spreadsheet: return "tablecells.badge.ellipsis"
        case .xml:         return "doc.badge.gearshape"
        case .unknown:     return "questionmark.square.dashed"
        }
    }
}

/// Raw display of a source's normalized JSON.
struct ImportDebugJSONView: View {
    let title: String
    let json: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
            ScrollView([.vertical, .horizontal]) {
                Text(json)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppTheme.Colors.background.ignoresSafeArea())
            .tint(AppTheme.Colors.accent)
            // `.paneChrome` draws its own bars on a macOS sheet — the native toolbar
            // would let the user's desktop show through. See the `macSheetChrome`
            // comment in AdaptivePane.swift.
            .paneChrome(title, cancelLabel: "Fermer", onCancel: { dismiss() })
    }
}

/// Per-unit detail: why it yielded nothing, and what the app read.
///
/// Without this block, a silent OCR, an unavailable AI and a genuinely empty
/// document all give the same screen — no way to know what to fix.
struct DocumentAnalysisDiagnosticsSection: View {
    let units: [AnalysisUnit]
    @State private var expandedText: UUID?

    private var problems: [AnalysisUnit] {
        units.filter { $0.diagnostic.isFailure || $0.recognizedCount == 0 }
    }

    var body: some View {
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
}

// MARK: - Adapters from the two parsers

extension TransactionDocumentParser.UnitResult {
    var analysisUnit: AnalysisUnit {
        AnalysisUnit(id: id, unitNumber: unitNumber, sourceName: sourceName,
                     rawText: rawText, recognizedCount: transactions.count,
                     diagnostic: diagnostic, kind: kind,
                     usedDeterministicFallback: usedDeterministicFallback)
    }
}

extension PDFPageResult {
    func analysisUnit(sourceName: String) -> AnalysisUnit {
        AnalysisUnit(id: id, unitNumber: pageNumber, sourceName: sourceName,
                     rawText: rawText, recognizedCount: orders.count + positions.count,
                     diagnostic: diagnostic, kind: kind,
                     usedDeterministicFallback: usedDeterministicFallback)
    }
}
