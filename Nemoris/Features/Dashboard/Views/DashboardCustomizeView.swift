import SwiftUI

// MARK: - DashboardCustomizeView
//
// Écran de personnalisation de la grille : afficher/masquer, réordonner, changer la
// taille de chaque carte.
//
// **Calque strictement sur « Ordre des onglets »** (`SettingsView`) : `Form` +
// `ForEach` + `.onMove`, avec `editMode` forcé sur iOS uniquement. C'est le seul
// pattern de réordonnancement déjà validé sur macOS dans cette app — le drag&drop y
// fonctionne nativement sans mode édition.
//
// ⚠️ `Form { }.background(…)` et surtout PAS `ZStack { Color.ignoresSafeArea(); Form }` :
// sur macOS le `Color.ignoresSafeArea()` rend le Form infiniment haut (fenêtre étirée
// au maximum, contenu invisible) — piège documenté dans CLAUDE.md §N.1.

struct DashboardCustomizeView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.dismiss) private var dismiss
    /// macOS : ferme la vue swap-par-état (cf. `DashboardView.body`) — la vue
    /// remplace alors le dashboard sans passer par une sheet/push, donc
    /// `dismiss()` seul n'aurait rien à fermer. nil sur iOS, où la vue reste
    /// poussée dans la sheet du dashboard et `dismiss()` suffit.
    var onBack: (() -> Void)? = nil

    var body: some View {
        Form {
            Section {
                ForEach(appState.dashboardLayout) { preference in
                    row(for: preference)
                }
                .onMove(perform: move)
            } header: {
                Text("Cartes du tableau de bord")
            } footer: {
                Text("Glissez pour réordonner. Les cartes masquées ne sont pas calculées : les masquer allège aussi le chargement de l'écran.")
            }

            Section {
                Button("Réinitialiser la disposition", role: .destructive) {
                    appState.dashboardLayout = DashboardLayoutStore.sanitize([])
                    HapticService.shared.warning()
                }
            } footer: {
                Text("Le hero, les alertes et la bande « Vue d'ensemble » sont fixes et restent toujours affichés.")
            }
        }
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Personnaliser")
        #if os(iOS)
        // Même choix que l'écran « Ordre des onglets » : le mode édition permanent
        // évite un bouton « Modifier » pour une liste dont c'est la seule fonction.
        .environment(\.editMode, .constant(.active))
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Terminé") {
                    if let onBack { onBack() } else { dismiss() }
                }
            }
        }
    }

    // MARK: - Ligne

    @ViewBuilder
    private func row(for preference: DashboardCardPreference) -> some View {
        let isAvailable = appState.isDashboardCardAvailable(preference.card, purchaseManager: purchaseManager)

        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: preference.card.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isAvailable ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preference.card.title)
                        .font(AppTheme.Typography.bodyMedium)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if !isAvailable, let module = preference.card.requiredModule {
                        // On n'efface JAMAIS la préférence d'une carte dont le module
                        // est désactivé/l'abonnement expiré : réactiver le module ou
                        // renouveler le Pro restitue sa place et sa taille.
                        Text(unavailableReason(module))
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.warning)
                    }
                }

                Spacer(minLength: 0)

                Toggle("", isOn: Binding(
                    get: { preference.isVisible },
                    set: { newValue in
                        update(preference.card) { $0.isVisible = newValue }
                        HapticService.shared.toggle()
                    }
                ))
                .labelsHidden()
                .disabled(!isAvailable)
            }

            // Le sélecteur de taille n'a de sens que si la carte en supporte plusieurs :
            // un graphe à 12 barres sur une demi-largeur d'iPhone est illisible, donc
            // certaines cartes n'existent qu'en large.
            if preference.isVisible, isAvailable, preference.card.supportedSizes.count > 1 {
                Picker("Taille", selection: Binding(
                    get: { preference.size },
                    set: { newValue in update(preference.card) { $0.size = newValue } }
                )) {
                    ForEach(preference.card.supportedSizes, id: \.self) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(.vertical, 2)
        .opacity(isAvailable ? 1 : 0.55)
    }

    /// N'est appelée que pour une carte déjà jugée indisponible : distingue le module
    /// désactivé dans les Réglages (`showBudget` etc. à `false`) de l'abonnement Pro
    /// qui a expiré (module toujours activé, mais `PurchaseManager` ne le déverrouille
    /// plus) — même ordre de check que `AppState.isDashboardCardAvailable`.
    private func unavailableReason(_ module: MainTabItem) -> String {
        guard appState.availableTabsResolved.contains(module) else {
            return "Module « \(module.title) » désactivé"
        }
        return "Abonnement Pro requis"
    }

    // MARK: - Mutations

    private func move(from source: IndexSet, to destination: Int) {
        var layout = appState.dashboardLayout
        layout.move(fromOffsets: source, toOffset: destination)
        appState.dashboardLayout = layout
    }

    /// Réécrit le tableau complet : `dashboardLayout` est une propriété **stockée**
    /// observée par la grille, donc réassigner déclenche le rafraîchissement (et la
    /// sauvegarde via son `didSet`).
    private func update(_ card: DashboardCardID, _ mutate: (inout DashboardCardPreference) -> Void) {
        guard let index = appState.dashboardLayout.firstIndex(where: { $0.card == card }) else { return }
        var layout = appState.dashboardLayout
        mutate(&layout[index])
        appState.dashboardLayout = layout
    }
}
