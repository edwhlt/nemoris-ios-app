import SwiftUI
import Charts
import TipKit

struct MonthNavigationView: View {
    @Bindable var vm: BudgetViewModel

    private var cal: Calendar { .current }
    private var prevMonth: Date { cal.date(byAdding: .month, value: -1, to: vm.displayedMonth) ?? vm.displayedMonth }
    private var nextMonth: Date { cal.date(byAdding: .month, value: 1, to: vm.displayedMonth) ?? vm.displayedMonth }
    private var isCurrentMonth: Bool { cal.isDate(vm.displayedMonth, equalTo: Date(), toGranularity: .month) }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button { vm.previousMonth() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.Colors.surface, in: Circle())
            }

            Button { vm.previousMonth() } label: {
                Text(prevMonth, format: .dateTime.month(.abbreviated))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                    .frame(minWidth: 36)
            }

            Spacer()

            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text(vm.displayedMonth, format: .dateTime.month(.wide))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if !isCurrentMonth {
                        Image(systemName: "arrow.uturn.left.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.Colors.accent.opacity(0.75))
                    }
                }
                Text(vm.displayedMonth, format: .dateTime.year())
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !isCurrentMonth { vm.goToCurrentMonth() } }

            Spacer()

            Button { vm.nextMonth() } label: {
                Text(nextMonth, format: .dateTime.month(.abbreviated))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                    .frame(minWidth: 36)
            }

            Button { vm.nextMonth() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.Colors.surface, in: Circle())
            }
        }
        .buttonStyle(.borderless)
        .animation(AppTheme.Animations.springSnappy, value: vm.displayedMonth)
    }
}
