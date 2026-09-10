import SwiftUI
import Charts
import TipKit

struct BudgetApercuSheet: View {
    let summary: MonthlyBudgetSummary?
    let days: [CalendarDay]
    let month: Date
    let categories: [Category]
    let allTiers: [Tiers]
    let allCategories: [Category]
    @Environment(\.paneDismiss) private var paneDismiss
    @Environment(AppState.self) private var appState

    @State private var selectedCategoryName: String? = nil
    @State private var showCategoryTxSheet: Bool = false
    private let envelopeTip = BudgetEnvelopeTip()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppTheme.Spacing.md) {
                    if let s = summary {
                        AppCard {
                            VStack(spacing: AppTheme.Spacing.sm) {
                                SectionHeader(title: "Aperçu budgétaire")
                                apercuContent(s)
                            }
                        }
                        .padding(.horizontal, AppTheme.Spacing.md)

                        if !s.envelopes.isEmpty {
                            TipView(envelopeTip, arrowEdge: .none)
                                .padding(.horizontal, AppTheme.Spacing.md)
                            AppCard {
                                VStack(spacing: AppTheme.Spacing.sm) {
                                    SectionHeader(title: "Enveloppes")
                                    ForEach(s.envelopes) { env in
                                        Button {
                                            selectedCategoryName = env.categoryName
                                            showCategoryTxSheet = true
                                        } label: {
                                            HStack(spacing: AppTheme.Spacing.sm) {
                                                EnvelopeProgressRow(progress: env)
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 12, weight: .semibold))
                                                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                                            }
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(.horizontal, AppTheme.Spacing.md)
                        }
                    }

                    if !days.isEmpty {
                        MonthProjectionCard(days: days)
                            .padding(.horizontal, AppTheme.Spacing.md)

                        AppCard {
                            VStack(spacing: AppTheme.Spacing.sm) {
                                SectionHeader(title: "Dépenses par catégorie")
                                CategoryExpensePieChart(days: days, selectedCategory: $selectedCategoryName)
                                if selectedCategoryName != nil {
                                    Button {
                                        showCategoryTxSheet = true
                                    } label: {
                                        Label("Voir les transactions", systemImage: "list.bullet")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.horizontal, AppTheme.Spacing.md)

                        AppCard {
                            VStack(spacing: AppTheme.Spacing.sm) {
                                SectionHeader(title: "Flux budgétaire")
                                Text("Revenus → Dépenses par catégorie")
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                MoneyFlowSankeyView(days: days)
                            }
                        }
                        .padding(.horizontal, AppTheme.Spacing.md)
                    }

                    Spacer(minLength: AppTheme.Spacing.xl)
                }
                .padding(.top, AppTheme.Spacing.md)
            }
            .background(AppTheme.Colors.background)
            .paneChromeInline(month.formatted(.dateTime.month(.wide).year().locale(appState.locale)).capitalized,
                               cancelLabel: "Fermer", onCancel: { paneDismiss() })
            // #8 macOS : une .sheet imbriquée dans une vue elle-même présentée
            // en .sheet s'affiche VIDE sur Mac. On pousse la liste dans la
            // NavigationStack existante via navigationDestination (comportement
        }
        // Niveau 2 (adaptivePane depuis un contenu déjà dans le panneau macOS
        // → sheet, cf. paneHostContext). Un push (navigationDestination) ferait
        // remonter son titre/back-button dans la barre du MODULE (le panneau
        // n'a pas de fenêtre séparée pour l'absorber) — la sheet, elle, est sa
        // propre fenêtre sur macOS et reste scopée correctement.
        .adaptivePane(isPresented: $showCategoryTxSheet) {
            List(filteredTransactionsForSelectedCategory()) { tx in
                HStack(spacing: 10) {
                    MerchantLogo(transaction: tx, allTiers: allTiers, allCategories: allCategories, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tx.tiersName.isEmpty ? tx.information : tx.tiersName)
                            .font(.subheadline)
                        if !tx.information.isEmpty && !tx.tiersName.isEmpty {
                            Text(tx.information).font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(tx.amount, format: .currency(code: "EUR"))
                            .font(.subheadline).bold()
                            .foregroundStyle(tx.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        Text(tx.date, format: .dateTime.day().month(.abbreviated))
                            .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
            #if os(macOS)
            // `List` peint SON PROPRE fond système sur macOS PAR-DESSUS
            // celui du panneau hôte — sans ce modificateur, le bureau de
            // l'utilisateur transparaît (retour d'usage 2026-08-19).
            .scrollContentBackground(.hidden)
            #endif
            .paneChrome(selectedCategoryName ?? "Transactions",
                        cancelLabel: "Fermer", onCancel: { showCategoryTxSheet = false })
        }
    }

    @ViewBuilder
    private func apercuContent(_ s: MonthlyBudgetSummary) -> some View {
        HStack {
            statBox(title: "Prévu", value: s.forecastedExpenses, color: AppTheme.Colors.accent)
            Divider().frame(height: 40)
            statBox(title: "Réel", value: s.actualExpenses,
                    color: s.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.success)
            Divider().frame(height: 40)
            let v = s.variance
            statBox(title: v >= 0 ? "Écart" : "Économie", value: abs(v),
                    color: v > 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
        }
        .frame(maxWidth: .infinity)

        let ratio = s.forecastedExpenses > 0
            ? min(s.actualExpenses / s.forecastedExpenses, 1.5) : 0
        BudgetRatioBar(ratio: ratio, forecastedExpenses: s.forecastedExpenses, actualExpenses: s.actualExpenses)

        HStack {
            Text("\(s.matchedCount) confirmés")
                .font(AppTheme.Typography.labelMedium).foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Text("\(s.pendingCount) en attente")
                .font(AppTheme.Typography.labelMedium).foregroundStyle(AppTheme.Colors.textSecondary)
        }

        if s.fixedActual > 0 || s.totalIncome > 0 {
            Rectangle()
                .fill(AppTheme.Colors.surfaceSecondary)
                .frame(height: 1)
            SavingsBreakdownRow(summary: s)
        }
    }

    private func statBox(title: LocalizedStringKey, value: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value, format: .currency(code: "EUR"))
                .font(AppTheme.Typography.moneySmall).foregroundStyle(color)
            Text(title)
                .font(AppTheme.Typography.labelSmall).foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func filteredTransactionsForSelectedCategory() -> [FinanceTransaction] {
        guard let sel = selectedCategoryName else { return [] }
        let cal = Calendar.current
        let monthComponents = cal.dateComponents([.year, .month], from: month)

        // Build hierarchical set of category IDs (parent + children)
        let matchingIds: Set<Int>
        if let cat = categories.first(where: { $0.name == sel }) {
            let childIds = categories.filter { $0.parentId == cat.id }.map { $0.id }
            matchingIds = Set([cat.id] + childIds)
        } else {
            matchingIds = Set()
        }

        return days
            .flatMap { $0.transactions }
            .filter { tx in
                let comps = cal.dateComponents([.year, .month], from: tx.date)
                guard comps.year == monthComponents.year && comps.month == monthComponents.month else { return false }
                if !matchingIds.isEmpty, let catId = tx.categoryId {
                    return matchingIds.contains(catId)
                }
                // Fallback: name-based match (for "Autre" or unknown categories)
                let catName = tx.categoryName.isEmpty ? "Autre" : tx.categoryName
                return catName == sel
            }
            .sorted { $0.date > $1.date }
    }
}
