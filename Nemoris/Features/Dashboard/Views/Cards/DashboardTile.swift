import SwiftUI

// MARK: - DashboardTile
//
// The single container for every card in the grid: background, header, a
// floor height, a skeleton and an empty state.
//
// **All the chrome lives here and nowhere else.** This is what keeps
// `DashboardCardHost`'s `switch` trivial (one line per card) and what guarantees
// the cards stay visually consistent — the old Dashboard's flaw was
// exactly three copy-pasted banners that had drifted apart from one another.
//
// ⚠️ Only the header is tappable when a card points to a module, never the
// whole tile: several contents have their own interactions (the monthly
// chart's bars, the coach's insights, the "Parent" toggle), which an enclosing
// `Button` would swallow.

struct DashboardTile<Content: View>: View {
    let card: DashboardCardID
    let size: DashboardCardSize
    /// `nil` as long as the card's aggregate isn't computed → a skeleton.
    var isLoading: Bool = false
    /// True when the aggregate arrived but holds nothing to show.
    var isEmpty: Bool = false
    var emptyMessage: String = "Aucune donnée"
    var subtitle: LocalizedStringResource? = nil
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

    // MARK: - Header

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
                Text(LocalizedStringKey(card.title))
                    .textCase(.uppercase)
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

    // MARK: - States

    /// A skeleton **per card**: each tile waits on its own aggregate. This is what
    /// replaces the whole screen's all-or-nothing skeleton — light cards
    /// show up without waiting on the coach, which scans 180 days.
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
        Text(LocalizedStringKey(emptyMessage))
            .font(AppTheme.Typography.bodySmall)
            .foregroundStyle(AppTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
