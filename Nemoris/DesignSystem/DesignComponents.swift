import SwiftUI
import TipKit

// MARK: - AppCard

struct AppCard<Content: View>: View {
    var padding: CGFloat = AppTheme.Spacing.lg
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .appCardStyle(padding: padding)
    }
}

// MARK: - SectionHeader

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var action: (() -> Void)? = nil
    var actionLabel: String = "Voir tout"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Typography.titleMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
            Spacer()
            if let action {
                Button(actionLabel, action: action)
                    .font(AppTheme.Typography.labelLarge)
                    .foregroundStyle(AppTheme.Colors.accent)
            }
        }
    }
}

// MARK: - StatBadge

struct StatBadge: View {
    let label: String
    let value: String
    var valueColor: Color = AppTheme.Colors.textPrimary
    var icon: String? = nil

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(valueColor)
            }
            Text(value)
                .font(AppTheme.Typography.moneySmall)
                .foregroundStyle(valueColor)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(label)
                .font(AppTheme.Typography.labelSmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - AnimatedNumberText

struct AnimatedNumberText: View {
    let value: Double
    var currencyCode: String = "EUR"
    var font: Font = AppTheme.Typography.moneyMedium
    var color: Color = AppTheme.Colors.textPrimary

    var body: some View {
        Text(value, format: .currency(code: currencyCode).presentation(.narrow))
            .font(font)
            .foregroundStyle(color)
            .contentTransition(.numericText())
            .animation(AppTheme.Animations.spring, value: value)
    }
}

// MARK: - AppChartCard

struct AppChartCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var accentColor: Color = AppTheme.Colors.accent
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                Spacer()
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 3, height: 16)
            }
            content()
        }
        .appCardStyle()
    }
}

// MARK: - PremiumDashboardSummaryCard

struct PremiumDashboardSummaryCard: View {
    let stats: DashboardStats
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            // Header row
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppTheme.Typography.labelMedium)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text(subtitle)
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                Spacer()
                // Net balance pill
                let net = stats.netBalance
                Text(net, format: .currency(code: "EUR").presentation(.narrow))
                    .font(AppTheme.Typography.labelLarge)
                    .foregroundStyle(net >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(
                        Capsule().fill(
                            (net >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger).opacity(0.15)
                        )
                    )
            }

            Rectangle()
                .fill(AppTheme.Colors.surfaceSecondary)
                .frame(height: 1)

            // Stats row
            HStack(spacing: 0) {
                StatBadge(
                    label: "Recettes",
                    value: stats.totalIncome.formatted(.currency(code: "EUR").presentation(.narrow)),
                    valueColor: AppTheme.Colors.success,
                    icon: "arrow.down.circle.fill"
                )
                Rectangle()
                    .fill(AppTheme.Colors.surfaceSecondary)
                    .frame(width: 1, height: 48)
                StatBadge(
                    label: "Dépenses",
                    value: abs(stats.totalExpense).formatted(.currency(code: "EUR").presentation(.narrow)),
                    valueColor: AppTheme.Colors.danger,
                    icon: "arrow.up.circle.fill"
                )
                if stats.transactionCount > 0 {
                    Rectangle()
                        .fill(AppTheme.Colors.surfaceSecondary)
                        .frame(width: 1, height: 48)
                    StatBadge(
                        label: "Transactions",
                        value: "\(stats.transactionCount)",
                        valueColor: AppTheme.Colors.accent,
                        icon: "list.bullet.circle.fill"
                    )
                }
            }
        }
        .appCardStyle()
    }
}

// MARK: - FilterPill

struct FilterPill: View {
    let label: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xs) {
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
                Text(label)
                    .font(AppTheme.Typography.labelLarge)
            }
            .foregroundStyle(isActive ? .white : AppTheme.Colors.textSecondary)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(
                Capsule().fill(isActive ? AppTheme.Colors.accent : AppTheme.Colors.surfaceSecondary)
            )
        }
        .buttonStyle(.plain)
        .animation(AppTheme.Animations.springSnappy, value: isActive)
    }
}

// MARK: - InfoBadge

