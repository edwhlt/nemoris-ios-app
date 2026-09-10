import SwiftUI

// MARK: - DashboardCustomizeView
//
// Écran de personnalisation de la grille : afficher/masquer, réordonner, changer la
// taille de chaque carte.
//
// **Calque strictement sur « Ordre des onglets »** (`SettingsView`) : `Form` +
// `ForEach` + `.onMove`, avec `editMode` forcé sur iOS uniquement.
//
// ⚠️ Historique court : cet écran est brièvement passé par `List` +
// `.macGroupedRow` (même recette que `ModulesSettingsView`) pour tenter de
// réparer le réordonnancement macOS, qui ne marchait pas via `.onMove` seul
// (`.onMove` a besoin d'une vraie `List`/`ForEach`, jamais d'un `Form` — cf.
// doc `ModulesSettingsView`). Retour d'usage direct (2026-09) : le rendu
// `List` (séparateurs internes entre rows, en-tête petite-caps façon liste de
// données) rendait cet écran COURT ET CURATÉ moins lisible que l'ancien
// `Form` — les lignes de séparation "c'est bien quand on a énormément de
// données dans un scrollable […] on a pas besoin de ça" ici. Revenu au `Form`
// d'origine.
//
// Le réordonnancement macOS n'a PAS besoin de `List` pour autant :
// `macReorderable` (`ReorderableRow.swift`) est bâti sur `onDrag`/`onDrop`,
// des modifiers SwiftUI génériques qui fonctionnent sur N'IMPORTE QUELLE vue
// — `Form` compris, pas seulement `List`. C'est `.onMove` spécifiquement (pas
// le drag&drop en général) qui a besoin d'un vrai `List`. `ReorderHandle()`
// (même fichier) rend le geste DÉCOUVRABLE — sans lui la row est glissable
// mais rien à l'écran ne le suggère (retour d'usage 2026-09 : "on peut drag,
// mais on ne voit pas qu'on peut le faire").
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
    #if os(macOS)
    /// Carte actuellement glissée — cf. `macReorderable` (`ReorderableRow.swift`).
    @State private var draggedCard: DashboardCardPreference?
    #endif

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section {
                // `$appState.dashboardLayout` directement : `dashboardLayout`
                // est une propriété STOCKÉE (comme `mainTabOrder` depuis
                // 2026-09 — un get/set calculé sur `UserDefaults` ne notifie
                // aucun observateur `@Observable`, ce qui causait un freeze
                // perçu à la fin d'un drag, cf. doc `AppState.mainTabOrder`),
                // donc `macReorderable` peut réordonner en place sans mirroir
                // `@State` local.
                ForEach(appState.dashboardLayout) { preference in
                    row(for: preference)
                        #if os(macOS)
                        .macReorderable(preference, items: $appState.dashboardLayout, dragged: $draggedCard) {}
                        #endif
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
        .localizedNavigationTitle("Personnaliser")
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
                    Text(LocalizedStringKey(preference.card.title))
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

                #if os(macOS)
                ReorderHandle()
                #endif
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
                        Text(LocalizedStringKey(size.label)).tag(size)
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
    private func unavailableReason(_ module: MainTabItem) -> LocalizedStringKey {
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
