import SwiftUI

/// Reassignment sheet: lists every existing payee, filterable by search.
/// Used from `ImportSessionView` and `PayeeDetailView` for the rows/payees
/// the user wants to link to an existing payee.
struct PayeePickerSheet: View {

    let rawLabel: String
    let onPick: (Tiers) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var allPayees: [Tiers] = []
    @State private var allCategories: [Category] = []
    @State private var searchText: String = ""
    @State private var sortByRecent: Bool = false
    @State private var hasLoaded = false

    private let repository = TransactionRepository()

    var body: some View {
            VStack(spacing: 0) {
                contextHeader
                Divider()
                payeeList
            }
            #if os(macOS)
            // Without an explicit frame, a `List` nested in a VStack (as
            // opposed to a root `Form`, see nemorisFormStyle()) takes its
            // intrinsic size when the view is presented as a `.sheet` on
            // macOS — the popup then appears almost empty.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
            .paneSearchable(text: $searchText, prompt: "Rechercher dans vos tiers")
            // `.paneChrome` draws its own bars on a macOS sheet and supplies
            // its own background. The earlier attempt
            // (`.toolbarBackground(for: .windowToolbar)`) compiled but had NO
            // visual effect. See the `macSheetChrome` comment in
            // AdaptivePane.swift.
            .paneChrome("Lier à un tiers existant", cancelLabel: "Annuler", onCancel: { dismiss() })
            .task {
                await Task.yield()
                loadPayees()
                hasLoaded = true
            }
    }

    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Libellé à classer")
                .font(.caption2.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text(rawLabel)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppTheme.Colors.textSecondary.opacity(0.08))
    }

    private var filteredPayees: [Tiers] {
        let query = searchText
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return allPayees }
        return allPayees.filter {
            $0.name
                .folding(options: .diacriticInsensitive, locale: .current)
                .lowercased()
                .contains(query)
        }
    }

    private var payeeList: some View {
        Group {
            if !hasLoaded {
                List {
                    ForEach(0..<6, id: \.self) { _ in
                        SkeletonCandidateRow()
                    }
                }
                .listStyle(.plain)
                .macGroupedListTopGap()
            } else if allPayees.isEmpty {
                EmptyStateView(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "Aucun tiers existant",
                    message: "Créez d'abord un tiers depuis la liste des données de référence."
                )
            } else if filteredPayees.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Aucun résultat",
                    message: "Aucun tiers ne correspond à votre recherche."
                )
            } else {
                List(filteredPayees) { payee in
                    Button {
                        onPick(payee)
                        dismiss()
                    } label: {
                        PayeeRowSummary(payee: payee, allCategories: allCategories)
                    }
                    .buttonStyle(.plain)
                    .macGroupedRow(first: payee.id == filteredPayees.first?.id, last: payee.id == filteredPayees.last?.id)
                }
                .listStyle(.plain)
                .macGroupedListTopGap()
            }
        }
        #if os(macOS)
        // A `List` with no explicit ideal height, nested in a VStack (so
        // not the root of a NavigationStack), is given a near-zero ideal
        // height by AppKit — even with a `maxHeight: .infinity` upstream on
        // the container, that only forces the upper bound, not the starting
        // size. Hence invisible rows despite a correctly sized popup.
        .frame(minHeight: 320, maxHeight: .infinity)
        // On macOS, `List` paints ITS OWN system background OVER the
        // `.background()` set on the parent VStack — without this modifier
        // (propagated to both Lists in the Group above), the app's
        // background is invisible and the user's desktop shows through. See
        // `TagSummaryView`.
        .scrollContentBackground(.hidden)
        #endif
    }

    private func loadPayees() {
        allPayees = repository.fetchTiers()
        allCategories = repository.fetchCategories()
    }
}

private struct PayeeRowSummary: View {
    let payee: Tiers
    let allCategories: [Category]

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            MerchantLogo(tiers: payee, allCategories: allCategories, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(payee.name).font(.body)
                if let regex = payee.regex, !regex.isEmpty {
                    Text(regex)
                        .font(.caption2.monospaced())
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
        }
        .padding(.vertical, 4)
    }
}
