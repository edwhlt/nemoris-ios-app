import SwiftUI

// MARK: - InsightsCoachSection
//
// The "Coach" section shown in the Dashboard. Shows the **top 3**
// insights by `compositeScore`. Tapping an insight opens a detail sheet
// with the full `detail` + action buttons (Seen / Not for me).
//
// **Dismissal persistence**: "Not for me" insights are stored
// in UserDefaults by `id` — they aren't suggested again for 90 days (beyond
// that, the user may have changed their mind or conditions may have changed).

struct InsightsCoachSection: View {
    let insights: [Insight]
    /// `false` when the section is rendered inside a `DashboardTile`, which already
    /// carries the title — otherwise we'd stack two headers.
    var showsHeader: Bool = true
    @State private var selectedInsight: Insight? = nil

    /// The top 3 non-dismissed insights.
    private var topInsights: [Insight] {
        let dismissed = InsightDismissalStore.shared.activeDismissals()
        return insights
            .filter { !dismissed.contains($0.id) }
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        if !topInsights.isEmpty {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if showsHeader {
                    HStack(alignment: .firstTextBaseline) {
                        Text("COACH FINANCIER")
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Spacer()
                        Text("Top \(topInsights.count)")
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                VStack(spacing: AppTheme.Spacing.sm) {
                    ForEach(topInsights) { insight in
                        InsightCard(insight: insight)
                            .onTapGesture {
                                selectedInsight = insight
                                HapticService.shared.tap()
                            }
                    }
                }
            }
            .adaptivePane(item: $selectedInsight) { insight in
                InsightDetailSheet(insight: insight)
            }
        }
    }
}

// MARK: - Card

struct InsightCard: View {
    let insight: Insight

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: insight.kind.systemIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 40, height: 40)
                .background(AppTheme.Colors.accent.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(insight.kind.label))
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Text(insight.title)
                    .font(AppTheme.Typography.titleSmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(2)
                if insight.isActionable && insight.annualImpact > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                        MoneyText(
                            amount: insight.annualImpact,
                            font: AppTheme.Typography.labelLarge,
                            color: AppTheme.Colors.success
                        )
                        Text("/an potentiels")
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.success.opacity(0.85))
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }
}

// MARK: - Detail sheet

struct InsightDetailSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let insight: Insight

    var body: some View {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    // Header — icon + kind label
                    HStack(spacing: AppTheme.Spacing.md) {
                        Image(systemName: insight.kind.systemIcon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.accent)
                            .frame(width: 56, height: 56)
                            .background(AppTheme.Colors.accent.opacity(0.13), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(insight.kind.label))
                                .textCase(.uppercase)
                                .font(.system(size: 11, weight: .semibold))
                                .tracking(0.6)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                            Text(insight.title)
                                .font(AppTheme.Typography.titleLarge)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                        }
                    }
                    Text(insight.detail)
                        .font(AppTheme.Typography.bodyMedium)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    // KPIs (potential gain, feasibility, confidence)
                    if insight.isActionable {
                        HStack(spacing: AppTheme.Spacing.lg) {
                            kpi(label: "Impact / an", value: insight.annualImpact.formatted(.currency(code: "EUR").presentation(.narrow).locale(appState.locale)), color: AppTheme.Colors.success)
                            kpi(label: "Faisabilité", value: "\(insight.actionability)/5", color: AppTheme.Colors.accent)
                            kpi(label: "Confiance", value: "\(Int(insight.confidence * 100)) %", color: AppTheme.Colors.textSecondary)
                        }
                    }

                    Spacer()

                    // Actions
                    HStack(spacing: AppTheme.Spacing.md) {
                        Button {
                            HapticService.shared.success()
                            appState.postToast(.success, "Marqué comme vu")
                            dismiss()
                        } label: {
                            Label("Vu", systemImage: "checkmark")
                                .font(AppTheme.Typography.titleSmall)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppTheme.Spacing.md)
                                .foregroundStyle(.white)
                                .background(AppTheme.Colors.accent)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                        }
                        .buttonStyle(.plain)

                        Button {
                            InsightDismissalStore.shared.dismiss(insight.id)
                            HapticService.shared.tap()
                            appState.postToast(.info, "Masqué pendant 90 jours")
                            dismiss()
                        } label: {
                            Label("Pas pour moi", systemImage: "xmark")
                                .font(AppTheme.Typography.titleSmall)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppTheme.Spacing.md)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .background(AppTheme.Colors.surfaceSecondary)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(AppTheme.Spacing.xl)
            }
            .paneChrome("Détail", cancelLabel: "Fermer", onCancel: { dismiss() })
    }

    @ViewBuilder
    private func kpi(label: LocalizedStringKey, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Text(value)
                .font(AppTheme.Typography.titleSmall)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }
}

// MARK: - Dismissal persistence

/// Stores the `insight.id`s the user marked "Not for me", with their
/// dismissal date. They're ignored for 90 days, after which they're
/// back in the running (conditions may have changed).
final class InsightDismissalStore: @unchecked Sendable {
    static let shared = InsightDismissalStore()
    private let key = "insightDismissals"
    private let cooldownDays: TimeInterval = 90 * 24 * 3600

    /// Marks an insight as dismissed now.
    func dismiss(_ id: String) {
        var dict = stored()
        dict[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// Returns the set of currently dismissed IDs (date < cooldownDays).
    func activeDismissals() -> Set<String> {
        let now = Date().timeIntervalSince1970
        let dict = stored()
        var result: Set<String> = []
        for (id, ts) in dict where now - ts < cooldownDays {
            result.insert(id)
        }
        return result
    }

    private func stored() -> [String: TimeInterval] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: TimeInterval]) ?? [:]
    }
}
