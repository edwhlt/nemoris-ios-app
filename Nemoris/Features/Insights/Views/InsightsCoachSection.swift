import SwiftUI

// MARK: - InsightsCoachSection
//
// Section "Coach" affichée dans le Dashboard. Affiche les **3 meilleurs**
// insights selon `compositeScore`. Tap sur un insight ouvre une sheet détail
// avec le `detail` complet + boutons d'action (Vu / Pas pour moi).
//
// **Persistance des dismissals** : les insights "Pas pour moi" sont stockés
// dans UserDefaults par `id` — on ne les re-suggère plus pendant 90 j (au-delà,
// peut-être que l'utilisateur a changé d'avis ou que les conditions ont évolué).

struct InsightsCoachSection: View {
    let insights: [Insight]
    /// `false` quand la section est rendue dans une `DashboardTile`, qui porte déjà
    /// le titre — sinon on empilerait deux en-têtes.
    var showsHeader: Bool = true
    @State private var selectedInsight: Insight? = nil

    /// Top 3 insights non dismissés.
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
                Text(insight.kind.label.uppercased())
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
                    // Header — icône + kind label
                    HStack(spacing: AppTheme.Spacing.md) {
                        Image(systemName: insight.kind.systemIcon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(AppTheme.Colors.accent)
                            .frame(width: 56, height: 56)
                            .background(AppTheme.Colors.accent.opacity(0.13), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(insight.kind.label.uppercased())
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

                    // KPIs (gain potentiel, faisabilité, confiance)
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
    private func kpi(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
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

/// Stocke les `insight.id` que l'utilisateur a marqués "Pas pour moi" avec leur
/// date de dismissal. On les ignore pendant 90 jours, après quoi ils sont
/// remis en lice (peut-être que les conditions ont changé).
final class InsightDismissalStore: @unchecked Sendable {
    static let shared = InsightDismissalStore()
    private let key = "insightDismissals"
    private let cooldownDays: TimeInterval = 90 * 24 * 3600

    /// Marque un insight comme dismissé maintenant.
    func dismiss(_ id: String) {
        var dict = stored()
        dict[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(dict, forKey: key)
    }

    /// Retourne le set des IDs actuellement dismissés (date < cooldownDays).
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
