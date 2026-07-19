import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
import TipKit

// MARK: - Document picker cross-platform

#if os(macOS)
/// macOS : NSOpenPanel natif — même API que le wrapper UIKit ci-dessous.
/// Présenté en sheet par les call sites : la vue ouvre le panel à l'apparition
/// puis se dismiss (le panel Mac est une fenêtre système, pas une vue).
struct DocumentPickerView: View {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ProgressView()
            .frame(width: 200, height: 120)
            .onAppear {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = contentTypes
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url {
                    onPick(url)
                }
                dismiss()
            }
    }
}
#else
// UIDocumentPickerViewController wrapper (fiable dans les sheets)
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
    @State private var accounts: [Account] = []
    @State private var tabOrder: [MainTabItem] = []
    @State private var showPaywall = false
    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true
    @AppStorage("nemoris.budgetRedOverPct") private var budgetRedOverPct = 20.0
    private let repository = TransactionRepository()

    var isEmbedded: Bool = false

    var body: some View {
        if isEmbedded { navBody } else { NavigationStack { navBody } }
    }

    @ViewBuilder private var accountPickerOptions: some View {
        Text("Premier disponible").tag(0)
        ForEach(accounts.groupedByType, id: \.type) { group in
            Section(group.type.label) {
                ForEach(group.accounts) { a in
                    Text(a.name).tag(a.id)
                }
            }
        }
    }

    @ViewBuilder private var navBody: some View {
        @Bindable var appState = appState
        // Fond appliqué via .background (borné par le Form) et non via un
        // ZStack avec Color.ignoresSafeArea() gourmand : sur macOS ce dernier
        // rendait le Form infiniment haut (fenêtre étirée + contenu invisible).
        Form {
                // ── Abonnement ────────────────────────────────────────────
                subscriptionSection

                // ── Général ───────────────────────────────────────────────
                Section("Général") {
                    if !accounts.isEmpty {
                        Picker("Compte par défaut", selection: $appState.defaultAccountId) {
                            accountPickerOptions
                        }
                    }
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Sécurité (verrouillage Face ID / Touch ID / code) ────
                appLockSection
                .listRowBackground(AppTheme.Colors.surface)

                // ── Confidentialité (masquage des montants) ──────────────
                privacySection
                .listRowBackground(AppTheme.Colors.surface)

                // ── Modules ───────────────────────────────────────────────
                // Activation des modules optionnels. "Remboursements" est groupé
                // ici car c'est aussi une fonctionnalité activable, pas un réglage de Tricount.
                Section {
                    proToggle(
                        isOn: $appState.showTricount,
                        feature: nil,
                        label: "Tricount",
                        icon: "person.2.fill"
                    )
                    proToggle(
                        isOn: $appState.showInvestments,
                        feature: .investments,
                        label: "Investissements",
                        icon: "chart.line.uptrend.xyaxis"
                    )
                    proToggle(
                        isOn: $appState.showBudget,
                        feature: .budget,
                        label: "Budget & Prévisions",
                        icon: "chart.bar.fill"
                    )
                    // Patrimoine — pas paywallé pour l'instant (feature: nil),
                    // alignement avec Tricount. Promotion possible plus tard.
                    proToggle(
                        isOn: $appState.showPatrimoine,
                        feature: nil,
                        label: "Patrimoine",
                        icon: "house.lodge.fill"
                    )
                    proToggle(
                        isOn: $appState.showSQLConsole,
                        feature: .sqlConsole,
                        label: "Console SQL",
                        icon: "terminal"
                    )
                    Toggle(isOn: $reimbursementsEnabled) {
                        Label("Remboursements", systemImage: "arrow.uturn.left.circle")
                    }
                    .tint(AppTheme.Colors.accent)
                } header: {
                    Text("Modules")
                } footer: {
                    Text("Activez les fonctionnalités que vous souhaitez voir dans l'app.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Investissements ───────────────────────────────────────
                // N'apparaît que si le module Investissements est activé.
                if appState.showInvestments {
                    Section {
                        Toggle(isOn: $appState.investmentsIncludeCashInTotal) {
                            Label("Inclure la trésorerie dans la valorisation", systemImage: "eurosign.circle")
                        }
                        .tint(AppTheme.Colors.accent)
                        Toggle(isOn: $appState.investmentsAutoSyncEnabled) {
                            Label("Synchronisation automatique des cours", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .tint(AppTheme.Colors.accent)
                    } header: {
                        Text("Investissements")
                    } footer: {
                        Text("Si activé, la trésorerie (cash disponible) est ajoutée au gros chiffre de valorisation. Le calcul de performance reste basé uniquement sur les positions, peu importe ce réglage. La synchronisation automatique actualise portefeuilles et cours à l'ouverture de l'app ou du module, au plus toutes les 4 heures.")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    .listRowBackground(AppTheme.Colors.surface)
                }

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

                // ── Budget ────────────────────────────────────────────────
                Section {
                    Stepper(value: $budgetRedOverPct, in: 0...100, step: 5) {
                        HStack {
                            Label("Seuil rouge budget", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text("+\(Int(budgetRedOverPct)) %")
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Text("Budget")
                } footer: {
                    Text("Orange de 0 % à +\(Int(budgetRedOverPct)) % de dépassement, rouge au-delà.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .listRowBackground(AppTheme.Colors.surface)

                Section {
                    ForEach(tabOrder) { tab in
                        HStack {
                            Label(tab.title, systemImage: tab.systemImage)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            if tab == .investments && !store.isUnlocked(.investments) {
                                ProBadge()
                            }
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .font(.subheadline)
                        }
                    }
                    .onMove(perform: moveTab)
                } header: {
                    Text("Ordre des onglets")
                } footer: {
                    Text("Les 4 premiers s'affichent dans la barre du bas. Les suivants vont dans Plus.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .listRowBackground(AppTheme.Colors.surface)
                #if os(iOS)
                // editMode n'existe pas sur macOS — le drag&drop de réordonnancement
                // marche nativement sur Mac sans mode édition.
                .environment(\.editMode, .constant(.active))
                #endif

                // ── Import & Données ──────────────────────────────────────
                Section("Import & Données") {
                    NavigationLink(destination: ImportV3EntryView()) {
                        Label("Importer un CSV…", systemImage: "square.and.arrow.down")
                    }
                    NavigationLink(destination: CompanyDataSourcesSettingsView()) {
                        Label("Sources entreprises", systemImage: "globe.europe.africa.fill")
                    }
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Synchronisation ───────────────────────────────────────
                // Un seul groupe pour les 2 types de sync :
                //   - Synchronisation du fichier de base (iCloud Drive, OneDrive…)
                //   - Synchronisation automatique des positions (exchanges, wallets)
                Section("Sauvegarde & synchronisation") {
                    // Filet de sécurité de base — gratuit, snapshots quotidiens iCloud
                    // (recommandé pour tous les users).
                    NavigationLink(destination: BackupSettingsView()) {
                        Label("Sauvegarde locale & iCloud", systemImage: "icloud.and.arrow.up.fill")
                    }
                    // Sync CloudKit chiffrée multi-appareils (AXE L).
                    NavigationLink(destination: CloudSyncSettingsView()) {
                        HStack {
                            Label("Synchronisation iCloud", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                            Spacer()
                            Text("Bêta")
                                .font(AppTheme.Typography.labelMedium)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                    // Export continu du fichier vers un dossier choisi (Pro).
                    // Volontairement PAS appelé "sync" : c'est un miroir one-way
                    // (app → dossier) pour la portabilité/propriété du fichier —
                    // la vraie sync multi-appareils est CloudSyncSettingsView.
                    NavigationLink(destination: SyncSettingsView()) {
                        HStack {
                            Label("Export continu vers dossier", systemImage: "externaldrive.badge.icloud")
                            Spacer()
                            if !store.isUnlocked(.sync) { ProBadge() }
                        }
                    }
                    if appState.showInvestments {
                        NavigationLink(destination: LiveSyncSettingsView()) {
                            Label("Exchanges & wallets", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Avancé ────────────────────────────────────────────────
                // Regroupe : IA, confidentialité, base de données.
                Section("Avancé") {
                    NavigationLink(destination: AISettingsView()) {
                        Label("Intelligence artificielle", systemImage: "sparkles")
                    }
                    NavigationLink(destination: PrivacyView()) {
                        Label("Données & vie privée", systemImage: "lock.shield")
                    }
                    // Rapport fiscal présenté en sheet (pas un push) — c'est
                    // un outil d'export ponctuel, pas un sous-réglage permanent.
                    NavigationLink(destination: TaxReportView()) {
                        Label("Rapport fiscal France", systemImage: "doc.text.fill")
                    }
                    NavigationLink(destination: AdvancedSettingsView()) {
                        Label("Base de données & Console SQL", systemImage: "gearshape.2")
                    }
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── À propos ──────────────────────────────────────────────
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

                // ── Développeur (DEBUG uniquement) ────────────────────────
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
        #if os(macOS)
        // Sur macOS le Form prend sa largeur intrinsèque (étroite) et se colle
        // au bord : on force le remplissage du volet détail + style grouped natif.
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .navigationTitle("Paramètres")
        .onAppear {
            if DatabaseManager.shared.hasDatabase() {
                accounts = repository.fetchAccounts()
            }
            tabOrder = appState.mainTabOrder
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView().environment(store)
        }
    }

    // MARK: - App Lock Section

    /// Section "Sécurité" : toggle de verrouillage adaptatif (Face ID / Touch ID
    /// / code iOS selon disponibilité). Le label suit ce que le device propose
    /// pour que l'user voie immédiatement ce qui sera utilisé.
    @State private var lockEnabledMirror = UserDefaults.standard.bool(forKey: "appLockEnabled")
    @State private var lockBiometryType: AppLockService.BiometryType = .none
    @State private var showCurrencyConverter = false

    @ViewBuilder private var appLockSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { lockEnabledMirror },
                set: { newValue in
                    // L'auth doit réussir avant d'écrire le flag — sinon on revert
                    // visuellement le toggle. La vue affiche la prompt iOS native.
                    Task {
                        let ok = await AppLockService.shared.setEnabled(newValue)
                        if ok {
                            lockEnabledMirror = newValue
                            appState.postToast(.success,
                                               newValue ? "Verrouillage activé" : "Verrouillage désactivé")
                        } else {
                            // Auth échouée ou annulée → on resync l'état réel.
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

    // MARK: - Privacy Section (masquage des montants)

    @ViewBuilder private var privacySection: some View {
        Section {
            // Toggle direct du masquage. Action immédiate visible partout dans l'app
            // (heros, bandeaux, rows transactions qui utilisent `MoneyText`).
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

            // Mode automatique via détection de l'orientation. Active le
            // `PrivacyMotionMonitor` qui surveille `gravity.z` à 4 Hz.
            Toggle(isOn: Binding(
                get: { appState.hideAmountsOnFaceDown },
                set: {
                    appState.hideAmountsOnFaceDown = $0
                    HapticService.shared.selection()
                    // Synchronise immédiatement le monitor — start/stop selon le nouveau flag.
                    PrivacyMotionMonitor.shared.syncWithSetting()
                }
            )) {
                Label("Retourner l'iPhone pour basculer", systemImage: "iphone.gen3.slash")
            }
            .tint(AppTheme.Colors.accent)

            // Toggle haptiques — Default ON, désactivable explicitement
            Toggle(isOn: Binding(
                get: { appState.hapticsEnabled },
                set: { newValue in
                    appState.hapticsEnabled = newValue
                    // Donne un dernier tap pour confirmer le changement avant désactivation
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
            .sheet(isPresented: $showCurrencyConverter) {
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
                        Button("Passer Pro") { showPaywall = true }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                LinearGradient(
                                    colors: [AppTheme.Colors.accent, AppTheme.Colors.accentSecondary],
                                    startPoint: .leading, endPoint: .trailing
                                ),
                                in: Capsule()
                            )
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
                    Button("Gérer l'abonnement") {
                        if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
                            #if os(iOS)
                            UIApplication.shared.open(url)
                            #else
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                    }
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        } header: {
            Text("Abonnement")
        }
        .listRowBackground(AppTheme.Colors.surface)
    }
    
    // MARK: - Pro Toggle Helper

    @ViewBuilder
    private func proToggle(isOn: Binding<Bool>, feature: AppFeature?, label: String, icon: String) -> some View {
        // `feature == nil` = feature gratuite, pas de paywall → toggle normal.
        // `feature != nil` et unlocked → toggle normal.
        // `feature != nil` et locked → bouton paywall.
        let isUnlocked = feature.map { store.isUnlocked($0) } ?? true
        if isUnlocked {
            Toggle(isOn: isOn) {
                Label(label, systemImage: icon)
            }
            .tint(AppTheme.Colors.accent)
        } else {
            Button {
                showPaywall = true
            } label: {
                HStack {
                    Label(label, systemImage: icon)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Spacer()
                    Text("Pro")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            LinearGradient(
                                colors: [AppTheme.Colors.accent, AppTheme.Colors.accentSecondary],
                                startPoint: .leading, endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
    }

    private func moveTab(from source: IndexSet, to destination: Int) {
        tabOrder.move(fromOffsets: source, toOffset: destination)
        appState.mainTabOrder = tabOrder
    }
}

// MARK: - SyncSettingsView

struct SyncSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var store
    @State private var showSyncFolderPicker = false
    @State private var syncFolderName: String? = SyncService.shared.destinationFolderName
    @State private var syncErrorMessage: String?
    @State private var lastSyncDate: Date? = SyncService.shared.lastSyncDate
    @State private var lastSyncSuccess: Bool? = SyncService.shared.lastSyncSuccess

    var body: some View {
        Form {
            Section {
                if let name = syncFolderName {
                    LabeledContent("Dossier") {
                        Text(name)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }

                    if let date = lastSyncDate {
                        LabeledContent("Dernière sync") {
                            HStack(spacing: 4) {
                                Image(systemName: lastSyncSuccess == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(lastSyncSuccess == true ? AppTheme.Colors.success : AppTheme.Colors.danger)
                                    .font(.caption)
                                Text(date, style: .relative)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                    .font(.caption)
                            }
                        }
                    }

                    Button {
                        let ok = SyncService.shared.sync()
                        lastSyncDate = SyncService.shared.lastSyncDate
                        lastSyncSuccess = ok
                        appState.postToast(ok ? .success : .error,
                                           ok ? "Sauvegarde envoyée" : "Échec de la sauvegarde")
                    } label: {
                        Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .tint(AppTheme.Colors.accent)

                    Button("Changer de dossier…") {
                        showSyncFolderPicker = true
                    }
                    .tint(AppTheme.Colors.accent)

                    Button("Désactiver la synchronisation", role: .destructive) {
                        SyncService.shared.removeDestination()
                        syncFolderName = nil
                        lastSyncDate = nil
                        lastSyncSuccess = nil
                        syncErrorMessage = nil
                        appState.postToast(.info, "Synchronisation désactivée")
                    }
                } else {
                    Text("Choisissez un dossier (iCloud Drive, OneDrive, local…) vers lequel la base sera automatiquement copiée.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .font(.caption)

                    Button("Choisir un dossier de sync…") {
                        showSyncFolderPicker = true
                    }
                    .tint(AppTheme.Colors.accent)
                }

                if let err = syncErrorMessage {
                    Text(err).foregroundStyle(AppTheme.Colors.danger).font(.caption)
                }
            } header: {
                Text("Dossier de destination")
            } footer: {
                if syncFolderName != nil {
                    Text("La base est copiée automatiquement dans ce dossier à chaque modification et quand l'application passe en arrière-plan.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .navigationTitle("Synchronisation")
        .navigationBarTitleDisplayMode(.large)
        .paywallOverlay(for: .sync)
        .sheet(isPresented: $showSyncFolderPicker) {
            DocumentPickerView(contentTypes: [.folder]) { url in
                showSyncFolderPicker = false
                do {
                    try SyncService.shared.setDestination(from: url)
                    syncFolderName = SyncService.shared.destinationFolderName
                    lastSyncDate = SyncService.shared.lastSyncDate
                    lastSyncSuccess = SyncService.shared.lastSyncSuccess
                    syncErrorMessage = nil
                } catch {
                    syncErrorMessage = error.localizedDescription
                }
            }
            .ignoresSafeArea()
        }
    }
}

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
            // MARK: Base de données
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
                    showSQLFolderPicker = true
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

            // MARK: Aide
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
        .navigationTitle("Avancé")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showSQLFolderPicker) {
            DocumentPickerView(contentTypes: [.folder]) { url in
                showSQLFolderPicker = false
                do {
                    try SQLConsoleHelper.linkFolder(from: url)
                    linkedSQLFolderName = SQLConsoleHelper.linkedFolderName
                    sqlFolderErrorMessage = nil
                } catch {
                    sqlFolderErrorMessage = error.localizedDescription
                }
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - PrivacyView

struct PrivacyView: View {
    var body: some View {
        List {
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
        .background(AppTheme.Colors.background)
        .navigationTitle("Confidentialité")
        .navigationBarTitleDisplayMode(.large)
    }
}
