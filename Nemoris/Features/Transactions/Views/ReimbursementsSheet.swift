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
    /// Groupement TOUJOURS par payee — ce toggle ne fait que sous-détailler les
    /// items D'UN MÊME payee par catégorie, il ne remplace pas le groupement.
    @State private var detailByCategory = false
    /// Disclosure des sous-groupes catégorie, repliés par défaut. Clé composite
    /// "payeeId|categoryId" : un même categoryId peut apparaître sous plusieurs
    /// payees (ex. "Alimentation" chez Papa ET chez Maman) — un Set<Int> seul
    /// ferait coïncider à tort leurs états d'expansion.
    @State private var expandedCategoryKeys: Set<String> = []

    init(repository: TransactionRepository, initialFrom: Date, initialTo: Date) {
        self.repository = repository
        _fromDate = State(initialValue: initialFrom)
        _toDate   = State(initialValue: initialTo)
    }

    private var isEmpty: Bool { groups.isEmpty }
    private var grandTotal: Double { groups.reduce(0) { $0 + $1.total } }

    var body: some View {
            // Form (pas List) : contenu type formulaire → boxes arrondies
            // natives macOS via nemorisFormStyle(), insetGrouped natif sur iOS.
            Form {
                // Période
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
                        ContentUnavailableView(
                            "Aucun remboursement",
                            systemImage: "arrow.uturn.left.circle",
                            description: Text("Aucune transaction avec remboursement sur cette période.")
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

                    // Liste unifiée — toujours groupée par payee
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

    // MARK: En-tête de groupe (tappable pour expand)

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

    // MARK: Sous-titre du groupe

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

    // MARK: Sous-détail par catégorie (au sein d'un même payee)

    /// Découpe les items d'UN payee par catégorie — calculé en mémoire à partir
    /// des données déjà chargées (categoryId/categoryName portés par
    /// Reimbursement), pas de requête supplémentaire. Tri par montant absolu
    /// décroissant : la catégorie la plus lourde en premier.
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

    /// Clé composite payee+catégorie pour l'état d'expansion — cf. commentaire
    /// sur `expandedCategoryKeys`.
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

    /// Repli : la note libre (`information`) est souvent vide (transactions
    /// importées, jamais annotées par l'user) → repli sur le payee ORIGINAL de
    /// la transaction (ex. "Netflix"), pas sur un libellé générique.
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
                Text(item.originDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if item.needsConversion {
                    Text(item.amount.formatted(.currency(code: item.currency)))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.Colors.warning)
                    Text("non converti")
                        .font(.caption2).foregroundStyle(AppTheme.Colors.warning)
                } else {
                    Text(item.effectiveEurAmount.formatted(.currency(code: "EUR")))
                        .font(.subheadline)
                        .foregroundStyle(item.effectiveEurAmount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    if item.isConverted {
                        Text(item.amount.formatted(.currency(code: item.currency)))
                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .padding(.leading, 12)
    }

    // MARK: Chargement

    private func load() {
        groups = reimbursementRepo.fetchReimbursementGroups(from: fromDate, to: toDate)
    }
}
