import SwiftUI

// MARK: - DashboardTile
//
// Le conteneur unique de toutes les cartes de la grille : fond, en-tête, hauteur
// plancher, squelette et état vide.
//
// **Tout le chrome vit ici et nulle part ailleurs.** C'est ce qui garde le `switch`
// de `DashboardCardHost` trivial (une ligne par carte) et ce qui garantit que les
// cartes restent visuellement homogènes — le défaut de l'ancien Dashboard était
// justement trois bandeaux copiés-collés qui avaient dérivé les uns des autres.
//
// ⚠️ L'en-tête seul est tappable quand la carte pointe vers un module, jamais la
// tuile entière : plusieurs contenus ont leurs propres interactions (barres du
// graphe mensuel, insights du coach, toggle « Parente »), qu'un `Button` englobant
// avalerait.

struct DashboardTile<Content: View>: View {
    let card: DashboardCardID
    let size: DashboardCardSize
    /// `nil` tant que l'agrégat de la carte n'est pas calculé → squelette.
    var isLoading: Bool = false
    /// Vrai quand l'agrégat est arrivé mais ne contient rien à montrer.
    var isEmpty: Bool = false
    var emptyMessage: String = "Aucune donnée"
    var subtitle: String? = nil
    var onOpenModule: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            header

            if isLoading {
                loadingContent
            } else if isEmpty {
                emptyContent
            } else {
                content()
            }

            Spacer(minLength: 0)
        }
        .padding(AppTheme.Spacing.lg)
        .frame(
            maxWidth: .infinity,
            minHeight: DashboardLayoutMetrics.minHeight(for: size),
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Colors.textSecondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - En-tête

    @ViewBuilder private var header: some View {
        if let onOpenModule {
            Button {
                HapticService.shared.selection()
                onOpenModule()
            } label: {
                headerContent(showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            headerContent(showsChevron: false)
        }
    }

    @ViewBuilder
    private func headerContent(showsChevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Image(systemName: card.systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let subtitle {
                    Text(subtitle)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - États

    /// Squelette **par carte** : chaque tuile attend son propre agrégat. C'est ce qui
    /// remplace le squelette tout-ou-rien de l'écran entier — les cartes légères
    /// s'affichent sans attendre le coach, qui scanne 180 jours.
    @ViewBuilder private var loadingContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            SkeletonLine(width: 120, height: 22)
            SkeletonLine(width: 80, height: 12)
            if size == .wide {
                SkeletonLine(width: 200, height: 12)
            }
        }
    }

    @ViewBuilder private var emptyContent: some View {
        Text(emptyMessage)
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
