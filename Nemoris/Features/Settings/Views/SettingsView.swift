import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif
import TipKit

// MARK: - Document picker cross-platform

#if os(macOS)
/// Ouvre un `NSOpenPanel` DIRECTEMENT depuis une action (bouton), sans passer
/// par une sheet.
///
/// Sur Mac, choisir un fichier/dossier est une fenêtre système, pas une vue :
/// la router via une `.sheet` qui lance `runModal()` dans son `onAppear`
/// imbrique une boucle modale dans une présentation de sheet encore en cours —
/// le panneau ne s'ouvrait pas (« Changer le dossier… » sans effet). Appelé
/// depuis l'action, il n'y a plus de présentation concurrente.
@MainActor
func presentOpenPanel(contentTypes: [UTType], onPick: @escaping (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    // Un dossier ne se choisit PAS via `allowedContentTypes = [.folder]` (le
    // bouton « Ouvrir » reste désactivé) : il faut `canChooseDirectories`.
    if contentTypes.contains(.folder) {
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
    } else {
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = contentTypes
    }
    // Présentation ASYNCHRONE attachée à la fenêtre plutôt que `runModal()` :
    // lancer une boucle modale imbriquée depuis une action SwiftUI ne rendait
    // pas la main (le panneau ne s'affichait pas — aucun signet n'était jamais
    // enregistré). `beginSheetModal` rend immédiatement et rappelle au choix.
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

/// macOS : NSOpenPanel natif — même API que le wrapper UIKit ci-dessous.
/// ⚠️ Préférer `presentOpenPanel` (appel direct depuis l'action) : présenter ce
/// wrapper en sheet imbrique une boucle modale dans une présentation en cours.
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
                // Un dossier ne se sélectionne PAS via allowedContentTypes = [.folder]
                // (le bouton "Ouvrir" reste alors désactivé, d'où le "Changer le
                // dossier" inopérant) : il faut canChooseDirectories = true. On
                // adapte selon la nature demandée (dossier vs fichier).
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
    @State private var showPaywall = false

    var isEmbedded: Bool = false

    #if os(macOS)
    /// Sous-section ouverte, en navigation PAR ÉTAT (pas un push).
    ///
    /// Un `NavigationLink` empile la destination dans la `NavigationStack` du
    /// module ; sur macOS cet empilement n'est pas défait quand on change de
    /// module depuis la sidebar : on se retrouvait dans « Réglages › Avancé »
    /// alors que la sidebar surlignait déjà « Données ». Même remède que pour
    /// Investissements et Tricount : la sous-section REMPLACE le contenu du
    /// module, avec son propre retour.
    @State private var pushedSection: SettingsSection?
    /// Pour fermer le panneau en revenant à la liste des réglages.
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
    /// Une sous-section en pleine page + retour vers la liste des réglages.
    ///
    /// ⚠️ `.modules` et `.ai` sont des cas À PART : `ModulesSettingsView` et
    /// `AISettingsView` ont chacune leur PROPRE navigation interne (liste →
    /// sous-page), donc leur propre bouton retour. Leur superposer ICI un
    /// second bouton retour générique produit deux chevrons empilés dans la
    /// même barre — les deux `.toolbar` (celui-ci + celui de la sous-page)
    /// fusionnent au lieu de se remplacer. Ces deux vues reçoivent donc
    /// `onBack` et gèrent tout leur chrome elles-mêmes, exactement comme
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
                // ⚠️ Résolution explicite, jamais `LocalizedStringKey(...)` :
                // `.navigationTitle` ponte vers la chrome native (barre de
                // titre macOS), qui ne respecte pas fiablement `\.locale`
                // forcé par l'app. Cf. CLAUDE.md §5.
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

    /// Row menant à une sous-section : navigation par ÉTAT sur macOS (le push
    /// y désynchronise la sidebar), `NavigationLink` classique sur iOS. Le
    /// chevron est ajouté à la main côté macOS pour un rendu identique.
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
        // Fond appliqué via .background (borné par le Form) et non via un
        // ZStack avec Color.ignoresSafeArea() gourmand : sur macOS ce dernier
        // rendait le Form infiniment haut (fenêtre étirée + contenu invisible).
        Form {
                // ── Abonnement ────────────────────────────────────────────
                subscriptionSection

                // ⚠️ Le compte par défaut ("Général" avant) a déménagé dans
                // « Modules & navigation → Réglages de Transactions » : c'est
                // un réglage propre au module Transactions, au même titre que
                // le seuil budget ou la trésorerie des Investissements — pas
                // de raison qu'il vive ailleurs.

                // ── Sécurité (verrouillage Face ID / Touch ID / code) ────
                appLockSection
                .listRowBackground(AppTheme.Colors.surface)

                // ── Confidentialité (masquage des montants) ──────────────
                privacySection
                .listRowBackground(AppTheme.Colors.surface)

                // ── Modules ───────────────────────────────────────────────
                // Activation, ordre ET réglages spécifiques d'un module sont
                // regroupés dans UN SEUL écran dédié (`ModulesSettingsView`) —
                // les trois questions ("ce module est-il actif", "où
                // apparaît-il", "a-t-il un réglage propre") portent sur la
                // même ligne, elles n'ont pas de raison de vivre à des endroits
                // différents. C'est aussi ce qui répare le réordonnancement sur
                // Mac : `ModulesSettingsView` reprend le `Form` isolé de
                // `DashboardCustomizeView`, seul pattern de drag&drop validé sur
                // macOS dans l'app — imbriqué parmi une douzaine d'autres
                // sections comme avant, le glisser-déposer macOS n'amorçait pas.
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

                // ── Données ───────────────────────────────────────────────
                // ⚠️ L'entrée « Importation » a été RETIRÉE d'ici : elle
                // existait aussi dans la navigation principale, et deux chemins
                // vers le même écran laissaient croire à deux imports
                // différents. Un seul accès, celui du menu.
                Section("Données") {
                    settingsLink(.companySources) {
                        Label("Sources entreprises", systemImage: "globe.europe.africa.fill")
                    }
                    // Réglage propre à l'automatisation Apple Pay (Raccourcis) :
                    // installation du raccourci, seuil + période de l'alerte
                    // "dépenses en attente", nettoyage des anciennes entrées.
                    settingsLink(.applePay) {
                        Label("Alertes Apple Pay", systemImage: "bell.badge")
                    }
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Synchronisation ───────────────────────────────────────
                // Synchronisation du fichier de base (iCloud Drive, OneDrive…).
                // La sync des exchanges/wallets n'est PLUS ici depuis
                // 2026-08-08 : ce n'est pas un réglage global, c'est propre au
                // module Investissements — chaque lien est rattaché à un compte
                // et se gère depuis SA fiche (toolbar "Lier un exchange /
                // wallet" pour un nouveau compte, section "Synchronisation" de
                // la fiche pour un compte existant).
                Section("Sauvegarde & synchronisation") {
                    // Filet de sécurité de base — gratuit, snapshots quotidiens iCloud
                    // (recommandé pour tous les users).
                    settingsLink(.backup) {
                        Label("Sauvegarde locale & iCloud", systemImage: "icloud.and.arrow.up.fill")
                    }
                    // Sync CloudKit chiffrée multi-appareils.
                    settingsLink(.cloudSync) {
                        HStack {
                            Label("Synchronisation iCloud", systemImage: "arrow.trianglehead.2.clockwise.rotate.90.icloud")
                            Spacer()
                            Text("Bêta")
                                .font(AppTheme.Typography.labelMedium)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                    // (Export continu vers dossier retiré 2026-07-26 — redondant
                    //  avec les snapshots iCloud de BackupService, qui sont déjà
                    //  des .sqlite bruts accessibles dans Fichiers et survivent à
                    //  la désinstallation. Le multi-cloud viendra côté BackupService.)
                }
                .listRowBackground(AppTheme.Colors.surface)

                // ── Avancé ────────────────────────────────────────────────
                // Regroupe : IA, confidentialité, base de données.
                Section("Avancé") {
                    settingsLink(.ai) {
                        Label("Intelligence artificielle", systemImage: "sparkles")
                    }
                    settingsLink(.privacy) {
                        Label("Données & vie privée", systemImage: "lock.shield")
                    }
                    // Rapport fiscal présenté en sheet (pas un push) — c'est
                    // un outil d'export ponctuel, pas un sous-réglage permanent.
                    settingsLink(.taxReport) {
                        Label("Rapport fiscal France", systemImage: "doc.text.fill")
                    }
                    settingsLink(.advanced) {
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
        .nemorisFormStyle()
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .localizedNavigationTitle("Paramètres")
        .adaptivePane(isPresented: $showPaywall) {
            PaywallView().environment(store)
        }
    }

    // MARK: - App Lock Section

    /// Section "Sécurité" : toggle de verrouillage adaptatif (Face ID / Touch ID
    /// / code iOS selon disponibilité). Le label suit ce que le device propose
    /// pour que l'utilisateur voie immédiatement ce qui sera utilisé.
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
                        // Fond plein (pas de dégradé) : même recette que ProBadge et
                        // tous les autres CTA capsule de l'app (accent.Colors.accent
                        // seul). Un dégradé vers accentSecondary — cuivre volontairement
                        // FIXE entre les thèmes (cf. AppTheme.swift) — se détachait mal
                        // du vert accent qui, lui, devient beaucoup plus clair en dark
                        // mode : le cuivre inchangé y lisait comme un marron terne.
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
                    // "Changer de formule" ouvre le même Paywall que l'achat initial —
                    // il s'adapte tout seul (formule actuelle marquée, mensuel ↔ annuel
                    // via le crossgrade StoreKit natif, état dédié si Lifetime). "Gérer
                    // l'abonnement" reste la sortie vers Apple pour résilier ou changer
                    // de moyen de paiement, ce que StoreKit n'expose pas depuis l'app.
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

// (SyncSettingsView + SyncService retirés 2026-07-26 — l'export continu one-way
//  vers un dossier était redondant avec les snapshots iCloud de BackupService
//  et avait un piège de fausse sécurité : le bookmark du dossier vivait dans
//  UserDefaults, effacé à la désinstallation → l'export s'arrêtait en silence.)

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
                    #if os(macOS)
                    // Panneau système ouvert directement (cf. `presentOpenPanel`).
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
        .nemorisFormStyle()
        .localizedNavigationTitle("Avancé")
        .navigationBarTitleDisplayMode(.large)
        // iOS : picker en sheet (le contrôleur UIKit EST une vue). macOS : panneau
        // système ouvert directement depuis l'action (cf. `presentOpenPanel`).
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

    /// Enregistre le dossier choisi (commun aux deux plateformes).
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
        // Form (pas List) : contenu statique → boxes arrondies macOS via
        // nemorisFormStyle(), rendu identique sur iOS.
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

// MARK: - Sous-sections des réglages

/// Destinations des réglages. Sur macOS elles REMPLACENT le contenu du module
/// (cf. `SettingsView.pushedSection`) — un push n'y est pas défait au changement
/// de module et désynchronise la sidebar. Sur iOS, push classique.
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
        // `isPane: false` : atteinte en navigation standard ici, pas en pane
        // (cf. doc de `ApplePayAlertSettingsView`) — sans ça elle poserait
        // son propre `.paneChrome` par-dessus le titre/retour déjà fournis
        // par `settingsSectionPage`.
        case .applePay:        ApplePayAlertSettingsView(isPane: false)
        }
    }
}
