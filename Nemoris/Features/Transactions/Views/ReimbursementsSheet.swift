import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct ReimbursementsSheet: View {
    @Environment(\.paneDismiss) private var paneDismiss
    let repository: TransactionRepository
    private let reimbursementRepo = ReimbursementRepository()

    @State private var fromDate: Date
    @State private var toDate: Date
    @State private var groups: [ReimbursementGroup] = []
    @State private var expandedIds: Set<Int> = []
    /// ALWAYS grouped by payee — this toggle only sub-details a
    /// single payee's items by category, it doesn't replace the grouping.
    @State private var detailByCategory = false
    /// Disclosure of category sub-groups, collapsed by default. A composite key
    /// "payeeId|categoryId": the same categoryId can appear under several
    /// payees (e.g. "Groceries" for both Mom AND Dad) — a plain Set<Int>
    /// would wrongly conflate their expansion states.
    @State private var expandedCategoryKeys: Set<String> = []

    init(repository: TransactionRepository, initialFrom: Date, initialTo: Date) {
        self.repository = repository
        _fromDate = State(initialValue: initialFrom)
        _toDate   = State(initialValue: initialTo)
    }

    private var isEmpty: Bool { groups.isEmpty }
    private var grandTotal: Double { groups.reduce(0) { $0 + $1.total } }

    var body: some View {
            // A Form (not List): form-like content → native rounded macOS
            // boxes via nemorisFormStyle(), native insetGrouped on iOS.
            Form {
                // Period
                Section("Période") {
                    DatePicker("Du", selection: $fromDate, displayedComponents: .date)
                    DatePicker("Au", selection: $toDate, displayedComponents: .date)
                    Button("Appliquer") { load() }
                        .frame(maxWidth: .infinity)
                }

                if !isEmpty {
                    Section {
                        Toggle("Détailler par catégorie", isOn: $detailByCategory)
                    }
                }

                if isEmpty {
                    Section {
                        EmptyStateView(
                            icon: "arrow.uturn.left.circle",
                            title: "Aucun remboursement",
                            message: "Aucune transaction avec remboursement sur cette période."
                        )
                    }
                } else {
                    // Total global
                    Section {
                        HStack {
                            Text("Total à recevoir").fontWeight(.semibold)
                            Spacer()
                            Text(grandTotal, format: .currency(code: "EUR"))
                                .fontWeight(.bold)
                                .foregroundStyle(grandTotal < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                    }

                    // A unified list — always grouped by payee
                    ForEach(groups) { group in
                        Section {
                            groupHeader(id: group.id, title: group.payeeName, total: group.total,
                                        transactionCount: group.transactionCount, tricountCount: group.tricountCount)
                            if expandedIds.contains(group.id) {
                                if detailByCategory {
                                    ForEach(categorySubgroups(of: group.items)) { sub in
                                        let key = categoryKey(payeeId: group.id, sub: sub)
                                        categorySubheader(sub, isExpanded: expandedCategoryKeys.contains(key)) {
                                            if expandedCategoryKeys.contains(key) { expandedCategoryKeys.remove(key) }
                                            else { expandedCategoryKeys.insert(key) }
                                        }
                                        if expandedCategoryKeys.contains(key) {
                                            ForEach(sub.items) { item in itemRow(item) }
                                        }
                                    }
                                } else {
                                    ForEach(group.items) { item in itemRow(item) }
                                }
                            }
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .onAppear { load() }
            .paneChrome("Remboursements", cancelLabel: "Fermer", onCancel: { paneDismiss() })
    }

    // MARK: Group header (tappable to expand)

    @ViewBuilder
    private func groupHeader(id: Int, title: String, total: Double, transactionCount: Int, tricountCount: Int) -> some View {
        Button {
            if expandedIds.contains(id) { expandedIds.remove(id) }
            else { expandedIds.insert(id) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(AppTheme.Colors.textPrimary)
                    groupSubtitle(transactionCount: transactionCount, tricountCount: tricountCount)
                }
                Spacer()
                Text(total, format: .currency(code: "EUR"))
                    .fontWeight(.semibold)
                    .foregroundStyle(total < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                Image(systemName: expandedIds.contains(id) ? "chevron.up" : "chevron.down")
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Group subtitle

    @ViewBuilder
    private func groupSubtitle(transactionCount: Int, tricountCount: Int) -> some View {
        if transactionCount > 0 && tricountCount > 0 {
            HStack(spacing: 4) {
                Text("\(transactionCount) transaction(s)").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                Text("·").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                HStack(spacing: 3) {
                    Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(AppTheme.Colors.accentSecondary)
                    Text("\(tricountCount) Tricount").font(.caption).foregroundStyle(AppTheme.Colors.accentSecondary)
                }
            }
        } else if tricountCount > 0 {
            HStack(spacing: 3) {
                Image(systemName: "person.2.fill").font(.caption2).foregroundStyle(AppTheme.Colors.accentSecondary)
                Text("\(tricountCount) dépense(s) Tricount").font(.caption).foregroundStyle(AppTheme.Colors.accentSecondary)
            }
        } else {
            Text("\(transactionCount) transaction(s)").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
        }
    }

    // MARK: Category sub-detail (within a single payee)

    /// Splits ONE payee's items by category — computed in memory from
    /// the already-loaded data (categoryId/categoryName carried by
    /// Reimbursement), no extra query. Sorted by decreasing absolute amount:
    /// the heaviest category first.
    private func categorySubgroups(of items: [Reimbursement]) -> [CategoryReimbursementGroup] {
        var grouped: [Int: (name: String, items: [Reimbursement])] = [:]
        for item in items {
            let key = item.categoryId ?? -1
            let name = item.categoryId == nil ? "Non catégorisé" : item.categoryName
            grouped[key, default: (name, [])].items.append(item)
        }
        return grouped.map { id, pair in
            CategoryReimbursementGroup(categoryId: id == -1 ? nil : id, categoryName: pair.name, items: pair.items)
        }.sorted { abs($0.total) > abs($1.total) }
    }

    /// A composite payee+category key for the expansion state — see the comment
    /// on `expandedCategoryKeys`.
    private func categoryKey(payeeId: Int, sub: CategoryReimbursementGroup) -> String {
        "\(payeeId)|\(sub.id)"
    }

    private func categorySubheader(_ sub: CategoryReimbursementGroup, isExpanded: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                Text(sub.categoryName).font(.subheadline).fontWeight(.semibold).foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Text(sub.total, format: .currency(code: "EUR"))
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: Ligne item

    /// Fallback: the free-form note (`information`) is often empty (imported
    /// transactions, never annotated by the user) → falls back to the transaction's
    /// ORIGINAL payee (e.g. "Netflix"), not a generic label.
    private func displayLabel(_ item: Reimbursement) -> String {
        if !item.originDescription.isEmpty { return item.originDescription }
        if !item.originPayeeName.isEmpty { return item.originPayeeName }
        return item.isTricountOrigin ? "Tricount" : "Transaction"
    }

    @ViewBuilder
    private func itemRow(_ item: Reimbursement) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(displayLabel(item)).font(.subheadline)
                    if item.isTricountOrigin {
                        HStack(spacing: 3) {
                            Image(systemName: "person.2.fill").font(.caption2)
                            Text("Tricount").font(.caption2).fontWeight(.semibold)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.Colors.accentSecondary.opacity(0.13), in: Capsule())
                        .foregroundStyle(AppTheme.Colors.accentSecondary)
                    }
                }
                Text(item.originDate, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if item.needsConversion {
                    Text(item.amount, format: .currency(code: item.currency))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.warning)
                    Text("non converti")
                        .font(.caption2).foregroundStyle(AppTheme.Colors.warning)
                } else {
                    Text(item.effectiveEurAmount, format: .currency(code: "EUR"))
                        .font(.subheadline)
                        .foregroundStyle(item.effectiveEurAmount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    if item.isConverted {
                        Text(item.amount, format: .currency(code: item.currency))
                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .padding(.leading, 12)
    }

    // MARK: Loading

    private func load() {
        groups = reimbursementRepo.fetchReimbursementGroups(from: fromDate, to: toDate)
    }
}
