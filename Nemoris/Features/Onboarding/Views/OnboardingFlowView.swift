import SwiftUI
import UniformTypeIdentifiers

// MARK: - OnboardingFlowView
//
// Parcours guidé au 1er launch. Remplace l'ancien `OnboardingView` minimaliste
// par 5 étapes qui couvrent : pédagogie philosophique, choix base, premier compte,
// activation modules opt-in, récap final.
//
// **Gate** : ce flow ne s'affiche que si `hasDatabase == false` côté NemorisApp.
// Une fois la DB créée (étape `database`), on a déjà atteint un état "no return"
// — l'user peut quitter l'app, au prochain launch il aura `hasDatabase == true`
// et n'aura plus le flow. Mais on lui propose quand même les étapes restantes
// (modules + ready) tant qu'il est dans le flow courant. S'il quitte au step
// modules, c'est OK : il pourra activer les modules plus tard dans Settings.
//
// **Pas d'intrusion users existants** : ce flow ne se redéclenche jamais une
// fois la DB initialisée. Les users existants qui veulent voir les modules
// opt-in passent par Settings → Modules (existant).

struct OnboardingFlowView: View {
    let onDone: () -> Void
    @Environment(PurchaseManager.self) private var store

    // MARK: - Steps

    private enum Step: Int, CaseIterable {
        case welcome       // Pédagogie + 3 promesses
        case database      // Créer une DB neuve ou importer un .sqlite
        case createAccount // Premier compte (seulement si "Créer")
        case modules       // Choix des modules opt-in (Invest / Budget / Patrimoine / Tricount)
        case ready         // Récap + "Ouvrir Nemoris"
    }

    @State private var step: Step = .welcome
    @State private var showFilePicker = false
    @State private var errorMessage: String?

    // Détection restauration (2026-07-26) : au 1er lancement on scanne les
    // snapshots iCloud de BackupService (ils survivent à la désinstallation). Si
    // une sauvegarde existe, on la propose EN PREMIER, avec un badge de fraîcheur
    // — pour ne plus jamais laisser un user repartir de zéro alors qu'une
    // sauvegarde l'attendait.
    @State private var restoreSnapshots: [BackupService.Snapshot] = []
    @State private var isRestoring = false

    // Premier compte (step .createAccount)
    @State private var accountName: String = ""
    @State private var accountType: String = "COURANT"

    // Modules opt-in (step .modules)
    // Préchargés depuis UserDefaults : si l'user a déjà ouvert l'app avant, on
    // respecte ses choix précédents au lieu de tout remettre à false.
    @State private var enableInvestments: Bool = UserDefaults.standard.bool(forKey: "featureInvestments")
    @State private var enableBudget: Bool      = UserDefaults.standard.bool(forKey: "featureBudget")
    @State private var enablePatrimoine: Bool  = UserDefaults.standard.bool(forKey: "featurePatrimoine")
    @State private var enableTricount: Bool    = UserDefaults.standard.bool(forKey: "featureTricount")

