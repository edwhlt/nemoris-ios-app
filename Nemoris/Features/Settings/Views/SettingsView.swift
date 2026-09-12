import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
import TipKit

// MARK: - Document picker cross-platform

#if os(macOS)
/// Opens an `NSOpenPanel` DIRECTLY from an action (a button), without going
/// through a sheet.
///
/// On Mac, picking a file/folder is a system window, not a view:
/// routing it through a `.sheet` that fires `runModal()` in its `onAppear`
/// nests a modal loop inside a presentation that's still in progress —
/// the panel didn't open ("Change folder…" had no effect). Called
/// from the action, there's no longer a concurrent presentation.
@MainActor
func presentOpenPanel(contentTypes: [UTType], onPick: @escaping (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    // A folder can NOT be picked via `allowedContentTypes = [.folder]` (the
    // "Open" button stays disabled): `canChooseDirectories` is required.
    if contentTypes.contains(.folder) {
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
    } else {
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = contentTypes
    }
    // An ASYNCHRONOUS presentation attached to the window rather than `runModal()`:
    // launching a nested modal loop from a SwiftUI action didn't return
    // control (the panel never showed — no bookmark was ever
    // saved). `beginSheetModal` returns immediately and calls back on the choice.
    let handler: (NSApplication.ModalResponse) -> Void = { response in
        guard response == .OK, let url = panel.url else { return }
        onPick(url)
    }
    if let window = NSApp.keyWindow ?? NSApp.mainWindow {
        panel.beginSheetModal(for: window, completionHandler: handler)
    } else {
        panel.begin(completionHandler: handler)
    }
}

/// macOS: a native NSOpenPanel — the same API as the UIKit wrapper below.
/// ⚠️ Prefer `presentOpenPanel` (called directly from the action): presenting this
/// wrapper as a sheet nests a modal loop inside an ongoing presentation.
struct DocumentPickerView: View {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ProgressView()
            .frame(width: 200, height: 120)
            .onAppear {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                // A folder can NOT be selected via allowedContentTypes = [.folder]
                // (the "Open" button then stays disabled, hence "Change
                // folder" doing nothing): canChooseDirectories = true is required. It
                // adapts based on what's requested (a folder vs. a file).
                if contentTypes.contains(.folder) {
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                } else {
                    panel.canChooseDirectories = false
                    panel.canChooseFiles = true
                    panel.allowedContentTypes = contentTypes
                }
                if panel.runModal() == .OK, let url = panel.url {
                    onPick(url)
                }
                dismiss()
            }
    }
}
#else
// UIDocumentPickerViewController wrapper (reliable inside sheets)
struct DocumentPickerView: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
#endif

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var store
    @State private var showPaywall = false

    var isEmbedded: Bool = false

    #if os(macOS)
    /// An open sub-section, via STATE-DRIVEN navigation (not a push).
    ///
    /// A `NavigationLink` stacks the destination onto the module's
    /// `NavigationStack`; on macOS that stacking isn't undone when switching
    /// modules from the sidebar: the app ended up stuck in "Settings › Advanced"
    /// while the sidebar already highlighted "Data". The same fix as for
    /// Investments and Tricount: the sub-section REPLACES the module's
    /// content, with its own back button.
    @State private var pushedSection: SettingsSection?
    /// To close the pane by returning to the settings list.
    @Environment(InspectorPaneCenter.self) private var paneCenter: InspectorPaneCenter?
    #endif

    var body: some View {
        #if os(macOS)
        if let section = pushedSection {
            settingsSectionPage(section)
        } else if isEmbedded {
            navBody
        } else {
            NavigationStack { navBody }
        }
        #else
        if isEmbedded { navBody } else { NavigationStack { navBody } }
        #endif
    }

    #if os(macOS)
    /// A full-page sub-section + a way back to the settings list.
    ///
    /// ⚠️ `.modules` and `.ai` are SPECIAL cases: `ModulesSettingsView` and
    /// `AISettingsView` each have their OWN internal navigation (list →
    /// sub-page), so their own back button. Stacking a
    /// second generic back button HERE on top produces two chevrons stacked in
    /// the same bar — the two `.toolbar`s (this one + the sub-page's)
    /// merge instead of replacing each other. These two views therefore receive
    /// `onBack` and manage all of their own chrome, exactly like
    /// `DashboardCustomizeView`.
    @ViewBuilder
    private func settingsSectionPage(_ section: SettingsSection) -> some View {
        if section == .modules {
            ModulesSettingsView(onBack: {
                paneCenter?.dismissCurrent()
                pushedSection = nil
            })
        } else if section == .ai {
            AISettingsView(onBack: {
                paneCenter?.dismissCurrent()
                pushedSection = nil
            })
        } else {
            section.destination
                // ⚠️ Explicit resolution, never `LocalizedStringKey(...)`:
                // `.navigationTitle` bridges to native chrome (the macOS
                // title bar), which doesn't reliably respect the app-forced
                // `\.locale`. See CLAUDE.md §5.
                .localizedNavigationTitle(section.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            paneCenter?.dismissCurrent()
                            pushedSection = nil
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .localizedHelp("Réglages")
                        .localizedAccessibilityLabel("Réglages")
                    }
                }
        }
    }

    #endif

    /// A row leading to a sub-section: state-driven navigation on macOS (a push
    /// there desynchronizes the sidebar), a classic `NavigationLink` on iOS. The
    /// chevron is added by hand on the macOS side for an identical look.
    @ViewBuilder
    private func settingsLink(_ section: SettingsSection, @ViewBuilder label: () -> some View) -> some View {
        #if os(macOS)
        Button {
            pushedSection = section
        } label: {
            HStack {
                label()
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #else
        NavigationLink(destination: section.destination) { label() }
        #endif
    }

    @ViewBuilder private var navBody: some View {
        @Bindable var appState = appState
        // The background applied via .background (bounded by the Form) rather than a
        // ZStack with a greedy Color.ignoresSafeArea(): on macOS the latter
        // made the Form infinitely tall (a stretched window + invisible content).
        Form {
                // ── Abonnement ────────────────────────────────────────────
                subscriptionSection

                // ⚠️ The default account (formerly "General") has moved into
                // "Modules & navigation → Transactions settings": it's
                // a setting specific to the Transactions module, on the same footing as
                // the budget threshold or Investments' cash — no
                // reason for it to live elsewhere.

                // ── Security (Face ID / Touch ID / passcode lock) ────────
                appLockSection
                .listRowBackground(AppTheme.Colors.surface)

                // ── Privacy (amount masking) ──────────────────────────────
                privacySection
                .listRowBackground(AppTheme.Colors.surface)

                // ── Modules ───────────────────────────────────────────────
                // Enabling, ordering AND a module's specific settings are
                // grouped in ONE SINGLE dedicated screen (`ModulesSettingsView`) —
                // the three questions ("is this module active", "where
                // does it appear", "does it have its own setting") apply to the
                // same row, there's no reason for them to live in different
                // places. It's also what fixes reordering on
                // Mac: `ModulesSettingsView` reuses `DashboardCustomizeView`'s isolated
                // `Form`, the only drag&drop pattern validated on
                // macOS in the app — nested among a dozen other
                // sections as before, macOS drag-and-drop never engaged.
                Section {
                    settingsLink(.modules) {
                        Label("Modules & navigation", systemImage: "square.grid.2x2.fill")
                    }
                } header: {
                    Text("Modules")
                } footer: {
                    Text("Activez, réordonnez et configurez les modules de l'app.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Personnalisation ──────────────────────────────────────
                Section("Personnalisation") {
                    Picker("Thème", selection: $appState.colorSchemeRaw) {
                        Text("Système").tag("system")
                        Text("Clair").tag("light")
                        Text("Sombre").tag("dark")
                    }
                    .pickerStyle(.segmented)

                    Picker("Langue", selection: $appState.preferredLanguage) {
                        Text("Système").tag("system")
                        Text("Français").tag("fr")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Data ──────────────────────────────────────────────────
                // ⚠️ The "Import" entry was REMOVED from here: it
                // also existed in the main navigation, and two paths
                // to the same screen made it look like two different
                // imports. A single access point, the one in the menu.
                Section("Données") {
                    settingsLink(.companySources) {
                        Label("Sources entreprises", systemImage: "globe.europe.africa.fill")
                    }
                    // A setting specific to the Apple Pay automation (Shortcuts):
                    // installing the shortcut, the threshold + period of the
                    // "pending expenses" alert, cleaning up old entries.
                    settingsLink(.applePay) {
                        Label("Alertes Apple Pay", systemImage: "bell.badge")
                    }
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Sync ──────────────────────────────────────────────────
                // Syncing the database file (iCloud Drive, OneDrive…).
                // Syncing exchanges/wallets is NO LONGER here since
                // 2026-08-08: it isn't a global setting, it's specific to
                // the Investments module — each link is attached to an account
                // and managed from ITS OWN sheet (a "Link an exchange /
                // wallet" toolbar for a new account, a "Sync" section of
                // an existing account's sheet).
                Section("Sauvegarde & synchronisation") {
                    // Basic safety net — free, daily iCloud snapshots
                    // (recommended for every user).
                    settingsLink(.backup) {
                        Label("Sauvegarde locale & iCloud", systemImage: "icloud.and.arrow.up.fill")
                    }
                    // Encrypted multi-device CloudKit sync.
                    settingsLink(.cloudSync) {
                        HStack {
                            Label("Synchronisation iCloud", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                            Spacer()
                            Text("Bêta")
                                .font(AppTheme.Typography.labelMedium)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                    // (The continuous export to a folder was removed 2026-07-26 — redundant
                    //  with BackupService's iCloud snapshots, which are already
                    //  raw .sqlite files reachable in Files and survive
                    //  uninstallation. Multi-cloud will come on the BackupService side.)
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Advanced ──────────────────────────────────────────────
                // Groups: AI, privacy, database.
                Section("Avancé") {
                    settingsLink(.ai) {
                        Label("Intelligence artificielle", systemImage: "sparkles")
                    }
                    settingsLink(.privacy) {
                        Label("Données & vie privée", systemImage: "lock.shield")
                    }
                    // The tax report is presented as a sheet (not a push) — it's
                    // a one-off export tool, not a permanent sub-setting.
                    settingsLink(.taxReport) {
                        Label("Rapport fiscal France", systemImage: "doc.text.fill")
                    }
                    settingsLink(.advanced) {
                        Label("Base de données & Console SQL", systemImage: "gearshape.2")
                    }
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── About ─────────────────────────────────────────────────
                Section("À propos") {
                    LabeledContent("Version") {
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    LabeledContent("Build") {
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Developer (DEBUG only) ────────────────────────────────
                #if DEBUG
                Section {
                    @Bindable var store = store
                    Toggle(isOn: Binding(
                        get: { store.devOverrideEnabled },
                        set: { store.devOverrideEnabled = $0 }
                    )) {
                        Label("Mode Lifetime (dev)", systemImage: "hammer.fill")
                    }
                    .tint(AppTheme.Colors.warning)
                } header: {
                    Text("Développeur")
                } footer: {
                    Text("Visible uniquement en Debug. Force l'accès Lifetime sans achat réel.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .listRowBackground(AppTheme.Colors.surface)
                #endif
        }
        .scrollContentBackground(.hidden)
        .tint(AppTheme.Colors.accent)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .localizedNavigationTitle("Paramètres")
        .adaptivePane(isPresented: $showPaywall) {
            PaywallView().environment(store)
        }
    }

    // MARK: - App Lock Section

    /// "Security" section: an adaptive lock toggle (Face ID / Touch ID
    /// / iOS passcode depending on availability). The label follows what the
    /// device offers so the user immediately sees what will be used.
    @State private var lockEnabledMirror = UserDefaults.standard.bool(forKey: "appLockEnabled")
    @State private var lockBiometryType: AppLockService.BiometryType = .none
    @State private var showCurrencyConverter = false

    @ViewBuilder private var appLockSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { lockEnabledMirror },
                set: { newValue in
                    // Auth must succeed before the flag is written — otherwise the
                    // toggle visually reverts. The view shows the native iOS prompt.
                    Task {
                        let ok = await AppLockService.shared.setEnabled(newValue)
                        if ok {
                            lockEnabledMirror = newValue
                            appState.postToast(.success,
                                               newValue ? "Verrouillage activé" : "Verrouillage désactivé")
                        } else {
                            // Auth failed or canceled → resync to the real state.
                            lockEnabledMirror = AppLockService.shared.isLockEnabled
                            if lockBiometryType == .none {
                                appState.postToast(.warning, "Configurez un code d'accès iOS pour activer le verrouillage")
                            }
                        }
                    }
                }
            )) {
                Label("Verrouillage \(lockBiometryType.displayName)", systemImage: lockBiometryType.systemIcon)
            }
            .tint(AppTheme.Colors.accent)
            .disabled(lockBiometryType == .none)
        } header: {
            Text("Sécurité")
        } footer: {
            if lockBiometryType == .none {
                Text("Aucune biométrie ni code d'accès n'est configuré sur cet appareil. Activez Face ID, Touch ID ou un code d'accès dans Réglages iOS pour utiliser cette fonctionnalité.")
                    .font(AppTheme.Typography.bodySmall)
            } else {
                Text("Nemoris demandera \(lockBiometryType.displayName) à chaque ouverture et chaque retour depuis l'arrière-plan. Vos données ne sont jamais transmises lors de l'authentification — tout est géré par iOS en local.")
                    .font(AppTheme.Typography.bodySmall)
            }
        }
        .onAppear {
            lockBiometryType = AppLockService.shared.biometryType
            lockEnabledMirror = AppLockService.shared.isLockEnabled
        }
    }

    // MARK: - Privacy Section (amount masking)

    @ViewBuilder private var privacySection: some View {
        Section {
            // A direct toggle for masking. The action is immediately visible
            // everywhere in the app (heroes, banners, transaction rows using `MoneyText`).
            Toggle(isOn: Binding(
                get: { appState.amountsHidden },
                set: { appState.amountsHidden = $0 }
            )) {
                Label(
                    appState.amountsHidden ? "Montants masqués" : "Masquer les montants",
                    systemImage: appState.amountsHidden ? "eye.slash.fill" : "eye.fill"
                )
            }
            .tint(AppTheme.Colors.accent)

            // Automatic mode via orientation detection. Activates the
            // `PrivacyMotionMonitor`, which watches `gravity.z` at 4 Hz.
            Toggle(isOn: Binding(
                get: { appState.hideAmountsOnFaceDown },
                set: {
                    appState.hideAmountsOnFaceDown = $0
                    HapticService.shared.selection()
                    // Syncs the monitor immediately — start/stop based on the new flag.
                    PrivacyMotionMonitor.shared.syncWithSetting()
                }
            )) {
                Label("Retourner l'iPhone pour basculer", systemImage: "iphone.gen3.slash")
            }
            .tint(AppTheme.Colors.accent)

            // Haptics toggle — Default ON, can be explicitly disabled
            Toggle(isOn: Binding(
                get: { appState.hapticsEnabled },
                set: { newValue in
                    appState.hapticsEnabled = newValue
                    // Gives one last tap to confirm the change before disabling
                    if newValue { HapticService.shared.success() }
                }
            )) {
                Label("Retours haptiques", systemImage: "hand.tap.fill")
            }
            .tint(AppTheme.Colors.accent)

            // Convertisseur de devises — ouvert en sheet (calculatrice ad-hoc).
            Button {
                showCurrencyConverter = true
            } label: {
                HStack {
                    Label("Convertisseur de devises", systemImage: "arrow.left.arrow.right.circle")
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
            }
            .adaptivePane(isPresented: $showCurrencyConverter) {
                CurrencyConverterSheet().environment(appState)
            }
        } header: {
            Text("Confidentialité")
        } footer: {
            Text("Le masquage manuel se réinitialise au redémarrage de l'app. Quand le geste est activé, poser l'iPhone face cachée bascule l'affichage des montants. Le relever ne change rien — l'état reste actif jusqu'au prochain geste.")
                .font(AppTheme.Typography.bodySmall)
        }
    }

    // MARK: - Subscription Section

    private var subscriptionSection: some View {
        Section {
            VStack(spacing: AppTheme.Spacing.sm) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(
                                store.accessLevel == .free
                                    ? AnyShapeStyle(AppTheme.Colors.surface)
                                    : AnyShapeStyle(LinearGradient(
                                        colors: [Color(hex: "FFD700").opacity(0.8), Color(hex: "FF8C00")],
                                        startPoint: .topLeading, endPoint: .bottomTrailing
                                    ))
                            )
                            .frame(width: 44, height: 44)
                        Image(systemName: store.accessLevel == .free ? "lock.fill" : "crown.fill")
                            .font(.title3)
                            .foregroundStyle(store.accessLevel == .free ? AppTheme.Colors.textSecondary : .white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.accessLevel == .free ? "Finance Gratuit" : "Finance \(store.accessLevel.label)")
                            .font(.headline)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Text(store.accessLevel == .free
                             ? "Transactions et dashboard de base"
                             : "Toutes les fonctionnalités débloquées")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }

                    Spacer()

                    if store.accessLevel == .free {
                        // A solid fill (no gradient): the same recipe as ProBadge and
                        // every other capsule CTA in the app (accent.Colors.accent
                        // alone). A gradient toward accentSecondary — copper deliberately
                        // FIXED between themes (see AppTheme.swift) — clashed with
                        // the accent green, which itself becomes much lighter in dark
                        // mode: the unchanged copper read as a dull brown there.
                        Button("Passer Pro") { showPaywall = true }
                            .buttonStyle(.plain)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(AppTheme.Colors.accent, in: Capsule())
                    }
                }
                .padding(.vertical, 4)

                if store.accessLevel == .free {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Image(systemName: "crown.fill")
                                .foregroundStyle(Color(hex: "FFD700"))
                            Text("Voir les offres Pro")
                                .fontWeight(.medium)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    }
                } else {
                    // "Change plan" opens the same Paywall as the initial purchase —
                    // it adapts on its own (the current plan marked, monthly ↔ yearly
                    // via StoreKit's native crossgrade, a dedicated state if Lifetime). "Manage
                    // subscription" stays the way out to Apple to cancel or change
                    // the payment method, which StoreKit doesn't expose from within the app.
                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Text("Changer de formule")
                                .fontWeight(.medium)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    }
                    Button("Gérer l'abonnement") {
                        #if os(iOS)
                        UIApplication.shared.open(AppConstants.Store.manageSubscriptionsURL)
                        #else
                        NSWorkspace.shared.open(AppConstants.Store.manageSubscriptionsURL)
                        #endif
                    }
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        } header: {
            Text("Abonnement")
        }
        .listRowBackground(AppTheme.Colors.surface)
    }
    
}

// (SyncSettingsView + SyncService removed 2026-07-26 — the continuous one-way
//  export to a folder was redundant with BackupService's iCloud snapshots
//  and had a false-security trap: the folder's bookmark lived in
//  UserDefaults, erased on uninstall → the export silently stopped.)

// MARK: - AdvancedSettingsView

struct AdvancedSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var store
    @State private var showSQLFolderPicker = false
    @State private var linkedSQLFolderName: String? = SQLConsoleHelper.linkedFolderName
    @State private var sqlFolderErrorMessage: String?
    @State private var migrationError: String? = nil
    @State private var migrationSuccess: Bool = false

    var body: some View {
        Form {
            // MARK: Database
            Section {
                LabeledContent("Version du schéma") {
                    Text("v\(DatabaseManager.shared.schemaVersion)")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Button("Relancer les migrations") {
                    let error = DatabaseManager.shared.migrateIfNeeded()
                    migrationError = error
                    migrationSuccess = (error == nil)
                    if let error {
                        appState.postToast(.error, "Migration échouée : \(error)")
                    } else {
                        appState.postToast(.success, "Migrations à jour (v\(DatabaseManager.shared.schemaVersion))")
                    }
                }
                .tint(AppTheme.Colors.accent)
                if let err = migrationError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.danger)
                } else if migrationSuccess {
                    Text("Migrations à jour (v\(DatabaseManager.shared.schemaVersion))")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.success)
                }
            } header: {
                Text("Base de données")
            }

            // MARK: Scripts SQL
            Section {
                if let name = linkedSQLFolderName {
                    LabeledContent("Dossier actif") {
                        Text(name)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Réinitialiser le dossier", role: .destructive) {
                        SQLConsoleHelper.unlinkFolder()
                        linkedSQLFolderName = nil
                        sqlFolderErrorMessage = nil
                    }
                } else {
                    Text("Dossier par défaut : Documents/SQLRequests/")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .font(.caption)
                }

                Button("Changer le dossier…") {
                    #if os(macOS)
                    // The system panel opened directly (see `presentOpenPanel`).
                    presentOpenPanel(contentTypes: [.folder]) { url in
                        applyPickedSQLFolder(url)
                    }
                    #else
                    showSQLFolderPicker = true
                    #endif
                }
                .tint(AppTheme.Colors.accent)

                if let err = sqlFolderErrorMessage {
                    Text(err).foregroundStyle(AppTheme.Colors.danger).font(.caption)
                }
            } header: {
                Text("Scripts SQL")
            } footer: {
                if linkedSQLFolderName != nil {
                    Text("Les fichiers .sql seront lus et créés dans ce dossier.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            // MARK: Help
            Section {
                Button {
                    try? Tips.resetDatastore()
                    try? Tips.configure([
                        .datastoreLocation(.applicationDefault),
                        .displayFrequency(.immediate)
                    ])
                    appState.postToast(.success, "Conseils réinitialisés")
                } label: {
                    Label("Réafficher tous les conseils", systemImage: "lightbulb")
                }
                .tint(AppTheme.Colors.accent)
            } header: {
                Text("Aide")
            } footer: {
                Text("Les bulles d'aide sont affichées une seule fois. Appuyez ici pour les réinitialiser.")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .nemorisFormStyle()
        .localizedNavigationTitle("Avancé")
        .navigationBarTitleDisplayMode(.large)
        // iOS: the picker as a sheet (the UIKit controller IS a view). macOS: the
        // system panel opened directly from the action (see `presentOpenPanel`).
        #if !os(macOS)
        .sheet(isPresented: $showSQLFolderPicker) {
            DocumentPickerView(contentTypes: [.folder]) { url in
                showSQLFolderPicker = false
                applyPickedSQLFolder(url)
            }
            .ignoresSafeArea()
        }
        #endif
    }

    /// Saves the chosen folder (shared by both platforms).
    private func applyPickedSQLFolder(_ url: URL) {
        do {
            try SQLConsoleHelper.linkFolder(from: url)
            linkedSQLFolderName = SQLConsoleHelper.linkedFolderName
            sqlFolderErrorMessage = nil
        } catch {
            sqlFolderErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - PrivacyView

struct PrivacyView: View {
    var body: some View {
        // A Form (not a List): static content → native rounded macOS boxes via
        // nemorisFormStyle(), rendered identically on iOS.
        Form {
            Section {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Colors.accent.opacity(0.15))
                            .frame(width: 44, height: 44)
                        Image(systemName: "iphone")
                            .font(.title3)
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Données stockées localement")
                            .fontWeight(.semibold)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Text("Toutes vos données financières restent sur votre appareil.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Vos données")
            }
            .listRowBackground(AppTheme.Colors.surface)

            Section {
                Label("Aucune donnée envoyée à des serveurs externes.", systemImage: "xmark.icloud")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Label("Aucun compte utilisateur requis.", systemImage: "person.slash")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Label("Aucun traceur ni publicité.", systemImage: "eye.slash")
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            } header: {
                Text("Ce que nous ne faisons pas")
            }
            .listRowBackground(AppTheme.Colors.surface)

            Section {
                Text("La synchronisation (optionnelle) copie votre base de données vers le dossier de votre choix — iCloud Drive, OneDrive, ou tout autre stockage local. Vous seul contrôlez où vont vos données.")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            } header: {
                Text("Synchronisation")
            }
            .listRowBackground(AppTheme.Colors.surface)

            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                LabeledContent("Build") {
                    Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            } header: {
                Text("Application")
            }
            .listRowBackground(AppTheme.Colors.surface)
        }
        .scrollContentBackground(.hidden)
        .nemorisFormStyle()
        .background(AppTheme.Colors.background)
        .localizedNavigationTitle("Confidentialité")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Settings sub-sections

/// Settings destinations. On macOS they REPLACE the module's content
/// (see `SettingsView.pushedSection`) — a push there isn't undone when
/// switching modules and desynchronizes the sidebar. On iOS, a classic push.
enum SettingsSection: String, Identifiable, CaseIterable {
    case modules, importCSV, companySources, backup, cloudSync
    case ai, privacy, taxReport, advanced, applePay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modules:         return "Modules & navigation"
        case .importCSV:       return "Importation"
        case .companySources:  return "Sources entreprises"
        case .backup:          return "Sauvegarde locale & iCloud"
        case .cloudSync:       return "Synchronisation iCloud"
        case .ai:              return "Intelligence artificielle"
        case .privacy:         return "Données & vie privée"
        case .taxReport:       return "Rapport fiscal France"
        case .advanced:        return "Base de données & Console SQL"
        case .applePay:        return "Apple Pay"
        }
    }

    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .modules:         ModulesSettingsView()
        case .importCSV:       ImportEntryView(isEmbedded: true)
        case .companySources:  CompanyDataSourcesSettingsView()
        case .backup:          BackupSettingsView()
        case .cloudSync:       CloudSyncSettingsView()
        case .ai:              AISettingsView()
        case .privacy:         PrivacyView()
        case .taxReport:       TaxReportView()
        case .advanced:        AdvancedSettingsView()
        // `isPane: false`: reached via standard navigation here, not as a pane
        // (see `ApplePayAlertSettingsView`'s docs) — without this it would set
        // its own `.paneChrome` on top of the title/back button already provided
        // by `settingsSectionPage`.
        case .applePay:        ApplePayAlertSettingsView(isPane: false)
        }
    }
}
