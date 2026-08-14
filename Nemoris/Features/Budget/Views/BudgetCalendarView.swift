import SwiftUI

// MARK: - DayCell

struct DayCell: View {
    let day: CalendarDay
    let isToday: Bool
    let isSelected: Bool

    private var hasTransaction: Bool { !day.transactions.isEmpty }
    private var hasPrevision: Bool { !day.previsions.isEmpty }

    private var txDotColor: Color {
        guard day.actualAmount != 0 else { return AppTheme.Colors.success }
        return day.actualAmount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if isToday {
                    Circle()
                        .fill(AppTheme.Colors.accent)
                        .frame(width: 32, height: 32)
                } else if isSelected {
                    Circle()
                        .fill(AppTheme.Colors.accent.opacity(0.15))
                        .frame(width: 32, height: 32)
                }
                Text(dayNumber)
                    .font(.system(size: 14, weight: isToday ? .semibold : .regular))
                    .foregroundStyle(
                        isToday ? Color.white :
                        isSelected ? AppTheme.Colors.accent :
                        AppTheme.Colors.textPrimary
                    )
            }

            // Event indicator dots
            HStack(spacing: 3) {
                if hasTransaction {
                    Circle()
                        .fill(txDotColor)
                        .frame(width: 5, height: 5)
                }
                if hasPrevision {
                    Circle()
                        .fill(AppTheme.Colors.warning.opacity(hasTransaction ? 0.7 : 1))
                        .frame(width: 5, height: 5)
                }
                if !hasTransaction && !hasPrevision {
                    Color.clear.frame(width: 5, height: 5)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 54)
    }

    private var dayNumber: String {
        String(Calendar.current.component(.day, from: day.date))
    }
}

// MARK: - DayDetailPanel

struct DayDetailPanel: View {
    let day: CalendarDay
    @Bindable var vm: BudgetViewModel
    var allTiers: [Tiers] = []
    var allCategories: [Category] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.date, format: .dateTime.weekday(.wide))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .textCase(.uppercase)
                    Text(day.date, format: .dateTime.day().month(.wide).year())
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                Spacer()
                if day.actualAmount != 0 {
                    Text(day.actualAmount, format: .currency(code: "EUR"))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(day.actualAmount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                }
            }
            .padding(AppTheme.Spacing.lg)

            if !day.previsions.isEmpty {
                Divider().background(AppTheme.Colors.surfaceSecondary)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Label("Prévisions", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .textCase(.uppercase)
                        .padding(.bottom, 2)

                    ForEach(day.previsions) { ep in
                        HStack(spacing: AppTheme.Spacing.sm) {
                            Circle()
                                .fill(ep.status == .matched ? AppTheme.Colors.success : AppTheme.Colors.warning)
                                .frame(width: 7, height: 7)
                            Text(ep.patternName)
                                .font(AppTheme.Typography.bodySmall)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(ep.displayAmount, format: .currency(code: "EUR"))
                                .font(AppTheme.Typography.bodySmall)
                                .fontWeight(.semibold)
                                .foregroundStyle(ep.isExpense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                            // Bouton skip inline sur .pending (calendrier)
                            if ep.status == .pending {
                                Button {
                                    vm.skipPrevision(ep.prevision)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Ignorer cette échéance")
                            }
                        }
                        .contextMenu {
                            if ep.status == .pending {
                                Button(role: .destructive) {
                                    vm.skipPrevision(ep.prevision)
                                } label: {
                                    Label("Ignorer", systemImage: "xmark")
                                }
                            }
                        }
                    }
                }
                .padding(AppTheme.Spacing.lg)
            }

            if !day.transactions.isEmpty {
                Divider().background(AppTheme.Colors.surfaceSecondary)
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Label("Transactions", systemImage: "creditcard")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .textCase(.uppercase)
                        .padding(.bottom, 2)

                    ForEach(day.transactions) { tx in
                        HStack(spacing: AppTheme.Spacing.sm) {
                            MerchantLogo(transaction: tx, allTiers: allTiers, allCategories: allCategories, size: 24)
                            Text(tx.tiersName.isEmpty ? tx.information : tx.tiersName)
                                .font(AppTheme.Typography.bodySmall)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(tx.amount, format: .currency(code: "EUR"))
                                .font(AppTheme.Typography.bodySmall)
                                .fontWeight(.semibold)
                                .foregroundStyle(tx.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                    }
                }
                .padding(AppTheme.Spacing.lg)
            }
        }
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Colors.surfaceSecondary, lineWidth: 1)
        )
    }
}

// MARK: - MonthProjectionCard

struct MonthProjectionCard: View {
    @Environment(AppState.self) private var appState

    let days: [CalendarDay]

    private var totalForecasted: Double { days.reduce(0) { $0 + $1.forecastedAmount } }
    private var totalExpenses: Double {
        days.reduce(0) { total, d in
            total + d.transactions.filter { $0.amount < 0 }.reduce(0) { $0 + $1.amount }
        }
    }
    private var totalIncome: Double {
        days.reduce(0) { total, d in
            total + d.transactions.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        }
    }

    var body: some View {
        AppCard {
            VStack(spacing: AppTheme.Spacing.sm) {
                SectionHeader(title: "Résumé du mois")
                HStack(spacing: AppTheme.Spacing.xs) {
                    StatBadge(
                        label: "Prévisions",
                        value: totalForecasted.formatted(.currency(code: "EUR").precision(.fractionLength(0)).locale(appState.locale)),
                        valueColor: AppTheme.Colors.warning
                    )
                    Divider().frame(height: 36)
                    StatBadge(
                        label: "Dépenses",
                        value: totalExpenses.formatted(.currency(code: "EUR").precision(.fractionLength(0)).locale(appState.locale)),
                        valueColor: AppTheme.Colors.danger
                    )
                    Divider().frame(height: 36)
                    StatBadge(
                        label: "Revenus",
                        value: totalIncome.formatted(.currency(code: "EUR").precision(.fractionLength(0)).locale(appState.locale)),
                        valueColor: AppTheme.Colors.success
                    )
                }
            }
        }
    }
}

// MARK: - TransactionRepository convenience

extension TransactionRepository {
    func fetchAllTransactions(accountId: Int, from: Date, to: Date) -> [FinanceTransaction] {
        var all: [FinanceTransaction] = []
        var offset = 0
        let pageSize = 500
        while true {
            let page = fetchTransactions(accountId: accountId, from: from, to: to,
                                         limit: pageSize, offset: offset)
            all.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }
        return all
    }

    func fetchAllAccountsTransactions(from: Date, to: Date) -> [FinanceTransaction] {
        var all: [FinanceTransaction] = []
        var offset = 0
        let pageSize = 500
        while true {
            let page = fetchTransactionsAllAccounts(from: from, to: to,
                                                    limit: pageSize, offset: offset)
            all.append(contentsOf: page)
            if page.count < pageSize { break }
            offset += pageSize
        }
        return all
    }
}
