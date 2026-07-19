import SwiftUI

// MARK: - AlertsBanner
//
// Bandeau d'alertes affiché en haut du Dashboard quand `AlertEngine.compute()`
// renvoie au moins une alerte. Pattern UI :
//   - 1 seule alerte → row complète avec icône + titre + message + chevron
//   - 2-3 alertes → tap "Voir tout" ouvre une sheet listant tout
//   - 4+ → on affiche la plus sévère + badge "N alertes au total"
//
// **Tap action** : route vers l'onglet pertinent via `appState.selectedTab`.
// Pour MVP on n'ouvre pas la fiche exacte (deep-link complexe) — l'user
// arrive sur l'onglet et trouve l'item facilement.
//
// **Animation** : transition d'apparition douce (move + opacity), pour éviter
// un "pop" brutal quand les alertes se rafraîchissent.

struct AlertsBanner: View {
    @Environment(AppState.self) private var appState
    let alerts: [Alert]
    @State private var showAllSheet = false

    /// L'alerte mise en avant — la plus sévère. Si 0 alerte la vue est invisible.
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
                row(for: primary)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showAllSheet) {
                allAlertsSheet
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(for alert: Alert) -> some View {
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

            if alerts.count > 1 {
                // Badge "N alertes au total" + chevron pour signaler qu'il y a + à voir
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

    // MARK: - Sheet "toutes les alertes"

    @ViewBuilder private var allAlertsSheet: some View {
        NavigationStack {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                List {
                    ForEach(alerts) { alert in
                        Button {
                            showAllSheet = false
                            // Délai léger pour que la sheet dismiss soit fluide
                            // avant le switch de tab.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                navigate(to: alert.route)
                            }
                        } label: {
                            row(for: alert)
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
            .navigationTitle("Toutes les alertes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { showAllSheet = false }
                }
            }
        }
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
