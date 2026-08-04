import SwiftUI
import Charts
import TipKit

struct EnvelopeProgressRow: View {
    let progress: EnvelopeProgress

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill((progress.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.accent).opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: progress.categoryIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(progress.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.accent)
                }
                Text(progress.categoryName)
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Spacer()
                Text("\(progress.spent, format: .currency(code: "EUR")) / \(progress.allocated, format: .currency(code: "EUR"))")
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(progress.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.textSecondary)
            }
            // Barre segmentée : gris = fixes confirmés, accent = variables, fantôme = prévu restant
            GeometryReader { geo in
                let totalW = geo.size.width
                let recurW = totalW * progress.recurringRatio
                let varW   = totalW * min(max(progress.ratio - progress.recurringRatio, 0),
                                          1.0 - progress.recurringRatio)
                let spentW = recurW + varW
                let forecastW = min(totalW * progress.forecastedRatio, totalW)
                let ghostW = max(forecastW - spentW, 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.Colors.surfaceSecondary).frame(height: 8)
                    HStack(spacing: 0) {
                        if recurW > 0 {
                            Rectangle()
                                .fill(AppTheme.Colors.textSecondary.opacity(0.45))
                                .frame(width: recurW, height: 8)
                        }
                        if varW > 0 {
                            Rectangle()
                                .fill(progress.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.accent)
                                .frame(width: varW, height: 8)
                        }
                        if ghostW > 0 {
                            Rectangle()
                                .fill(AppTheme.Colors.accent.opacity(0.2))
                                .frame(width: ghostW, height: 8)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(width: totalW, height: 8)
                    .clipShape(Capsule())
                }
            }
            .frame(height: 8)
            HStack {
                if progress.isOverBudget {
                    Label("Dépassé de \(progress.spent - progress.allocated, format: .currency(code: "EUR"))",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(AppTheme.Typography.labelSmall).foregroundStyle(AppTheme.Colors.danger)
                } else {
                    Text("Reste \(progress.remaining, format: .currency(code: "EUR"))")
                        .font(AppTheme.Typography.labelSmall).foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Spacer()
                if progress.forecasted > 0 {
                    HStack(spacing: 3) {
                        if progress.forecastExceedsBudget {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(AppTheme.Colors.warning)
                        } else {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(AppTheme.Colors.accent.opacity(0.5))
                                .frame(width: 2, height: 9)
                        }
                        Text("\(progress.forecasted, format: .currency(code: "EUR").precision(.fractionLength(0))) prévus")
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(progress.forecastExceedsBudget
                                ? AppTheme.Colors.warning
                                : AppTheme.Colors.textSecondary.opacity(0.7))
                    }
                } else if progress.recurringSpent > 0 {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(AppTheme.Colors.textSecondary.opacity(0.45))
                            .frame(width: 5, height: 5)
                        Text("\(progress.recurringSpent, format: .currency(code: "EUR")) fixes")
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                    }
                } else {
                    Text("\(Int((progress.ratio * 100).rounded())) %")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(progress.isOverBudget ? AppTheme.Colors.danger : AppTheme.Colors.textSecondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
