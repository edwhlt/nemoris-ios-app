import SwiftUI

// MARK: - DashboardCustomizeView
//
// The grid customization screen: show/hide, reorder, change the
// size of each card.
//
// **Strictly modeled on "Tab order"** (`SettingsView`): a `Form` +
// `ForEach` + `.onMove`, with `editMode` forced on iOS only.
//
// ⚠️ A short history: this screen briefly went through `List` +
// `.macGroupedRow` (the same recipe as `ModulesSettingsView`) to try to
// fix macOS reordering, which didn't work via `.onMove` alone
// (`.onMove` needs a real `List`/`ForEach`, never a `Form` — see
// `ModulesSettingsView`'s docs). Direct feedback: the `List`
// rendering (internal row separators, small-caps headers like a data
// list) made this SHORT, CURATED screen less readable than the old
// `Form` — separator lines are "nice when you have a huge amount of
// data in a scrollable […] you don't need that" here. Reverted to the original
// `Form`.
//
// macOS reordering doesn't NEED `List` regardless:
// `macReorderable` (`ReorderableRow.swift`) is built on `onDrag`/`onDrop`,
// generic SwiftUI modifiers that work on ANY view
// — `Form` included, not just `List`. It's `.onMove` specifically (not
// drag&drop in general) that needs a real `List`. `ReorderHandle()`
// (same file) makes the gesture DISCOVERABLE — without it the row is
// draggable but nothing on screen suggests it ("you can drag,
// but you can't see that you can").
//
// ⚠️ `Form { }.background(…)` and definitely NOT `ZStack { Color.ignoresSafeArea(); Form }`:
// on macOS `Color.ignoresSafeArea()` makes the Form infinitely tall (a window stretched
// to the max, invisible content) — the pitfall documented in CLAUDE.md §N.1.

struct DashboardCustomizeView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var purchaseManager
    @Environment(\.dismiss) private var dismiss
    /// macOS: closes the swap-by-state view (see `DashboardView.body`) — the
    /// view then replaces the dashboard without going through a sheet/push, so
    /// `dismiss()` alone would have nothing to close. nil on iOS, where the view stays
    /// pushed inside the dashboard's sheet and `dismiss()` is enough.
    var onBack: (() -> Void)? = nil
    #if os(macOS)
    /// The card currently being dragged — see `macReorderable` (`ReorderableRow.swift`).
    @State private var draggedCard: DashboardCardPreference?
    #endif

    var body: some View {
        @Bindable var appState = appState
        Form {
            Section {
                // `$appState.dashboardLayout` directly: `dashboardLayout`
                // is a STORED property (like `mainTabOrder` since
                // 2026-09 — a computed get/set over `UserDefaults` notifies
                // no `@Observable` observer, which caused a perceived freeze
                // at the end of a drag, see `AppState.mainTabOrder`'s docs),
                // so `macReorderable` can reorder in place with no local
                // `@State` mirror.
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
        // Same choice as the "Tab order" screen: permanent edit mode
        // avoids an "Edit" button for a list whose only function that is.
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
                        // The preference for a card whose module is disabled/subscription
                        // expired is NEVER cleared: re-enabling the module or
                        // renewing Pro restores its position and size.
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

            // The size selector only makes sense if the card supports several:
            // a 12-bar chart on half an iPhone's width is unreadable, so
            // some cards only exist in the wide size.
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

    /// Only called for a card already deemed unavailable: distinguishes a module
    /// disabled in Settings (`showBudget` etc. set to `false`) from an
    /// expired Pro subscription (the module still enabled, but `PurchaseManager`
    /// no longer unlocks it) — the same check order as `AppState.isDashboardCardAvailable`.
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

    /// Rewrites the full array: `dashboardLayout` is a **stored** property
    /// observed by the grid, so reassigning it triggers a refresh (and
    /// saving, via its `didSet`).
    private func update(_ card: DashboardCardID, _ mutate: (inout DashboardCardPreference) -> Void) {
        guard let index = appState.dashboardLayout.firstIndex(where: { $0.card == card }) else { return }
        var layout = appState.dashboardLayout
        mutate(&layout[index])
        appState.dashboardLayout = layout
    }
}
