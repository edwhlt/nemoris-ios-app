import SwiftUI

// `ImportDocumentSource` et `ImportDocumentReader` vivaient ici. Ils sont
// remontés dans `Features/Import/Pipeline/Readers/` : ce sont des moteurs de
// lecture, pas des vues, et la refonte leur ajoute deux formats (classeur,
// relevé structuré) qui n'ont rien à faire dans un fichier d'UI.

/// Blocs d'UI PARTAGÉS par les deux imports de documents (transactions et
/// investissements) : la barre de progression de l'analyse et le détail par
/// unité en cas d'échec.
///
/// **Pourquoi les mutualiser :** les deux imports lisent les mêmes formats
/// (PDF, capture, texte), avec le même découpage en unités et les mêmes modes
/// d'échec (`ImportUnitDiagnostic`). Laisser chaque module réinventer son écran de
/// traitement, c'est garantir qu'ils divergent — l'un a fini par afficher une
/// progression exacte avec le texte lu en cas d'échec, l'autre un simple
/// « Page X / Y » sans diagnostic.

/// Vue neutre d'une unité analysée, alimentée par l'un ou l'autre parseur.
struct AnalysisUnit: Identifiable {
    let id: UUID
    let unitNumber: Int
    /// Fichier d'origine (une session peut agréger plusieurs documents).
    let sourceName: String
    /// Texte réellement extrait — c'est LUI qui permet de distinguer un OCR
    /// muet d'une interprétation ratée.
    let rawText: String
    /// Nombre d'éléments reconnus dans cette unité (opérations, ordres…).
    let recognizedCount: Int
    let diagnostic: ImportUnitDiagnostic
    let kind: ImportSourceKind
    /// Vrai si le résultat vient de l'extraction déterministe, sans IA.
    let usedDeterministicFallback: Bool
}

/// Progression de l'analyse.
///
/// ⚠️ La barre n'est DÉTERMINÉE que si elle a quelque chose à raconter, c'est-à-dire
/// s'il y a plus d'une unité à traiter :
///   • total inconnu (0) → on lit encore le document, la durée est imprévisible ;
///   • une seule unité → la barre sauterait de 0 % à 100 % sans jamais bouger,
///     alors que l'attente réelle (OCR + génération IA) se passe DANS cette
///     unique unité.
/// Dans les deux cas une barre indéterminée est plus honnête.
struct DocumentAnalysisProgressSection: View {
    let done: Int
    let total: Int
    /// Phrase d'attente adaptée au type d'import.
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

/// Détail PAR SOURCE de ce que l'import a produit, avec inspection du JSON
/// normalisé.
///
/// **Pourquoi par source et pas un total :** sur un import multi-fichiers
/// mêlant plusieurs formats, un total agrégé ne dit pas si TOUTES les sources
/// ont contribué. Une source muette n'apparaît dans aucune ligne importée — par
/// définition — donc seul un décompte par fichier permet de la repérer.
///
/// **Pourquoi le JSON `ImportElement` et pas le texte OCR :** c'est la seule
/// forme qui existe pour TOUS les formats. Un CSV, un classeur ou un relevé
/// CAMT n'ont aucun « texte lu » à montrer, alors qu'ils produisent bien des
/// éléments — les inspecter était impossible avant.
struct ImportSourceBreakdownSection: View {
    let summaries: [ImportSourceSummary]
    /// Nom de ce qui est compté (« opération », « ligne »).
    var noun: String = "opération"
    /// JSON normalisé d'une source, à la demande.
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
                                // Une source qui n'a rien donné est mise en
                                // évidence : c'est l'information utile.
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
                // Ré-injection \.locale obligatoire (CLAUDE.md §5) et
                // `\.paneHostContext` itou : cette section vit dans une vue
                // elle-même hébergée dans l'inspecteur macOS (`.inspector`) —
                // sans reset à `.modal`, le `.paneChrome` d'`ImportDebugJSONView`
                // publierait ses boutons dans la barre système au lieu de les
                // dessiner dans CETTE fenêtre séparée (aucun bouton visible).
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

/// Affichage brut du JSON normalisé d'une source.
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
            // `.paneChrome` dessine ses propres barres sur macOS-sheet — la
            // barre d'outils native laisse le bureau de l'utilisateur
            // transparaître (retour d'usage 2026-08-21). Cf. le commentaire
            // de `macSheetChrome` dans AdaptivePane.swift.
            .paneChrome(title, cancelLabel: "Fermer", onCancel: { dismiss() })
    }
}

/// Détail par unité : pourquoi ça n'a rien donné, et ce que l'app a lu.
///
/// Sans ce bloc, un OCR muet, une IA indisponible et un document réellement
/// vide donnent le même écran — impossible de savoir quoi corriger.
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

// MARK: - Adaptateurs depuis les deux parseurs

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
