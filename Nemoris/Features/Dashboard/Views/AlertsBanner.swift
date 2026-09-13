import SwiftUI

/// Translates a severity into a theme color.
///
/// Lives here rather than on the enum itself: `AlertEngine` is a
/// computation engine and must not depend on any SwiftUI type. This banner is its
/// only consumer.
extension AlertSeverity {
    var color: Color {
        switch self {
        case .info:     return AppTheme.Colors.accent
        case .warning:  return AppTheme.Colors.warning
        case .critical: return AppTheme.Colors.danger
        }
    }
}

// MARK: - AlertsBanner
//
// An alert banner shown at the top of the Dashboard when `AlertEngine.compute()`
// returns at least one alert. UI pattern:
//   - only 1 alert → a full row with icon + title + message + chevron
//   - 2-3 alerts → tapping "See all" opens a sheet listing everything
//   - 4+ → the most severe one is shown + a "N alerts total" badge
//
// **Tap action**: routes to the relevant tab via `appState.selectedTab`.
// For the MVP, the exact sheet isn't opened (a complex deep link) — the user
// lands on the tab and finds the item easily.
//
// **Animation**: a gentle appearance transition (move + opacity), to avoid
// a jarring "pop" when alerts refresh.

struct AlertsBanner: View {
    @Environment(AppState.self) private var appState
    let alerts: [Alert]
    @State private var showAllSheet = false

    /// The highlighted alert — the most severe one. If there are 0 alerts the view is invisible.
    private var primary: Alert? { alerts.first }

    var body: some View {
        if let primary {
            Button {
                if alerts.count > 1 {
                    showAllSheet = true
                } else {
                    navigate(to: primary.route)
                }
            } label: {
                // Only the collapsed banner carries the counter: it announces "there
                // are N in total, tap to see".
                row(for: primary, showsTotalBadge: alerts.count > 1)
            }
            .buttonStyle(.plain)
            .adaptivePane(isPresented: $showAllSheet) {
                allAlertsSheet
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Row

    /// - Parameter showsTotalBadge: shows the **total number of alerts**. Reserved for
    ///   the collapsed banner. In the "All alerts" list, the same row used to be
    ///   rendered with this badge on EVERY line — five alerts therefore showed five
    ///   "5" badges, read as a counter specific to each envelope.
    @ViewBuilder
    private func row(for alert: Alert, showsTotalBadge: Bool) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: alert.systemIcon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(alert.severity.color)
                .frame(width: 36, height: 36)
                .background(alert.severity.color.opacity(0.15), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(AppTheme.Typography.titleSmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Text(alert.message)
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer()

            if showsTotalBadge {
                // A "N alerts total" badge + a chevron to signal there's more to see
                Text("\(alerts.count)")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(alert.severity.color, in: Capsule())
                    .foregroundStyle(.white)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
        }
        .padding(AppTheme.Spacing.md)
        .background(alert.severity.color.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(alert.severity.color.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - "All alerts" sheet

    @ViewBuilder private var allAlertsSheet: some View {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                List {
                    ForEach(alerts) { alert in
                        Button {
                            showAllSheet = false
                            // A slight delay so the sheet dismisses smoothly
                            // before the tab switch.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                navigate(to: alert.route)
                            }
                        } label: {
                            row(for: alert, showsTotalBadge: false)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4,
                                                  leading: AppTheme.Spacing.lg,
                                                  bottom: 4,
                                                  trailing: AppTheme.Spacing.lg))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppTheme.Colors.background)
            }
            .paneChrome("Toutes les alertes", cancelLabel: "Fermer", onCancel: { showAllSheet = false })
    }

    // MARK: - Navigation

    private func navigate(to route: AlertRoute) {
        switch route {
        case .patrimoine:   appState.navigateToTab(.patrimoine)
        case .budget:       appState.navigateToTab(.budget)
        case .transactions: appState.navigateToTab(.transactions)
        case .none:         break
        }
    }
}