struct InfoBadge: View {
    let label: String
    let icon: String
    var color: Color = AppTheme.Colors.accent

    var body: some View {
        Label(label, systemImage: icon)
            .font(AppTheme.Typography.labelMedium)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs + 1)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - EmptyStateView

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Image(systemName: icon)
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.45))
            VStack(spacing: AppTheme.Spacing.sm) {
                Text(title)
                    .font(AppTheme.Typography.titleMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(message)
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppTheme.Spacing.xxxl)
        .padding(.top, 60)
    }
}

// MARK: - LoadingCardView

struct LoadingCardView: View {
    var body: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            ProgressView()
                .tint(AppTheme.Colors.accent)
                .scaleEffect(1.3)
            Text("Chargement…")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - NemorisTipViewStyle

struct NemorisTipViewStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {

            // Icon bubble
            if let image = configuration.image {
                image
                    .foregroundStyle(AppTheme.Colors.accent)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(
                        AppTheme.Colors.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    )
            }

            // Text content
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                if let title = configuration.title {
                    title
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                if let message = configuration.message {
                    message
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                if !configuration.actions.isEmpty {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        ForEach(configuration.actions) { action in
                            Button {
                                configuration.tip.invalidate(reason: .actionPerformed)
                            } label: {
                                action.label()
                                    .font(AppTheme.Typography.labelLarge)
                                    .foregroundStyle(AppTheme.Colors.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)

            // Dismiss button
            Button {
                configuration.tip.invalidate(reason: .tipClosed)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(AppTheme.Colors.surfaceSecondary, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Colors.surfaceSecondary, lineWidth: 1)
        )
    }
}

// MARK: - AppToast (reusable feedback banner)

/// Niveau sémantique d'un toast — pilote l'icône et la couleur d'accent.
enum AppToastKind {
    case success, info, warning, error

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .success: return AppTheme.Colors.success
        case .info:    return AppTheme.Colors.accent
        case .warning: return AppTheme.Colors.warning
        case .error:   return AppTheme.Colors.danger
        }
    }
}

/// Modèle léger pour un toast affiché par `ToastCenter`.
/// `id` UUID → SwiftUI peut détecter un nouveau toast même si message identique.
struct AppToastMessage: Identifiable, Equatable {
    let id = UUID()
    let kind: AppToastKind
    let text: String

    static func == (lhs: AppToastMessage, rhs: AppToastMessage) -> Bool {
        lhs.id == rhs.id
    }
}

/// Bannière flottante temporaire — utilisable via le modifier `.appToast(_:)`.
struct AppToast: View {
    let message: AppToastMessage

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: message.kind.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(message.kind.color)
            Text(message.text)
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(message.kind.color.opacity(0.3), lineWidth: 1)
        )
        .softShadow()
    }
}

private struct AppToastModifier: ViewModifier {
    @Binding var message: AppToastMessage?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    AppToast(message: message)
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.top, AppTheme.Spacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(AppTheme.Animations.spring, value: message?.id)
            .onChange(of: message?.id) { _, newId in
                guard let newId else { return }
                // Auto-dismiss après 3 secondes.
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if message?.id == newId {
                        message = nil
                    }
                }
            }
    }
}

extension View {
    /// Affiche un toast temporaire (3 s) en haut de la vue.
    /// Mettre `message = nil` pour le retirer manuellement.
    func appToast(_ message: Binding<AppToastMessage?>) -> some View {
        modifier(AppToastModifier(message: message))
    }
}

// MARK: - Previews

#Preview("PremiumDashboardSummaryCard") {
    PremiumDashboardSummaryCard(
        stats: DashboardStats(totalIncome: 4850.50, totalExpense: -2340.75, transactionCount: 42),
        title: "Tous comptes",
        subtitle: "Mai 2026"
    )
    .padding()
    .background(AppTheme.Colors.background)
}

#Preview("SectionHeader") {
    SectionHeader(title: "Revenus & Dépenses", subtitle: "Touchez un mois pour filtrer") {}
        .padding()
        .background(AppTheme.Colors.background)
}
