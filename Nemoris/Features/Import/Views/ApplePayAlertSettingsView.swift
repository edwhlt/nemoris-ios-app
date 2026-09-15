import SwiftUI

/// Apple Pay configuration menu: installing the shortcut, the threshold
/// alert, cleaning up old entries.
///
/// Local state only (`@State`, not `AppState`): this setting only needs to be
/// read here and by `ApplePayAlertService`, which re-reads
/// `ApplePayAlertSettings` (UserDefaults) directly on every trigger — same
/// doctrine as `AISettingsView`.
///
/// Automatic resolution at app launch (engine → silent promotion to a
/// transaction) is not implemented; manual cleanup is the only way to avoid
/// accumulation.
struct ApplePayAlertSettingsView: View {
    @Environment(\.paneDismiss) private var paneDismiss

    /// `true` (default): the view is opened as a pane from the Dashboard —
    /// it carries its own `.paneChrome` (a "Close" button). `false`: reached
    /// through standard navigation from Settings
    /// (`SettingsSection.applePay`), where `SettingsView`'s generic wrapper
    /// already supplies a title and a back button — adding `.paneChrome`
    /// here would stack a second button and title (same class of bug as
    /// `.modules`/`.ai`, see `SettingsView.settingsSectionPage`).
    var isPane: Bool = true
    /// Hidden from the Dashboard (`false` there): if the "pending" banner
    /// is visible, the shortcut has necessarily already run at least once to
    /// drop that entry off — offering to install it there makes no sense.
    /// Always visible from Settings (`true`, the default), which is the
    /// entry point for a first-time setup.
    var showsInstallSection: Bool = true

    @State private var isEnabled = ApplePayAlertSettings.isEnabled
    @State private var threshold = ApplePayAlertSettings.threshold
    @State private var period = ApplePayAlertSettings.period

    @State private var purgeOlderThanDays = 30
    @State private var showPurgeConfirmation = false
    // `LocalizedStringResource`, not `String`: built once in `performPurge` and
    // re-read later by `body` — a plain `String` would freeze whatever language
    // was active at construction time.
    @State private var purgeResultMessage: LocalizedStringResource?

    var body: some View {
        if isPane {
            formContent
                .paneChrome("Apple Pay", cancelLabel: "Fermer", onCancel: { paneDismiss() })
        } else {
            // `.paneChrome` supplies its own title on the pane side, but in
            // standard navigation from Settings, `settingsLink` pushes this
            // destination BARE on iOS (unlike macOS, where
            // `SettingsView.settingsSectionPage` applies
            // `.localizedNavigationTitle` from outside) — without a title set
            // HERE, the bar stays empty. Same convention as the other "flat"
            // destinations (`BackupSettingsView`, etc.), which all set it
            // themselves.
            formContent
                .localizedNavigationTitle("Apple Pay")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var formContent: some View {
        Form {
            if showsInstallSection {
                Section {
                    Button {
                        // Resolved from `versions.json` at tap time rather
                        // than a URL baked into the app: whoever maintains
                        // the automation can publish a newer version (a
                        // fresh export, or just a new iCloud link) without a
                        // new app build. `@MainActor` for `UIApplication`/
                        // `NSWorkspace`, same convention as
                        // `EngineBootstrap.bootIfNeeded()`.
                        Task { @MainActor in
                            let url = await ApplePayShortcutManifest.resolveInstallURL()
                            #if os(iOS)
                            await UIApplication.shared.open(url)
                            #else
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                    } label: {
                        Label("Installer le raccourci Apple Pay", systemImage: "square.and.arrow.down.on.square")
                    }
                } footer: {
                    Text("Ouvre l'app Raccourcis pour ajouter l'automatisation qui dépose une dépense Apple Pay dans Nemoris — à configurer une seule fois (Automatisation personnelle → Apple Pay).")
                }
            }

            Section {
                Toggle("Alerte Apple Pay", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        ApplePayAlertSettings.isEnabled = newValue
                    }
            } footer: {
                Text("Une notification est envoyée quand le cumul des dépenses Apple Pay encore en attente dépasse le seuil sur la période choisie.")
            }

            if isEnabled {
                Section("Seuil") {
                    HStack {
                        Text("Montant")
                        Spacer()
                        TextField("Seuil", value: $threshold, format: .number)
                            #if os(iOS)
                            .keyboardType(.decimalPad)
                            #endif
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                            .onChange(of: threshold) { _, newValue in
                                ApplePayAlertSettings.threshold = newValue
                            }
                        Text("€")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Section("Période") {
                    Picker("Période", selection: $period) {
                        ForEach(ApplePayAlertPeriod.allCases, id: \.self) { p in
                            // `p.label` is a runtime `String`, not a literal —
                            // `Text(String)` would stay verbatim without this
                            // wrap, cf. CLAUDE.md §5.
                            Text(LocalizedStringKey(p.label)).tag(p)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .onChange(of: period) { _, newValue in
                        ApplePayAlertSettings.period = newValue
                    }
                }
            }

            Section {
                Picker("Ancienneté", selection: $purgeOlderThanDays) {
                    Text("7 jours").tag(7)
                    Text("30 jours").tag(30)
                    Text("90 jours").tag(90)
                    Text("180 jours").tag(180)
                }
                Button(role: .destructive) {
                    showPurgeConfirmation = true
                } label: {
                    Text("Nettoyer les anciennes dépenses")
                }
                if let purgeResultMessage {
                    Text(purgeResultMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            } header: {
                Text("Nettoyage")
            } footer: {
                Text("Supprime définitivement les dépenses en attente ou écartées déposées avant cette ancienneté, pour éviter d'en accumuler trop. Ne touche pas aux vraies transactions.")
            }
        }
        .nemorisFormStyle()
        .tint(AppTheme.Colors.accent)
        .alert("Supprimer les anciennes dépenses ?", isPresented: $showPurgeConfirmation) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive, action: performPurge)
        } message: {
            Text("Cette action est irréversible.")
        }
    }

    private func performPurge() {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -purgeOlderThanDays, to: Date()) else { return }
        let repository = PendingApplePayRepository()
        let count = repository.purgeEntries(olderThan: cutoff)
        purgeResultMessage = count > 0
            ? "\(count) dépense\(count > 1 ? "s" : "") supprimée\(count > 1 ? "s" : "")."
            : "Aucune dépense à supprimer."
        if count > 0 {
            ApplePayDashboardSync.syncIfNeeded(repository: repository)
        }
    }
}
