import SwiftUI

// MARK: - DashboardOverviewBanner
//
// Bande « Vue d'ensemble » : trois chiffres de modules côte à côte, chacun tappable
// vers son onglet.
//
// **Remplace trois bandeaux pleine largeur** (Investissements, Patrimoine, Budget)
// qui étaient trois copies quasi identiques du même agencement — icône 44pt en
// cercle, eyebrow 10pt tracking 0.6, valeur, sous-titre, chevron, dégradé et
// bordure — pour ~210 lignes dupliquées. Empilés, ils consommaient à eux seuls près
// de trois écrans de scroll pour délivrer trois nombres.
//
// C'est un élément **fixe** du Dashboard : il n'entre pas dans la grille de cartes
// configurables. Une colonne dont le module est désactivé (ou sans donnée) disparaît
// et les autres se répartissent la largeur.

struct DashboardOverviewBanner: View {
    /// Lu pour le toggle de masquage global : `compact(_:)` court-circuite `MoneyText`,
    /// il doit donc respecter le masquage lui-même. L'ancien bandeau Patrimoine
    /// affichait le montant des dettes en clair même œil fermé.
    @Environment(AppState.self) private var appState

    /// `nil` = colonne masquée (module désactivé ou aucune donnée à montrer).
    let investments: InvestmentsRecap?
    let patrimoine: PatrimoineSnapshot?
    let budget: BudgetRecap?
    let onSelect: (MainTabItem) -> Void

    private var hasAnyColumn: Bool {
        investments != nil || patrimoine != nil || budget != nil
    }

    var body: some View {
        if hasAnyColumn {
            HStack(alignment: .top, spacing: 0) {
                if let investments {
                    column(
                        icon: "chart.line.uptrend.xyaxis",
                        tint: AppTheme.Colors.accentSecondary,
                        title: "Investi",
                        destination: .investments
                    ) {
                        MoneyText(
                            amount: investments.totalCurrentValue,
                            font: AppTheme.Typography.moneySmall,
                            maskedPlaceholder: "••• €"
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                        if investments.totalInvested > 0 {
                            caption(
                                String(format: "%@%.1f %%",
                                       investments.pnlAbsolute >= 0 ? "+" : "",
                                       investments.pnlPercent),
                                color: investments.pnlAbsolute >= 0
                                    ? AppTheme.Colors.success
                                    : AppTheme.Colors.danger
                            )
                        } else {
                            caption("\(investments.activeAccountCount) compte\(investments.activeAccountCount > 1 ? "s" : "")")
                        }
                    }
                }

                if patrimoine != nil, investments != nil { separator }

                if let patrimoine {
                    column(
                        icon: "house.fill",
                        tint: AppTheme.Colors.accent,
                        title: "Patrimoine",
                        destination: .patrimoine
                    ) {
                        MoneyText(
                            amount: patrimoine.netWorth,
                            font: AppTheme.Typography.moneySmall,
                            color: patrimoine.netWorth >= 0
                                ? AppTheme.Colors.textPrimary
                                : AppTheme.Colors.danger,
                            maskedPlaceholder: "••• €"
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)

                        // Le passif explique pourquoi le net peut être négatif — c'est
                        // l'information la plus utile à côté du net.
                        if patrimoine.totalLiabilities > 0 {
                            caption(
                                appState.amountsHidden
                                    ? "••• de dettes"
                                    : "\(compact(patrimoine.totalLiabilities)) de dettes",
                                color: AppTheme.Colors.danger
                            )
                        } else {
                            caption("\(patrimoine.itemsCount) élément\(patrimoine.itemsCount > 1 ? "s" : "")")
                        }
                    }
                }

                if budget != nil, investments != nil || patrimoine != nil { separator }

                if let budget {
                    column(
                        icon: budgetIcon(budget),
                        tint: budgetTint(budget),
                        title: "Enveloppes",
                        destination: .budget
                    ) {
                        Text("\(budget.totalCount)")
                            .font(AppTheme.Typography.moneySmall)
                            .foregroundStyle(AppTheme.Colors.textPrimary)

                        HStack(spacing: 6) {
                            chip(budget.healthyCount, color: AppTheme.Colors.success, icon: "checkmark")
                            chip(budget.warningCount, color: AppTheme.Colors.warning, icon: "exclamationmark")
                            chip(budget.exceededCount, color: AppTheme.Colors.danger, icon: "xmark")
                        }
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.md)
            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .strokeBorder(AppTheme.Colors.textSecondary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: - Composants

    @ViewBuilder
    private func column<Content: View>(
        icon: String,
        tint: Color,
        title: String,
        destination: MainTabItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            HapticService.shared.selection()
            onSelect(destination)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var separator: some View {
        Rectangle()
            .fill(AppTheme.Colors.textSecondary.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, 2)
    }

    @ViewBuilder
    private func caption(_ text: String, color: Color = AppTheme.Colors.textSecondary) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    @ViewBuilder
    private func chip(_ count: Int, color: Color, icon: String) -> some View {
        if count > 0 {
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 7, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
        }
    }

    private func budgetIcon(_ recap: BudgetRecap) -> String {
        if recap.exceededCount > 0 { return "xmark.octagon.fill" }
        if recap.warningCount > 0 { return "exclamationmark.triangle.fill" }
        return "checkmark.seal.fill"
    }

    private func budgetTint(_ recap: BudgetRecap) -> Color {
        if recap.exceededCount > 0 { return AppTheme.Colors.danger }
        if recap.warningCount > 0 { return AppTheme.Colors.warning }
        return AppTheme.Colors.success
    }

    /// Montant abrégé (« 300,8 k€ ») : sur un tiers de largeur d'iPhone, un passif à
    /// six chiffres écrasé par `minimumScaleFactor` devient illisible.
    private func compact(_ amount: Double) -> String {
        let value = abs(amount)
        if value >= 1_000_000 {
            return String(format: "%.1f M€", value / 1_000_000)
        }
        if value >= 10_000 {
            return String(format: "%.0f k€", value / 1_000)
        }
        if value >= 1_000 {
            return String(format: "%.1f k€", value / 1_000)
        }
        // Reste cohérent avec les 2 branches ci-dessus (abrégé maison, décimale
        // à point) plutôt que `.formatted(.currency(...))` — qui, appelé hors
        // d'un `Text(_:format:)`, ignore la locale forcée par l'app et bascule
        // sur celle, réelle, de l'appareil (cf. fix Patrimoine).
        return String(format: "%.2f €", value)
    }
}
