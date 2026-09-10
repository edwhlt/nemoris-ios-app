import SwiftUI

/// Menu de configuration Apple Pay : installation du raccourci, alerte de
/// seuil, nettoyage des anciennes entrées.
///
/// État local uniquement (`@State`, pas `AppState`) : ce réglage n'a besoin
/// d'être lu qu'ici et par `ApplePayAlertService`, qui relit
/// `ApplePayAlertSettings` (UserDefaults) directement à chaque déclenchement
/// — même doctrine que `AISettingsView`.
///
/// ⚠️ La résolution automatique à l'ouverture de l'app (moteur → promotion
/// silencieuse en transaction) a été retirée (`ApplePayResolutionService`/
/// `ApplePayResolutionSettings` supprimés) — à revoir plus tard. Seul le
/// nettoyage manuel reste comme moyen d'éviter l'accumulation.
struct ApplePayAlertSettingsView: View {
    @Environment(\.paneDismiss) private var paneDismiss

    /// `true` (défaut) : vue ouverte en pane depuis le Dashboard — porte son
    /// propre `.paneChrome` (bouton "Fermer"). `false` : atteinte en
    /// navigation standard depuis Réglages (`SettingsSection.applePay`), le
    /// wrapper générique de `SettingsView` fournit déjà titre + retour —
    /// ajouter `.paneChrome` ici superposerait un second bouton/titre
    /// (même classe de bug que `.modules`/`.ai`, cf. `SettingsView.settingsSectionPage`).
    var isPane: Bool = true
    /// Masqué depuis le Dashboard (défaut `false` là-bas) : si le bandeau
    /// "en attente" est visible, le raccourci a forcément déjà tourné au
    /// moins une fois pour déposer cette entrée — proposer son installation
    /// à cet endroit n'a pas de sens. Toujours visible depuis Réglages
    /// (`true`, défaut), qui est le point d'entrée pour une 1ère configuration.
    var showsInstallSection: Bool = true

    @State private var isEnabled = ApplePayAlertSettings.isEnabled
    @State private var threshold = ApplePayAlertSettings.threshold
    @State private var period = ApplePayAlertSettings.period

    @State private var purgeOlderThanDays = 30
    @State private var showPurgeConfirmation = false
    @State private var purgeResultMessage: String?

    var body: some View {
        if isPane {
            formContent
                .paneChrome("Apple Pay", cancelLabel: "Fermer", onCancel: { paneDismiss() })
        } else {
            // `.paneChrome` fournit son propre titre côté pane, mais en
            // navigation standard depuis Réglages, `settingsLink` pousse
            // cette destination NUE sur iOS (contrairement à macOS, où
            // `SettingsView.settingsSectionPage` pose `.localizedNavigationTitle`
            // depuis l'extérieur) — sans titre posé ICI, la barre reste vide.
            // Même convention que les autres destinations "plates"
            // (`BackupSettingsView`, etc.), qui le posent toutes elles-mêmes.
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
                        #if os(iOS)
                        UIApplication.shared.open(AppConstants.Shortcuts.applePayInstallURL)
                        #else
                        NSWorkspace.shared.open(AppConstants.Shortcuts.applePayInstallURL)
                        #endif
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
                            Text(p.label).tag(p)
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
