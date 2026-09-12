import SwiftUI
import Charts
import TipKit

struct MonthNavigationView: View {
    @Bindable var vm: BudgetViewModel
    /// By default: an immediate switch, with no transition (the historical
    /// behavior). `BudgetView` overrides these to replay the SAME slide
    /// as the calendar's swipe — before, only the swipe was animated and the
    /// arrows/the "Today" button cut sharply, less smooth.
    var onPrevious: () -> Void = {}
    var onNext: () -> Void = {}
    var onToday: () -> Void = {}
    /// Tapping the month/year label — opens the quick picker. "Today"
    /// stays reachable via its own dedicated icon, separate from this tap.
    var onSelectMonthYear: () -> Void = {}

    private var cal: Calendar { .current }
    private var prevMonth: Date { cal.date(byAdding: .month, value: -1, to: vm.displayedMonth) ?? vm.displayedMonth }
    private var nextMonth: Date { cal.date(byAdding: .month, value: 1, to: vm.displayedMonth) ?? vm.displayedMonth }
    private var isCurrentMonth: Bool { cal.isDate(vm.displayedMonth, equalTo: Date(), toGranularity: .month) }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Button(action: onPrevious) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.Colors.surface, in: Circle())
            }

            Button(action: onPrevious) {
                Text(prevMonth, format: .dateTime.month(.abbreviated))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                    .frame(minWidth: 36)
            }

            Spacer()

            Button(action: onSelectMonthYear) {
                VStack(spacing: 1) {
                    Text(vm.displayedMonth, format: .dateTime.month(.wide))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(vm.displayedMonth, format: .dateTime.year())
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCurrentMonth {
                Button(action: onToday) {
                    Image(systemName: "arrow.uturn.left.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(AppTheme.Colors.accent.opacity(0.75))
                }
                .buttonStyle(.plain)
                .localizedHelp("Aujourd'hui")
                .localizedAccessibilityLabel("Aujourd'hui")
            }

            Spacer()

            Button(action: onNext) {
                Text(nextMonth, format: .dateTime.month(.abbreviated))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                    .frame(minWidth: 36)
            }

            Button(action: onNext) {
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
