import SwiftUI

// MARK: - PatrimoineView
//
// Vue racine du module Patrimoine. **Étape 2** : section "Mobilier & Liquidités"
// fonctionnelle (création / édition / suppression d'assets + linking vers comptes
// existants). Les sections Immobilier / Prêts / Vue nette globale arriveront aux
// étapes 3 à 5 et resteront masquées tant que pas implémentées.
//
// Pattern visuel aligné sur le Dashboard refondu : pas de cards à outrance, des
// eyebrows uppercased pour structurer les sections, des rows pleine largeur avec
// la valeur à droite.

struct PatrimoineView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = PatrimoineViewModel()

    // Sheets — actifs
    @State private var showCreateAsset = false
    @State private var editingAsset: PatrimoineAsset? = nil
    @State private var assetToDelete: PatrimoineAsset? = nil

    // Sheets — biens immobiliers
    @State private var showCreateRealEstate = false
    @State private var editingRealEstate: PatrimoineRealEstate? = nil
    @State private var realEstateToDelete: PatrimoineRealEstate? = nil

    // Sheets — prêts
    @State private var showCreateLoan = false
    @State private var editingLoan: PatrimoineLoan? = nil
    @State private var loanToDelete: PatrimoineLoan? = nil

    // Sheets — goals
    @State private var showCreateGoal = false
    @State private var editingGoal: Goal? = nil
    @State private var goalToDelete: Goal? = nil

    // Sheet — projection
    @State private var showProjection = false

    var isEmbedded: Bool = false

    var body: some View {
        if isEmbedded { navBody } else { NavigationStack { navBody } }
    }

    @ViewBuilder private var navBody: some View {
        Group {
            if vm.assets.isEmpty && vm.realEstates.isEmpty && vm.loans.isEmpty {
                // Empty state pleine page — on garde un ScrollView simple pour ne
                // pas montrer une List vide alors qu'on veut une intro éditoriale.
                ZStack {
                    AppTheme.Colors.background.ignoresSafeArea()
                    ScrollView {
                        emptyState
                            .padding(.top, AppTheme.Spacing.xxxl)
                            .padding(.horizontal, AppTheme.Spacing.lg)
                    }
                }
            } else {
                // List native — chaque row peut être supprimée par swipe-trailing et
                // éditée par swipe-leading. Les rows gardent leur look "card flottante"
                // grâce à `listRowBackground(.clear)` + `listRowSeparator(.hidden)`.
                List {
                    // Hero global Patrimoine net (1ère section, scroll naturel)
                    Section {
                        heroSection
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: AppTheme.Spacing.lg,
                                                      leading: AppTheme.Spacing.lg,
                                                      bottom: AppTheme.Spacing.md,
                                                      trailing: AppTheme.Spacing.lg))
                    }
                    // Bannière "liens rompus" si au moins 1 asset linké a perdu son
                    // compte source (cascade SET NULL). Affichée entre hero et donut
                    // pour être impossible à manquer mais sans bloquer la scroll.
                    if vm.hasBrokenLinks {
                        Section {
                            brokenLinksBanner
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0,
                                                          leading: AppTheme.Spacing.lg,
                                                          bottom: AppTheme.Spacing.md,
                                                          trailing: AppTheme.Spacing.lg))
                        }
                    }
                    // Objectifs financiers — affichés en priorité haute (juste sous
                    // le hero) pour matérialiser "où je vais" avant "ce que j'ai".
                    goalsListSection
                    // Donut allocation (visible uniquement si on a du brut à montrer)
                    if vm.snapshot.totalAssets > 0 {
                        Section {
                            allocationCard
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0,
                                                          leading: AppTheme.Spacing.lg,
                                                          bottom: AppTheme.Spacing.md,
                                                          trailing: AppTheme.Spacing.lg))
                        }
                    }
                    mobilierListSection
                    immobilierListSection
                    pretsListSection
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppTheme.Colors.background)
            }
        }
        .navigationTitle("Patrimoine")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                // Le toolbar `+` devient un Menu maintenant qu'on a 2 types d'entrées
                // (actif liquide vs bien immobilier). Étape 4 ajoutera "Prêt" ici.
                Menu {
                    Button {
                        showCreateAsset = true
                    } label: {
                        Label("Actif liquide", systemImage: "banknote.fill")
                    }
                    Button {
                        showCreateRealEstate = true
                    } label: {
                        Label("Bien immobilier", systemImage: "house.fill")
                    }
                    Button {
                        showCreateLoan = true
                    } label: {
                        Label("Prêt ou dette", systemImage: "creditcard.fill")
                    }
                    Divider()
                    Button {
                        showCreateGoal = true
                    } label: {
                        Label("Objectif", systemImage: "target")
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(AppTheme.Colors.accent)
                }
            }
        }
        .sheet(isPresented: $showCreateAsset) {
            AssetFormView(viewModel: vm, existingAsset: nil)
                .environment(appState)
        }
        .sheet(item: $editingAsset) { asset in
            AssetFormView(viewModel: vm, existingAsset: asset)
                .environment(appState)
        }
        .sheet(isPresented: $showCreateRealEstate) {
            RealEstateFormView(viewModel: vm, existingItem: nil)
                .environment(appState)
        }
        .sheet(item: $editingRealEstate) { item in
            RealEstateFormView(viewModel: vm, existingItem: item)
                .environment(appState)
        }
        .sheet(isPresented: $showCreateLoan) {
            LoanFormView(viewModel: vm, existingLoan: nil)
                .environment(appState)
        }
        .sheet(item: $editingLoan) { loan in
            LoanFormView(viewModel: vm, existingLoan: loan)
                .environment(appState)
        }
        .sheet(isPresented: $showCreateGoal) {
            GoalFormView(viewModel: vm, existingGoal: nil)
                .environment(appState)
        }
        .sheet(item: $editingGoal) { goal in
            GoalFormView(viewModel: vm, existingGoal: goal)
                .environment(appState)
        }
        .sheet(isPresented: $showProjection) {
            ProjectionView(viewModel: vm)
                .environment(appState)
        }
        .confirmationDialog(
            assetToDelete.map { "Supprimer « \($0.name) » ?" } ?? "",
            isPresented: Binding(
                get: { assetToDelete != nil },
                set: { if !$0 { assetToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                if let id = assetToDelete?.id {
                    vm.deleteAsset(id: id)
                }
                assetToDelete = nil
            }
            Button("Annuler", role: .cancel) { assetToDelete = nil }
        } message: {
            Text("Cette action ne supprime pas le compte source lié, uniquement la fiche Patrimoine.")
        }
        .confirmationDialog(
            realEstateToDelete.map { "Supprimer « \($0.name) » ?" } ?? "",
            isPresented: Binding(
                get: { realEstateToDelete != nil },
                set: { if !$0 { realEstateToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                if let id = realEstateToDelete?.id {
                    vm.deleteRealEstate(id: id)
                }
                realEstateToDelete = nil
            }
            Button("Annuler", role: .cancel) { realEstateToDelete = nil }
        } message: {
            Text("Les prêts liés à ce bien deviendront orphelins mais ne seront pas supprimés.")
        }
        .confirmationDialog(
            loanToDelete.map { "Supprimer « \($0.name) » ?" } ?? "",
            isPresented: Binding(
                get: { loanToDelete != nil },
                set: { if !$0 { loanToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                if let id = loanToDelete?.id {
                    vm.deleteLoan(id: id)
                }
                loanToDelete = nil
            }
            Button("Annuler", role: .cancel) { loanToDelete = nil }
        } message: {
            Text("Cette action ne peut pas être annulée.")
        }
        .confirmationDialog(
            goalToDelete.map { "Supprimer l'objectif « \($0.name) » ?" } ?? "",
            isPresented: Binding(
                get: { goalToDelete != nil },
                set: { if !$0 { goalToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Supprimer", role: .destructive) {
                if let id = goalToDelete?.id {
                    vm.deleteGoal(id: id)
                }
                goalToDelete = nil
            }
            Button("Annuler", role: .cancel) { goalToDelete = nil }
        } message: {
            Text("L'historique de progression sera perdu.")
        }
        .task(id: appState.dataRefreshToken) {
            vm.load()
        }
    }

    // MARK: - Hero éditorial (Patrimoine net global)

    /// Hero pleine largeur en tête de la List : eyebrow + big number 44pt du patrimoine
    /// net + sous-totaux Brut/Dettes + barre de levier (dette/patrimoine brut).
    /// Cohérent avec le hero éditorial du DashboardView (refonte 2026-06-01).
    @ViewBuilder private var heroSection: some View {
        let snap = vm.snapshot
        let isPositive = snap.netWorth >= 0
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            // Eyebrow daté — donne le contexte temporel sans avoir besoin d'un sélecteur
            // de période (le snapshot reflète toujours "maintenant").
            Text(eyebrowLabel.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            // Big number — couleur dynamique (vert si positif, terracotta si négatif).
            // 44pt bold pour faire concurrence au hero Dashboard et hiérarchiser cet écran.
            MoneyText(
                amount: snap.netWorth,
                font: .system(size: 44, weight: .bold, design: .default),
                color: isPositive ? AppTheme.Colors.textPrimary : AppTheme.Colors.danger,
                maskedPlaceholder: "•• ••• €"
            )
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            // Sous-totaux Brut/Dettes alignés horizontalement
            HStack(spacing: AppTheme.Spacing.xl) {
                heroSubtotal(
                    icon: "arrow.up.right",
                    label: "Actif brut",
                    value: snap.totalAssets,
                    color: AppTheme.Colors.success
                )
                heroSubtotal(
                    icon: "arrow.down.right",
                    label: "Dettes",
                    value: snap.totalLiabilities,
                    color: AppTheme.Colors.danger
                )
            }
            .padding(.top, AppTheme.Spacing.sm)

            // Barre de "levier" — matérialise visuellement le ratio dettes/actif brut.
            // Affichée seulement s'il y a effectivement de la dette (sinon parasite).
            if snap.totalLiabilities > 0 {
                leverageBar
                    .padding(.top, AppTheme.Spacing.sm)
            }

            // Bouton "Projection 5 ans" — discret mais accessible. Visible si on
            // a quelque chose à projeter (snapshot non vide).
            if snap.totalAssets > 0 || snap.totalLiabilities > 0 {
                Button {
                    showProjection = true
                } label: {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Projection à 5 ans")
                            .font(AppTheme.Typography.labelLarge)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.Colors.accent)
                    .padding(.vertical, AppTheme.Spacing.sm)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .background(AppTheme.Colors.accent.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, AppTheme.Spacing.sm)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Spacing.lg)
        .background(
            // Dégradé éditorial subtil — cohérent avec le DashboardView. Accent à 0.18
            // qui s'évanouit vers transparent, donne du "poids" au hero sans bandeau coloré.
            LinearGradient(
                colors: [
                    AppTheme.Colors.accent.opacity(0.18),
                    AppTheme.Colors.accent.opacity(0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.Colors.accent.opacity(0.12), lineWidth: 1)
        )
    }

    /// Eyebrow daté — "Patrimoine net · juin 2026" (locale FR).
    private var eyebrowLabel: String {
        let now = Date().formatted(.dateTime.month(.wide).year().locale(Locale(identifier: "fr_FR")))
        return "Patrimoine net · \(now)"
    }

    /// Sous-totaux Brut / Dettes du hero — icône colorée + label uppercased + valeur.
    @ViewBuilder
    private func heroSubtotal(icon: String, label: String, value: Double, color: Color) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Text(value, format: .currency(code: "EUR").presentation(.narrow))
                    .font(AppTheme.Typography.moneySmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    /// Barre de levier : montre quelle proportion de l'actif brut est financée par
    /// de la dette. > 50% = warning visuel, > 100% = danger (passif > actif).
    @ViewBuilder private var leverageBar: some View {
        let ratio = vm.leverageRatio  // 0…2.0
        let ratioPercent = ratio * 100
        let barColor: Color = {
            if ratio >= 1.0 { return AppTheme.Colors.danger }
            if ratio >= 0.5 { return AppTheme.Colors.warning }
            return AppTheme.Colors.success
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: "Dette / actif brut · %.1f %%", ratioPercent))
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppTheme.Colors.surfaceSecondary)
                        .frame(height: 4)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: max(4, geo.size.width * min(1.0, ratio)),
                               height: 4)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - Broken links banner

    /// Bannière warning au sommet de la List quand au moins 1 asset lié a perdu son
    /// compte source (le compte a été supprimé). L'asset reste affiché avec sa
    /// `lastKnownValue` mais ne se met plus à jour. Le tap ouvre le premier asset
    /// concerné pour que l'user puisse relier ou repasser en manuel.
    @ViewBuilder private var brokenLinksBanner: some View {
        let count = vm.brokenLinkAssetIds.count
        let firstBroken = vm.assets.first(where: { vm.brokenLinkAssetIds.contains($0.id) })
        Button {
            if let asset = firstBroken { editingAsset = asset }
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.warning)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.Colors.warning.opacity(0.18), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(count == 1 ? "1 lien rompu détecté" : "\(count) liens rompus détectés")
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text("Le compte source a été supprimé. La dernière valeur connue est conservée jusqu'à votre prochaine action.")
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Colors.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Colors.warning.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Allocation actif brut (donut + légende)

    /// Card "Composition de votre patrimoine" : donut + légende verticale réutilisant
    /// `AllocationDonutChart` du module Investments. Slices = totals par catégorie
    /// d'actif (Mobilier liquide, Immobilier). Les dettes sont volontairement
    /// **exclues** — le donut représente l'actif BRUT, pas le net (qui est déjà
    /// affiché en gros dans le hero).
    @ViewBuilder private var allocationCard: some View {
        let slices = allocationSlices
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text("COMPOSITION DE L'ACTIF")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
            }
            if slices.isEmpty {
                Text("Ajoutez des actifs pour voir la répartition.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            } else {
                AllocationDonutChart(slices: slices, currency: "EUR", size: 170)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
    }

    /// Construit les slices pour le donut. On regroupe Mobilier (tous les assets,
    /// quelle que soit leur kind) et Immobilier en 2 grosses catégories pour ne
    /// pas saturer le donut. Plus tard on pourra splitter par AssetKind si l'user
    /// le souhaite (toggle dans la card).
    private var allocationSlices: [AllocationSlice] {
        var slices: [AllocationSlice] = []
        if vm.totalAssetsValue > 0 {
            slices.append(AllocationSlice(name: "Mobilier & liquidités", value: vm.totalAssetsValue))
        }
        if vm.totalRealEstateValue > 0 {
            slices.append(AllocationSlice(name: "Immobilier", value: vm.totalRealEstateValue))
        }
        return slices
    }

    // MARK: - Empty state

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.accent.opacity(0.12))
                    .frame(width: 88, height: 88)
                Image(systemName: "house.lodge.fill")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(AppTheme.Colors.accent)
            }
            VStack(spacing: AppTheme.Spacing.xs) {
                Text("Construisez votre patrimoine")
                    .font(AppTheme.Typography.titleLarge)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                Text("Commencez par ajouter un actif liquide (livret, compte épargne, PEA…) en mode lié pour suivre automatiquement sa valeur, ou saisissez-le à la main.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppTheme.Spacing.xl)
            }
            HStack(spacing: AppTheme.Spacing.md) {
                Button {
                    showCreateAsset = true
                } label: {
                    Label("Actif", systemImage: "banknote.fill")
                        .font(AppTheme.Typography.labelLarge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.vertical, AppTheme.Spacing.md)
                        .background(AppTheme.Colors.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    showCreateRealEstate = true
                } label: {
                    Label("Bien", systemImage: "house.fill")
                        .font(AppTheme.Typography.labelLarge)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.vertical, AppTheme.Spacing.md)
                        .background(
                            Capsule().strokeBorder(AppTheme.Colors.accent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppTheme.Spacing.xxxl)
    }

    // MARK: - List row defaults (helpers)

    /// Insets standard pour les rows de la List Patrimoine — donne la "respiration"
    /// éditoriale entre rows (4 verticaux + alignement horizontal sur Spacing.lg).
    private var plainRowInsets: EdgeInsets {
        EdgeInsets(top: 4,
                   leading: AppTheme.Spacing.lg,
                   bottom: 4,
                   trailing: AppTheme.Spacing.lg)
    }

    /// Header de section uniformisé : eyebrow uppercased + total en `moneyMedium`
    /// (couleur paramétrable pour différencier actifs et passifs) + un complément
    /// optionnel à droite (compte d'items, coût mensuel, gain agrégé).
    ///
    /// Centralisé ici plutôt que dupliqué dans chaque section.
    @ViewBuilder
    private func sectionHeader(eyebrow: String,
                               total: Double,
                               accent: Color,
                               trailingNote: String? = nil,
                               gainChip: Double? = nil,
                               hideTotal: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                // Pour les sections sans total monétaire pertinent (ex : "OBJECTIFS",
                // qui n'a pas de "somme" qui ait du sens), on masque la ligne de chiffre.
                if !hideTotal {
                    Text(total, format: .currency(code: "EUR").presentation(.narrow))
                        .font(AppTheme.Typography.moneyMedium)
                        .foregroundStyle(accent)
                }
            }
            Spacer()
            if let gain = gainChip {
                HStack(spacing: 4) {
                    Image(systemName: gain >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(gain, format: .currency(code: "EUR").presentation(.narrow))
                        .font(AppTheme.Typography.labelLarge)
                }
                .foregroundStyle(gain >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
            } else if let note = trailingNote {
                Text(note)
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .textCase(nil)  // SwiftUI met les section headers en MAJUSCULES par défaut — on désactive
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    // MARK: - Section Objectifs (Goals)

    /// Section "Objectifs" en tête des collections Patrimoine. Visible uniquement
    /// si l'user a au moins 1 goal — sinon on n'affiche rien (header inclus) pour
    /// rester cohérent avec le pattern des autres sections.
    ///
    /// Le toolbar Menu `+` reste l'entry point unique pour créer.
    @ViewBuilder private var goalsListSection: some View {
        if !vm.goals.isEmpty {
            Section {
                ForEach(vm.goals) { goal in
                    goalRow(goal)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(plainRowInsets)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingGoal = goal
                            } label: {
                                Label("Modifier", systemImage: "pencil")
                            }
                            .tint(AppTheme.Colors.accent)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                goalToDelete = goal
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                }
            } header: {
                sectionHeader(
                    eyebrow: "OBJECTIFS",
                    total: 0,                                  // Pas de total monétaire pertinent ici
                    accent: AppTheme.Colors.textPrimary,
                    trailingNote: "\(vm.goals.count) objectif\(vm.goals.count > 1 ? "s" : "")",
                    hideTotal: true                            // On masque le 0 € — irrelevant
                )
            }
        }
    }

    @ViewBuilder
    private func goalRow(_ goal: Goal) -> some View {
        let progress = vm.goalProgresses[goal.id]
        Button {
            editingGoal = goal
        } label: {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                // Ligne 1 : icône + nom + % atteint
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: goal.kind.systemIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.accent)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.Colors.accent.opacity(0.13), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(goal.name)
                            .font(AppTheme.Typography.titleSmall)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(goalSubtitle(goal: goal, progress: progress))
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if let progress {
                        Text(progress.percentText)
                            .font(AppTheme.Typography.moneySmall)
                            .foregroundStyle(progress.isCompleted
                                             ? AppTheme.Colors.success
                                             : AppTheme.Colors.textPrimary)
                    }
                }

                // Ligne 2 : barre de progression couleur dynamique selon état
                // (success si atteint, warning si overdue, accent vert sinon)
                if let progress {
                    let barColor: Color = progress.isCompleted
                        ? AppTheme.Colors.success
                        : (progress.isOverdue ? AppTheme.Colors.danger : AppTheme.Colors.accent)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AppTheme.Colors.surfaceSecondary)
                                .frame(height: 5)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(barColor)
                                .frame(width: max(4, geo.size.width * progress.ratio),
                                       height: 5)
                        }
                    }
                    .frame(height: 5)

                    // Ligne 3 : current / target + mensualité requise (si deadline)
                    HStack {
                        MoneyText(
                            amount: progress.currentAmount,
                            font: AppTheme.Typography.labelMedium,
                            color: AppTheme.Colors.textSecondary
                        )
                        Text("/")
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        MoneyText(
                            amount: goal.kind == .debtPayoff
                                ? (progress.currentAmount + progress.amountRemaining)
                                : goal.targetAmount,
                            font: AppTheme.Typography.labelMedium,
                            color: AppTheme.Colors.textSecondary
                        )
                        Spacer()
                        if let monthly = GoalCalculator.monthlyContributionNeeded(for: progress) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 8, weight: .bold))
                                MoneyText(
                                    amount: monthly,
                                    font: AppTheme.Typography.labelMedium,
                                    color: AppTheme.Colors.accent
                                )
                                Text("/mois")
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.accent)
                            }
                        }
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
        .buttonStyle(.plain)
    }

    /// Sous-titre row goal : kind label + statut deadline + hint contextuel.
    /// Pour debt_payoff à 0% on ajoute une note explicative ("Baseline capturée…")
    /// pour éviter que l'user pense que c'est cassé.
    private func goalSubtitle(goal: Goal, progress: GoalProgress?) -> String {
        var parts: [String] = [goal.kind.label]
        if let progress, progress.isCompleted {
            parts.append("Atteint ✓")
        } else if let days = progress?.daysRemaining {
            if days < 0 {
                parts.append("En retard de \(abs(days)) j")
            } else if days == 0 {
                parts.append("Échéance aujourd'hui")
            } else if days < 365 {
                parts.append("Dans \(days) j")
            } else {
                let years = days / 365
                parts.append("Dans ~\(years) an\(years > 1 ? "s" : "")")
            }
        }
        // Hint pédagogique pour debt_payoff à 0% : le calcul est correct mais
        // contre-intuitif (vous avez 0% car vous n'avez encore rien remboursé
        // **depuis la création du goal**, pas depuis le début du prêt).
        if goal.kind == .debtPayoff, let progress, progress.ratio == 0 {
            parts.append("Point de départ")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Section Mobilier & Liquidités (List native)

    @ViewBuilder private var mobilierListSection: some View {
        // Section entièrement masquée si vide (header + content) — évite un header
        // orphelin suspendu. La création se fait via le toolbar Menu `+`.
        if !vm.assets.isEmpty {
            Section {
                ForEach(vm.assets) { asset in
                    assetRow(asset)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(plainRowInsets)
                        // Swipe LEFT (leading) → Modifier ; swipe RIGHT (trailing) → Supprimer.
                        // Geste natif iOS, supérieur au contextMenu pour les actions courantes.
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingAsset = asset
                            } label: {
                                Label("Modifier", systemImage: "pencil")
                            }
                            .tint(AppTheme.Colors.accent)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                assetToDelete = asset
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                }
            } header: {
                sectionHeader(
                    eyebrow: "MOBILIER & LIQUIDITÉS",
                    total: vm.totalAssetsValue,
                    accent: AppTheme.Colors.textPrimary,
                    trailingNote: "\(vm.assets.count) actif\(vm.assets.count > 1 ? "s" : "")"
                )
            }
        }
    }

    // MARK: - Section Immobilier (List native)

    @ViewBuilder private var immobilierListSection: some View {
        if !vm.realEstates.isEmpty {
            Section {
                ForEach(vm.realEstates) { item in
                    realEstateRow(item)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(plainRowInsets)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingRealEstate = item
                            } label: {
                                Label("Modifier", systemImage: "pencil")
                            }
                            .tint(AppTheme.Colors.accent)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                realEstateToDelete = item
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                }
            } header: {
                sectionHeader(
                    eyebrow: "IMMOBILIER",
                    total: vm.totalRealEstateValue,
                    accent: AppTheme.Colors.textPrimary,
                    gainChip: vm.totalRealEstateCapitalGain == 0 ? nil : vm.totalRealEstateCapitalGain
                )
            }
        }
    }

    // (addRealEstateCard retiré — création via le toolbar Menu `+` uniquement.)

    @ViewBuilder
    private func realEstateRow(_ item: PatrimoineRealEstate) -> some View {
        Button {
            editingRealEstate = item
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "house.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.Colors.accentSecondary.opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(realEstateSubtitle(item))
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.currentValue, format: .currency(code: "EUR").presentation(.narrow))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    // Mini chip plus-value (+X € / +Y%) si l'user a un prix d'achat
                    // renseigné — sinon on cache (pas pertinent).
                    if item.purchasePrice > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: item.capitalGain >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 8, weight: .bold))
                            Text(String(format: "%@%.1f %%",
                                        item.capitalGain >= 0 ? "+" : "",
                                        item.capitalGainPercent))
                                .font(AppTheme.Typography.labelMedium)
                        }
                        .foregroundStyle(item.capitalGain >= 0
                                         ? AppTheme.Colors.success
                                         : AppTheme.Colors.danger)
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
        .buttonStyle(.plain)
        // contextMenu retiré au profit des swipeActions natifs (configurés côté
        // List dans immobilierListSection).
    }

    /// Sous-titre pédagogique : "Acheté 240 000 € en oct. 2018" + adresse si renseignée.
    private func realEstateSubtitle(_ item: PatrimoineRealEstate) -> String {
        let priceText = item.purchasePrice > 0
            ? item.purchasePrice.formatted(.currency(code: "EUR").presentation(.narrow))
            : "—"
        let dateText = item.purchaseDate.formatted(.dateTime.month(.abbreviated).year())
        let baseLine = "Acheté \(priceText) en \(dateText)"
        if let address = item.address, !address.isEmpty {
            // On garde la première ligne d'adresse pour éviter de polluer la row.
            let firstLine = address.split(separator: "\n").first.map(String.init) ?? address
            return "\(baseLine) · \(firstLine)"
        }
        return baseLine
    }

    // MARK: - Section Prêts & dettes (List native)

    @ViewBuilder private var pretsListSection: some View {
        if !vm.loans.isEmpty {
            Section {
                ForEach(vm.loans) { loan in
                    loanRow(loan)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(plainRowInsets)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingLoan = loan
                            } label: {
                                Label("Modifier", systemImage: "pencil")
                            }
                            .tint(AppTheme.Colors.accent)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                loanToDelete = loan
                            } label: {
                                Label("Supprimer", systemImage: "trash")
                            }
                        }
                }
            } header: {
                // Header dette : montant en danger (terracotta) + coût mensuel total
                // (mensualités + assurances) en chip pour matérialiser le "poids" du passif.
                sectionHeader(
                    eyebrow: "PRÊTS & DETTES",
                    total: vm.totalLoansRemainingCapital,
                    accent: AppTheme.Colors.danger,
                    trailingNote: vm.totalMonthlyLoanCost > 0
                        ? "\(vm.totalMonthlyLoanCost.formatted(.currency(code: "EUR").presentation(.narrow))) / mois"
                        : "\(vm.loans.count) prêt\(vm.loans.count > 1 ? "s" : "")"
                )
            }
        }
    }

    // (addLoanCard retiré — création via le toolbar Menu `+` uniquement.)

    @ViewBuilder
    private func loanRow(_ loan: PatrimoineLoan) -> some View {
        let state = vm.loanStates[loan.id]
        Button {
            editingLoan = loan
        } label: {
            VStack(spacing: AppTheme.Spacing.sm) {
                // Ligne principale : icône + nom + capital restant.
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.danger)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.Colors.danger.opacity(0.13), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text(loan.name)
                            .font(AppTheme.Typography.titleSmall)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(loanSubtitle(loan))
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state?.remainingCapital ?? loan.principal,
                             format: .currency(code: "EUR").presentation(.narrow))
                            .font(AppTheme.Typography.moneySmall)
                            .foregroundStyle(AppTheme.Colors.danger)
                        // Coût mensuel = mensualité prêt + assurance (si renseignée).
                        // On affiche en 1 ligne pour ne pas étirer la row, et avec un
                        // tooltip "+ assu" pour matérialiser la présence de l'assurance.
                        if let state, !state.isPending && !state.isCompleted {
                            let totalMonthly = state.monthlyPayment + loan.insuranceMonthly
                            if totalMonthly > 0 {
                                Text("\(totalMonthly.formatted(.currency(code: "EUR").presentation(.narrow))) / mois")
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                if loan.insuranceMonthly > 0 {
                                    Text("dont \(loan.insuranceMonthly.formatted(.currency(code: "EUR").presentation(.narrow))) d'assurance")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(AppTheme.Colors.warning)
                                }
                            }
                        }
                    }
                }

                // Barre de progression % remboursé — visualise instantanément l'avancement
                // du prêt. Masquée pour REVOLVING (pas pertinent) et pour les prêts
                // pas encore démarrés (état pending).
                if loan.loanType != .revolving,
                   let state, !state.isPending,
                   state.capitalPaid > 0 || state.remainingCapital > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AppTheme.Colors.surfaceSecondary)
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AppTheme.Colors.success.opacity(0.7))
                                .frame(width: max(4, geo.size.width * state.progressRatio),
                                       height: 4)
                        }
                    }
                    .frame(height: 4)
                    HStack {
                        Text(String(format: "%.0f %% remboursé", state.progressRatio * 100))
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Spacer()
                        Text("Mois \(state.monthsElapsed) / \(loan.durationMonths)")
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
        .buttonStyle(.plain)
        // contextMenu retiré au profit des swipeActions natifs (configurés côté
        // List dans pretsListSection).
    }

    /// Sous-titre row prêt : type + durée + bien lié si applicable.
    private func loanSubtitle(_ loan: PatrimoineLoan) -> String {
        var parts: [String] = [loan.loanType.label]
        if loan.loanType != .revolving {
            let years = loan.durationMonths / 12
            let rem = loan.durationMonths % 12
            if years > 0 && rem == 0 {
                parts.append("\(years) an\(years > 1 ? "s" : "")")
            } else if years > 0 {
                parts.append("\(years) an\(years > 1 ? "s" : "") \(rem) mois")
            } else {
                parts.append("\(loan.durationMonths) mois")
            }
            if loan.annualRate > 0 {
                parts.append(String(format: "%.2f %%", loan.annualRate * 100))
            }
        }
        if let realEstateName = vm.realEstateName(forLoanLinked: loan.linkedRealEstateId) {
            parts.append("→ \(realEstateName)")
        }
        return parts.joined(separator: " · ")
    }

    // (addAssetCard retiré — création via le toolbar Menu `+` uniquement.)

    @ViewBuilder
    private func assetRow(_ asset: PatrimoineAsset) -> some View {
        let resolved = vm.resolvedAssetValues[asset.id] ?? asset.lastKnownValue
        let source = vm.resolvedAssetSources[asset.id] ?? .manual

        Button {
            editingAsset = asset
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: asset.assetKind.systemIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor(for: asset.assetKind))
                    .frame(width: 36, height: 36)
                    .background(iconColor(for: asset.assetKind).opacity(0.13), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(asset.name)
                            .font(AppTheme.Typography.titleSmall)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                        // Badge contextuel selon la source résolue.
                        sourceBadge(source)
                    }
                    Text(vm.sourceLabel(for: asset))
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(resolved, format: .currency(code: "EUR").presentation(.narrow))
                    .font(AppTheme.Typography.moneySmall)
                    .foregroundStyle(resolved < 0 ? AppTheme.Colors.danger : AppTheme.Colors.textPrimary)
            }
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
        .buttonStyle(.plain)
        // contextMenu retiré au profit des swipeActions natifs (configurés côté
        // List dans mobilierListSection).
    }

    /// Petit pictogramme à droite du nom qui matérialise instantanément la source
    /// de la valeur (lien actif, manuel, lien rompu). Évite à l'user de lire le
    /// sous-titre pour comprendre l'état.
    @ViewBuilder
    private func sourceBadge(_ source: AssetValueSource) -> some View {
        switch source {
        case .manual:
            EmptyView()
        case .linkedAccount, .linkedInvestment:
            Image(systemName: "link")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.Colors.accent)
                .frame(width: 18, height: 18)
                .background(AppTheme.Colors.accent.opacity(0.13), in: Circle())
        case .brokenLink:
            // Triangle warning explicite — l'icône `link.badge.plus` était trop
            // discrète et confondue avec "lien actif". Ici on signale clairement
            // qu'une action user est nécessaire (réparer ou repasser en manuel).
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.Colors.warning)
                .frame(width: 18, height: 18)
                .background(AppTheme.Colors.warning.opacity(0.18), in: Circle())
        }
    }

    private func iconColor(for kind: AssetKind) -> Color {
        switch kind {
        case .cash:       return AppTheme.Colors.success
        case .savings:    return AppTheme.Colors.accent
        case .investment: return AppTheme.Colors.accentSecondary
        case .other:      return AppTheme.Colors.textSecondary
        }
    }

    // (Teaser "À venir" retiré à l'étape 5 — toutes les sections sont maintenant
    //  implémentées : Mobilier, Immobilier, Prêts, Vue globale via le hero.)
}

#Preview {
    PatrimoineView()
        .environment(AppState())
}
