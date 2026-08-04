import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TagSummaryView: View {
    @Environment(\.paneDismiss) private var paneDismiss
    let repository: TransactionRepository
    @State private var summaries: [TagExpenseSummary] = []
    @State private var isSyncingRates = false
    /// État à la place d'un `NavigationLink` : un push depuis ce contenu, une
    /// fois hébergé dans le panneau macOS, ferait remonter le titre/back-button
    /// de `TagDetailView` dans la barre du MODULE (aucune fenêtre séparée pour
    /// l'absorber). Le détail s'ouvre en sheet (niveau 2, scopée) à la place.
    @State private var selectedTag: Tag?

    var body: some View {
            Group {
                if summaries.isEmpty && !isSyncingRates {
                    ContentUnavailableView(
                        "Aucun tag utilisé",
                        systemImage: "tag.slash",
                        description: Text("Assignez des tags à vos transactions ou dépenses Tricount.")
                    )
                } else {
                    List {
                        if isSyncingRates {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("Récupération des taux de change…")
                                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            .listRowSeparator(.hidden)
                        }
                        ForEach(summaries) { summary in
                            Button {
                                selectedTag = summary.tag
                            } label: {
                                HStack {
                                    tagSummaryRow(summary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .onAppear {
                summaries = repository.fetchTagExpenseSummary()
                Task {
                    isSyncingRates = true
                    await CurrencyRateService.syncAllGroups()
                    summaries = repository.fetchTagExpenseSummary()
                    isSyncingRates = false
                }
            }
            .adaptivePane(item: $selectedTag) { tag in
                TagDetailView(tag: tag, repository: repository)
                    .paneChrome(tag.name, cancelLabel: "Fermer", onCancel: { selectedTag = nil })
            }
            .paneChrome("Dépenses par tag", cancelLabel: "Fermer", onCancel: { paneDismiss() })
    }

    @ViewBuilder
    private func tagSummaryRow(_ summary: TagExpenseSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tag.fill")
                .foregroundStyle(summary.tag.displayColor)
                .font(.subheadline)
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.tag.name).font(.headline)
                HStack(spacing: 8) {
                    if summary.transactionTotal != 0 {
                        Label(summary.transactionTotal.formatted(.currency(code: "EUR")), systemImage: "creditcard")
                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    if summary.tricountTotal != 0 {
                        Label(summary.tricountTotal.formatted(.currency(code: "EUR")), systemImage: "person.2")
                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
            Spacer()
            Text(summary.total.formatted(.currency(code: "EUR")))
                .fontWeight(.semibold)
                .foregroundStyle(summary.total < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
        }
        .padding(.vertical, 2)
    }
}