    private let repository = TransactionRepository()

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.Colors.background.ignoresSafeArea()
                Group {
                    switch step {
                    case .welcome:       welcomeStep
                    case .database:      databaseStep
                    case .createAccount: createAccountStep
                    case .modules:       modulesStep
                    case .ready:         readyStep
                    }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal:   .move(edge: .leading).combined(with: .opacity)
                ))
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: step)
        }
    }

    // MARK: - Step 1 : Welcome

    private var welcomeStep: some View {
        VStack(spacing: AppTheme.Spacing.xxxl) {
            Spacer()

            // Mark Nemoris
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.xl)
                    .fill(AppTheme.Colors.accent.opacity(0.10))
                    .frame(width: 96, height: 96)
                Image(systemName: "leaf.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(AppTheme.Colors.accent)
            }

            VStack(spacing: AppTheme.Spacing.sm) {
                Text("Bienvenue dans Nemoris")
                    .font(AppTheme.Typography.displayMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Vos finances vous appartiennent.")
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }

            // 3 promesses différenciantes — ce qui fait que l'user CHOISIT Nemoris
            // plutôt que Bankin' ou un Excel. Plus parlant qu'une liste de features.
            VStack(spacing: AppTheme.Spacing.lg) {
                promiseRow(
                    icon: "wifi.slash",
                    title: "100 % hors-ligne",
                    subtitle: "Vos données restent sur votre iPhone. Aucun serveur Nemoris."
                )
                promiseRow(
                    icon: "hand.raised.fill",
                    title: "Aucune collecte",
                    subtitle: "Pas de tracking, pas de pub, pas de revente."
                )
                promiseRow(
                    icon: "checkmark.seal.fill",
                    title: "Gratuit à l'essentiel",
                    subtitle: "Transactions, catégorisation, dashboard — sans abonnement."
                )
            }
            .padding(.horizontal, AppTheme.Spacing.xl)

            Spacer()

            primaryButton("Commencer") { step = .database }
                .padding(.horizontal, AppTheme.Spacing.xxxl)
                .padding(.bottom, AppTheme.Spacing.xxxl)
        }
    }

    private func promiseRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 40, height: 40)
                .background(AppTheme.Colors.accent.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTheme.Typography.titleSmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
        }
    }

    // MARK: - Step 2 : Database

    private var databaseStep: some View {
        VStack(spacing: AppTheme.Spacing.xxxl) {
            Spacer()

            VStack(spacing: AppTheme.Spacing.md) {
                Text("Votre base de données")
                    .font(AppTheme.Typography.displaySmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Démarrez avec une base vierge ou importez une copie d'un fichier .sqlite existant — par exemple d'une ancienne version de Nemoris ou d'un export. Le fichier original ne sera plus utilisé ensuite.")
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppTheme.Spacing.xl)
            }

            // Sauvegarde iCloud détectée → proposée EN PREMIER (badge fraîcheur).
            if let latest = restoreSnapshots.first {
                VStack(spacing: AppTheme.Spacing.sm) {
                    restoreCard(latest)
                    Text("ou repartir autrement")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .padding(.horizontal, AppTheme.Spacing.xxxl)
            }

            VStack(spacing: AppTheme.Spacing.md) {
                primaryButton("Créer une nouvelle base", action: createNew)
                secondaryButton("Rejoindre via iCloud", action: createForICloud)
                secondaryButton("Importer un fichier .sqlite") {
                    showFilePicker = true
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xxxl)

            Text("Si vous avez déjà Nemoris sur un iPhone ou un iPad, choisissez « Rejoindre via iCloud » : la base sera créée sans catégories par défaut. Activez ensuite la synchronisation iCloud dans Réglages.")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.Spacing.xxxl)

            if let err = errorMessage {
                Text(err)
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppTheme.Spacing.xxxl)
            }

            Spacer()
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    _ = url.startAccessingSecurityScopedResource()
                    try DatabaseManager.shared.linkExternalFile(from: url)
                    // Import direct → on saute la création de compte (la DB importée
                    // a déjà ses comptes) et on file aux modules.
                    step = .modules
                } catch {
                    errorMessage = error.localizedDescription
                }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .task { await loadSnapshotsForRestore() }
    }

    // MARK: - Step 3 : Premier compte (suite d'une création neuve)

    private var createAccountStep: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Ex. : Compte courant BNP", text: $accountName)
                        .autocorrectionDisabled()
                    Picker("Type", selection: $accountType) {
                        ForEach(AccountType.allCases, id: \.rawValue) { type in
                            Text(type.label).tag(type.rawValue)
                        }
                    }
                } header: {
                    Text("Votre premier compte")
                } footer: {
                    Text("Vous pourrez ajouter d'autres comptes plus tard dans Données.")
                }
            }
            .nemorisFormStyle()
            .scrollContentBackground(.hidden)

            primaryButton("Continuer") {
                let name = accountName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                repository.addAccount(name: name, type: accountType)
                step = .modules
            }
            .disabled(accountName.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(accountName.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            .padding(.horizontal, AppTheme.Spacing.xxxl)
            .padding(.bottom, AppTheme.Spacing.xxxl)
        }
        .navigationTitle("Créer un compte")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Step 4 : Modules opt-in

    private var modulesStep: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            VStack(spacing: AppTheme.Spacing.sm) {
                Text("Vos modules")
                    .font(AppTheme.Typography.displaySmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Activez seulement ce dont vous avez besoin. Tout est désactivable plus tard dans Réglages.")
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppTheme.Spacing.xl)
            }
            .padding(.top, AppTheme.Spacing.xxxl)

            ScrollView {
                VStack(spacing: AppTheme.Spacing.md) {
                    moduleCard(
                        icon: "chart.line.uptrend.xyaxis",
                        title: "Investissements",
                        subtitle: "PEA, CTO, crypto. Suivi de portefeuille, sync live exchanges.",
                        isPro: !store.isUnlocked(.investments),
                        isOn: $enableInvestments
                    )
                    moduleCard(
                        icon: "chart.bar.fill",
                        title: "Budget & Prévisions",
                        subtitle: "Récurrents, prévisions, calendrier, notifications j-3.",
                        isPro: !store.isUnlocked(.budget),
                        isOn: $enableBudget
                    )
                    moduleCard(
                        icon: "house.lodge.fill",
                        title: "Patrimoine",
                        subtitle: "Liquidités, immobilier, prêts. Valeur nette globale.",
                        isPro: false,
                        isOn: $enablePatrimoine
                    )
                    moduleCard(
                        icon: "person.2.fill",
                        title: "Tricount",
                        subtitle: "Partage de dépenses en groupe (voyages, colocs…).",
                        isPro: false,
                        isOn: $enableTricount
                    )
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
            }

            primaryButton("Continuer") {
                // Persist les choix dans UserDefaults via les setters AppState.
                // On ne peut pas accéder à appState ici (pas dans l'env), donc on
                // écrit directement aux mêmes clés UserDefaults — c'est la source de
                // vérité de toute façon (cf. AppState.show* getters).
                UserDefaults.standard.set(enableInvestments, forKey: "featureInvestments")
                UserDefaults.standard.set(enableBudget,      forKey: "featureBudget")
                UserDefaults.standard.set(enablePatrimoine,  forKey: "featurePatrimoine")
                UserDefaults.standard.set(enableTricount,    forKey: "featureTricount")
                step = .ready
            }
            .padding(.horizontal, AppTheme.Spacing.xxxl)
            .padding(.bottom, AppTheme.Spacing.xxxl)
        }
    }

    @ViewBuilder
    private func moduleCard(icon: String, title: String, subtitle: String, isPro: Bool, isOn: Binding<Bool>) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 44, height: 44)
                .background(AppTheme.Colors.accent.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    if isPro {
                        // Badge "Pro" discret — l'user voit que l'activation
                        // déclenchera le paywall plus tard (depuis Settings).
                        Text("PRO")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.6)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .foregroundStyle(.white)
                            .background(AppTheme.Colors.warning, in: Capsule())
                    }
                }
                Text(subtitle)
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(AppTheme.Colors.accent)
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    // MARK: - Step 5 : Ready

    private var readyStep: some View {
        VStack(spacing: AppTheme.Spacing.xxxl) {
            Spacer()

            ZStack {
                Circle()
                    .fill(AppTheme.Colors.success.opacity(0.13))
                    .frame(width: 100, height: 100)
                Image(systemName: "checkmark")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.success)
            }

            VStack(spacing: AppTheme.Spacing.sm) {
                Text("Vous êtes prêt")
                    .font(AppTheme.Typography.displaySmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Vos prochaines étapes seront d'importer un relevé bancaire CSV ou d'ajouter vos transactions à la main.")
                    .font(AppTheme.Typography.bodyMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppTheme.Spacing.xl)
            }

            // Tips éditoriaux pour orienter sans imposer un parcours rigide.
            VStack(spacing: AppTheme.Spacing.sm) {
                tipRow(icon: "square.and.arrow.down", text: "Dashboard → menu → Importer un CSV")
                tipRow(icon: "lock.shield.fill", text: "Réglages → Sécurité pour activer Face ID")
                tipRow(icon: "icloud.and.arrow.up.fill", text: "Réglages → Sauvegarde locale & iCloud")
            }
            .padding(.horizontal, AppTheme.Spacing.xl)

            Spacer()

            primaryButton("Ouvrir Nemoris", action: onDone)
                .padding(.horizontal, AppTheme.Spacing.xxxl)
                .padding(.bottom, AppTheme.Spacing.xxxl)
        }
    }

    private func tipRow(icon: String, text: String) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .frame(width: 26)
            Text(text)
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
        }
    }

    // MARK: - Actions

    private func createNew() {
        do {
            try DatabaseManager.shared.createNewDatabase(seedDefaults: true)
            step = .createAccount
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Base vierge sans seed : l'user activera la sync iCloud dans Réglages.
    private func createForICloud() {
        do {
            try DatabaseManager.shared.createNewDatabase(seedDefaults: false)
            step = .modules
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Restauration depuis une sauvegarde iCloud

    /// Charge les snapshots BackupService. iCloud peut mettre quelques secondes à
    /// exposer son conteneur après un cold start / une réinstallation → on
    /// réessaie jusqu'à 5 fois (1 s d'intervalle) avant d'abandonner en silence.
    @MainActor
    private func loadSnapshotsForRestore() async {
        for attempt in 0..<5 {
            let found = BackupService.shared.listSnapshots()
            if !found.isEmpty {
                restoreSnapshots = found
                return
            }
            if attempt < 4 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }
    }

    /// Restaure la sauvegarde la plus récente puis file aux modules (la base
    /// restaurée a déjà ses comptes). Le download iCloud peut bloquer quelques
    /// secondes → on affiche un état "Restauration…".
    private func restoreLatest() {
        guard let snap = restoreSnapshots.first, !isRestoring else { return }
        isRestoring = true
        errorMessage = nil
        Task { @MainActor in
            do {
                try BackupService.shared.restore(snapshot: snap)
                isRestoring = false
                step = .modules
            } catch {
                isRestoring = false
                errorMessage = "Restauration impossible : \(error.localizedDescription)"
            }
        }
    }

    /// Niveau d'alerte selon l'âge de la sauvegarde : plus elle est vieille, plus
    /// on prévient qu'en restaurant on perd les données saisies depuis.
    private func restoreFreshness(_ snap: BackupService.Snapshot) -> (tint: Color, icon: String, message: String) {
        let days = Calendar.current.dateComponents([.day], from: snap.createdAt, to: Date()).day ?? 0
        switch days {
        case ...1:
            return (AppTheme.Colors.success, "checkmark.seal.fill",
                    "Sauvegarde récente — sûre à restaurer.")
        case 2...7:
            return (AppTheme.Colors.warning, "exclamationmark.triangle.fill",
                    "Il y a \(days) jours — vos données des derniers jours pourraient manquer.")
        default:
            return (AppTheme.Colors.danger, "exclamationmark.triangle.fill",
                    "Attention : \(days) jours. Des données récentes manqueront probablement.")
        }
    }

    @ViewBuilder
    private func restoreCard(_ snap: BackupService.Snapshot) -> some View {
        let fresh = restoreFreshness(snap)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "icloud.and.arrow.down.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sauvegarde iCloud trouvée")
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("\(snap.displayName) · \(snap.sizeLabel)")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: fresh.icon).font(.caption)
                Text(fresh.message)
                    .font(AppTheme.Typography.bodySmall)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(fresh.tint)

            Button(action: restoreLatest) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    if isRestoring { ProgressView().controlSize(.small).tint(.white) }
                    Text(isRestoring ? "Restauration…" : "Restaurer cette sauvegarde")
                        .font(AppTheme.Typography.titleSmall)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.md)
            }
            .foregroundStyle(.white)
            .background(AppTheme.Colors.accent)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .disabled(isRestoring)
        }
        .padding(AppTheme.Spacing.xl)
        .background(AppTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .stroke(AppTheme.Colors.accent.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Reusable buttons

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTheme.Typography.titleSmall)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.md)
        }
        .foregroundStyle(.white)
        .background(AppTheme.Colors.accent)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }

    private func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(AppTheme.Typography.titleSmall)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.md)
        }
        .foregroundStyle(AppTheme.Colors.accent)
        .background(AppTheme.Colors.accent.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
    }
}
