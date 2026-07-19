import SwiftUI
import Charts
import TipKit

// MARK: - DashboardView (Annual)

/// Dashboard repensé en **page éditoriale** (refonte 2026-06-01).
///
/// Avant : pile de cards uniformes ("summary card", "monthly card", "category card"…)
/// qui hiérarchisait tout au même niveau visuel → effet "tableau de bord d'admin".
///
/// Après : un seul *hero* dominant en haut de l'écran (solde net annuel en très grosse
/// typo + variation vs N-1) sur un fond dégradé subtil, suivi d'un bandeau dédié au
/// patrimoine investi (cliquable → onglet Investissements), puis de blocs d'analyse
/// alignés pleine largeur sans card-wrapper. Les composants `AppChartCard` et
/// `PremiumDashboardSummaryCard` ne sont plus utilisés ici — l'impact vient de la
/// typo, du dégradé et de l'espacement, pas du fond blanc/encadré.
struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var vm = AnnualDashboardViewModel()
    @State private var showSettings = false
    @State private var groupByParent = false
    @State private var showImport = false
    @State private var showSearch = false
    /// `false` jusqu'à la première fin de `vm.load()` après .task. Pilote le skeleton.
    @State private var hasLoaded = false
    private let chartTip = DashboardChartTip()

    /// Skeleton tant que la 1ère charge n'a pas terminé OU pendant un reload explicite via VM.
    private var showSkeleton: Bool { !hasLoaded || vm.isLoading }

    private let availableYears: [Int] = {
        let current = Calendar.current.component(.year, from: Date())
        return Array((current - 5)...current).reversed()
    }()

    var isEmbedded: Bool = false

    var body: some View {
        if isEmbedded { navBody } else { NavigationStack { navBody } }
    }

    @ViewBuilder private var navBody: some View {
        ZStack(alignment: .top) {
            AppTheme.Colors.background.ignoresSafeArea()
            // Dégradé éditorial du top : accent → background. Sur 360pt seulement
            // pour ne pas baigner toute la scroll view dans la teinte verte.
            heroBackdrop

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    yearPicker
                        .padding(.horizontal, AppTheme.Spacing.lg)
                        .padding(.top, AppTheme.Spacing.sm)

                    if showSkeleton {
                        skeletonContent
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.top, AppTheme.Spacing.lg)
                    } else {
                        // Bandeau d'alertes intelligentes — visible uniquement si
                        // l'engine a remonté au moins une alerte actionnable.
                        // Placé en tout premier pour maximiser la visibilité.
                        if !vm.alerts.isEmpty {
                            AlertsBanner(alerts: vm.alerts)
                                .padding(.horizontal, AppTheme.Spacing.lg)
                                .padding(.top, AppTheme.Spacing.md)
                        }

                        editorialHero
                            .padding(.horizontal, AppTheme.Spacing.lg)
                            .padding(.top, AppTheme.Spacing.xl)

                        if vm.monthlyData.isEmpty && vm.categoryData.isEmpty {
                            OnboardingImportCard { showImport = true }
                                .padding(.horizontal, AppTheme.Spacing.lg)
                                .padding(.top, AppTheme.Spacing.xxxl)
                        } else {
                            // Investissements (visible uniquement si l'user a au moins
                            // 1 compte Investments avec une valorisation).
                            if vm.investmentsRecap.hasData {
                                investmentsBanner
                                    .padding(.top, AppTheme.Spacing.xxl)
                            }

                            if vm.patrimoineRecap.hasData {
                                patrimoineBanner
                                    .padding(.top, AppTheme.Spacing.md)
                            }

                            if vm.budgetRecap.hasData {
                                budgetBanner
                                    .padding(.top, AppTheme.Spacing.md)
                            }

                            // Coach financier — insights statistiques top 3
                            if !vm.insights.isEmpty {
                                InsightsCoachSection(insights: vm.insights)
                                    .padding(.horizontal, AppTheme.Spacing.lg)
                                    .padding(.top, AppTheme.Spacing.xxl)
                            }

                            if !vm.monthlyData.isEmpty {
                                monthlySection
                                    .padding(.horizontal, AppTheme.Spacing.lg)
                                    .padding(.top, AppTheme.Spacing.xxl)
                            }

                            if !vm.categoryData.isEmpty {
                                topCategoriesSection
                                    .padding(.horizontal, AppTheme.Spacing.lg)
                                    .padding(.top, AppTheme.Spacing.xxl)
                            }

                            if !vm.tagData.isEmpty {
                                tagSection
                                    .padding(.horizontal, AppTheme.Spacing.lg)
                                    .padding(.top, AppTheme.Spacing.xxl)
                            }
                        }
                    }
                }
                .padding(.bottom, AppTheme.Spacing.xxxl)
            }
        }
        .navigationTitle("Dashboard")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                // Recherche globale cross-modules (cmd-K style)
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                // Toggle rapide de masquage — discret mais toujours accessible
                // depuis le hub principal de l'app. Animation snappy pour confirmer
                // visuellement que le toggle a bien été pris en compte.
                Button {
                    HapticService.shared.toggle()
                    withAnimation(AppTheme.Animations.springSnappy) {
                        appState.amountsHidden.toggle()
                    }
                } label: {
                    Image(systemName: appState.amountsHidden ? "eye.slash.fill" : "eye")
                        .foregroundStyle(appState.amountsHidden ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                }
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(appState)
        }
        .sheet(isPresented: $showImport) {
            ImportV3EntryView().environment(appState)
        }
        .sheet(isPresented: $showSearch) {
            SearchView().environment(appState)
        }
        .task(id: appState.dataRefreshToken) {
            // 1-frame guard : laisse le skeleton se peindre au moins une fois
            // avant que `vm.load()` (synchrone SQLite) ne le remplace, sinon
            // sur une base déjà chaude on aurait un flash de la layout vide.
            await Task.yield()
            vm.load()
            hasLoaded = true
        }
    }

    // MARK: - Hero backdrop (gradient subtil sur le top)

    /// Dégradé accent → background sur 360pt en haut de l'écran. Donne l'impression
    /// que le hero "émerge" du chrome de l'app, sans introduire un bandeau coloré
    /// brutal. Opacité 0.18 en dark, 0.12 en light pour rester sobre.
    @ViewBuilder private var heroBackdrop: some View {
        LinearGradient(
            colors: [
                AppTheme.Colors.accent.opacity(0.18),
                AppTheme.Colors.background.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 360)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Skeleton

    @ViewBuilder private var skeletonContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            // Hero
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                SkeletonLine(width: 120, height: 11)
                SkeletonLine(width: 260, height: 40)
                SkeletonLine(width: 180, height: 14)
            }
            // Investments banner
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                SkeletonLine(width: 140, height: 11)
                SkeletonLine(width: 200, height: 24)
            }
            .appCardStyle()
            // Chart
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                SkeletonLine(width: 180, height: 13)
                SkeletonChart(height: 200)
            }
        }
    }

    // MARK: - Year Picker

    private var yearPicker: some View {
        HStack {
            Text("Exercice")
                .font(AppTheme.Typography.labelLarge)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Picker("Année", selection: Binding(
                get: { vm.selectedYear },
                set: { vm.selectYear($0) }
            )) {
                ForEach(availableYears, id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(AppTheme.Colors.accent)
        }
    }

    // MARK: - Editorial Hero

    /// Le bloc dominant de l'écran : solde net annuel en `displayLarge` + variation
    /// vs N-1 + mini-stats recettes/dépenses en pied. **Pas de card**, pas de fond
    /// — on laisse le dégradé du backdrop faire le travail. Aligné à gauche, typo
    /// XL pour donner du poids.
    @ViewBuilder private var editorialHero: some View {
        let net = vm.stats.netBalance
        let prevNet = vm.previousYearStats.netBalance
        let delta = net - prevNet
        let hasComparison = vm.previousYearStats.totalIncome != 0 || vm.previousYearStats.totalExpense != 0
        let deltaPercent: Double = {
            guard hasComparison, abs(prevNet) > 0.01 else { return 0 }
            return delta / abs(prevNet) * 100
        }()

        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            // Eyebrow label
            Text(periodEyebrow.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            // Big number : solde net annuel — passe par MoneyText pour respecter
            // le masquage global. Placeholder large pour conserver la prominence
            // visuelle du hero quand masqué.
            MoneyText(
                amount: net,
                font: .system(size: 44, weight: .bold, design: .default),
                color: AppTheme.Colors.textPrimary,
                maskedPlaceholder: "•• ••• €"
            )
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            // Variation vs N-1 (uniquement si on a une comparaison utile)
            if hasComparison {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: delta >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 11, weight: .bold))
                    Text(delta, format: .currency(code: "EUR").presentation(.narrow))
                        .font(.system(size: 14, weight: .semibold))
                    if abs(deltaPercent) > 0.01 {
                        Text(String(format: "%@%.1f %%", delta >= 0 ? "+" : "", deltaPercent))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text("vs \(vm.selectedYear - 1)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                .foregroundStyle(delta >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
            }

            // Pied : Recettes · Dépenses sur la même ligne, séparés par un point
            // médian. Évite les "stat badges" verticaux et garde une lecture fluide.
            HStack(spacing: AppTheme.Spacing.lg) {
                heroStatPill(
                    icon: "arrow.down.right",
                    label: "Recettes",
                    value: vm.stats.totalIncome,
                    color: AppTheme.Colors.success
                )
                heroStatPill(
                    icon: "arrow.up.right",
                    label: "Dépenses",
                    value: vm.stats.totalExpense,
                    color: AppTheme.Colors.danger
                )
            }
            .padding(.top, AppTheme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Petite "pilule" stat utilisée dans le pied du hero. Reste alignée gauche,
    /// pas de fond pour ne pas concurrencer le big number. Juste icône colorée +
    /// montant en `moneySmall` + label en très petit.
    @ViewBuilder
    private func heroStatPill(icon: String, label: String, value: Double, color: Color) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                MoneyText(
                    amount: abs(value),
                    font: AppTheme.Typography.moneySmall,
                    color: AppTheme.Colors.textPrimary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }
        }
    }

    private var periodEyebrow: String {
        if let month = vm.selectedMonthLabel { return "Bilan · \(month)" }
        return "Bilan annuel · \(vm.selectedYear)"
    }

    // MARK: - Investments banner

    /// Bandeau patrimoine — pleine largeur, fond cuivre subtil (accentSecondary
    /// à 0.10), tap = navigation vers l'onglet Investissements. Pose la "deuxième
    /// gravité" visuelle de l'écran après le hero financier.
    @ViewBuilder private var investmentsBanner: some View {
        let recap = vm.investmentsRecap
        Button {
            // Helper qui gère les 2 cas (tab visible direct vs caché dans More).
            appState.navigateToTab(.investments)
        } label: {
            HStack(spacing: AppTheme.Spacing.lg) {
                // Icône patrimoine dans une bulle cuivre.
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.Colors.accentSecondary.opacity(0.18), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("PATRIMOINE INVESTI")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    MoneyText(
                        amount: recap.totalCurrentValue,
                        font: AppTheme.Typography.moneyMedium,
                        color: AppTheme.Colors.textPrimary
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    if recap.totalInvested > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: recap.pnlAbsolute >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 9, weight: .bold))
                            Text(recap.pnlAbsolute, format: .currency(code: "EUR").presentation(.narrow))
                                .font(.system(size: 12, weight: .semibold))
                            Text(String(format: "%@%.2f %%", recap.pnlAbsolute >= 0 ? "+" : "", recap.pnlPercent))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(recap.pnlAbsolute >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                    } else {
                        Text("\(recap.activeAccountCount) compte\(recap.activeAccountCount > 1 ? "s" : "") actif\(recap.activeAccountCount > 1 ? "s" : "")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
            }
            .padding(.vertical, AppTheme.Spacing.lg)
            .padding(.horizontal, AppTheme.Spacing.lg)
            .background(
                LinearGradient(
                    colors: [
                        AppTheme.Colors.accentSecondary.opacity(0.10),
                        AppTheme.Colors.accentSecondary.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .strokeBorder(AppTheme.Colors.accentSecondary.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.Spacing.lg)
    }

    // MARK: - Patrimoine banner

    /// Bandeau Patrimoine net — symétrique au bandeau Investissements, posé juste
    /// dessous. Fond accent vert subtil pour le différencier du cuivre Investments,
    /// big number du patrimoine net, sous-titre brut/dettes, tap → onglet Patrimoine.
    /// Visible uniquement si l'user a au moins 1 item Patrimoine.
    @ViewBuilder private var patrimoineBanner: some View {
        let recap = vm.patrimoineRecap
        let isPositive = recap.netWorth >= 0
        Button {
            appState.navigateToTab(.patrimoine)
        } label: {
            HStack(spacing: AppTheme.Spacing.lg) {
                Image(systemName: "house.lodge.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 44, height: 44)
                    .background(AppTheme.Colors.accent.opacity(0.18), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("PATRIMOINE NET")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    MoneyText(
                        amount: recap.netWorth,
                        font: AppTheme.Typography.moneyMedium,
                        color: isPositive ? AppTheme.Colors.textPrimary : AppTheme.Colors.danger
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    // Sous-titre : brut + dettes — donne le détail sans avoir besoin
                    // d'ouvrir l'onglet, et matérialise pourquoi le net peut être
                    // négatif (dettes > actifs).
                    if recap.totalLiabilities > 0 {
                        HStack(spacing: 4) {
                            Text("\(recap.totalAssets.formatted(.currency(code: "EUR").presentation(.narrow))) brut")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.Colors.success)
                            Text("·")
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                            Text("\(recap.totalLiabilities.formatted(.currency(code: "EUR").presentation(.narrow))) dettes")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.Colors.danger)
                        }
                    } else {
                        Text("\(recap.itemsCount) élément\(recap.itemsCount > 1 ? "s" : "")")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
            }
            .padding(.vertical, AppTheme.Spacing.lg)
            .padding(.horizontal, AppTheme.Spacing.lg)
            .background(
                LinearGradient(
                    colors: [
                        AppTheme.Colors.accent.opacity(0.10),
                        AppTheme.Colors.accent.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .strokeBorder(AppTheme.Colors.accent.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.Spacing.lg)
    }

    // MARK: - Budget banner

    /// Bandeau "Budget du mois" — symétrique aux bandeaux Investissements et
    /// Patrimoine. Affiche le décompte healthy/warning/exceeded des enveloppes.
    /// Couleur dynamique : danger si dépassements, warning si ≥ 1 attention,
    /// success si tout est sous les 80 %.
    @ViewBuilder private var budgetBanner: some View {
        let recap = vm.budgetRecap
        let (statusIcon, statusColor): (String, Color) = {
            if recap.exceededCount > 0 { return ("xmark.octagon.fill", AppTheme.Colors.danger) }
            if recap.warningCount > 0 { return ("exclamationmark.triangle.fill", AppTheme.Colors.warning) }
            return ("checkmark.seal.fill", AppTheme.Colors.success)
        }()
        Button {
            appState.navigateToTab(.budget)
        } label: {
            HStack(spacing: AppTheme.Spacing.lg) {
                Image(systemName: statusIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 44, height: 44)
                    .background(statusColor.opacity(0.18), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("BUDGET DU MOIS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("\(recap.totalCount) enveloppe\(recap.totalCount > 1 ? "s" : "")")
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    HStack(spacing: 10) {
                        statusChip(count: recap.healthyCount, color: AppTheme.Colors.success, icon: "checkmark")
                        statusChip(count: recap.warningCount, color: AppTheme.Colors.warning, icon: "exclamationmark.triangle")
                        statusChip(count: recap.exceededCount, color: AppTheme.Colors.danger, icon: "xmark")
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.6))
            }
            .padding(.vertical, AppTheme.Spacing.lg)
            .padding(.horizontal, AppTheme.Spacing.lg)
            .background(
                LinearGradient(
                    colors: [statusColor.opacity(0.10), statusColor.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .strokeBorder(statusColor.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AppTheme.Spacing.lg)
    }

    @ViewBuilder
    private func statusChip(count: Int, color: Color, icon: String) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
        }
    }

    // MARK: - Monthly

    /// Section "Flux mensuel" en **pleine largeur sans card**. Le chart respire sur
    /// le fond de page, ce qui le rend plus présent qu'enfermé dans une carte
    /// rectangulaire.
    private var monthlySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionTitle(
                "FLUX MENSUEL",
                subtitle: vm.selectedMonth != nil
                    ? "Touchez une barre pour déselectionner"
                    : "Touchez un mois pour filtrer les catégories"
            )
            TipView(chartTip, arrowEdge: .none)
            MonthlyBarChartView(
                data: vm.monthlyData,
                selectedMonth: Binding(
                    get: { vm.selectedMonth },
                    set: { vm.toggleMonth($0 ?? "") }
                )
            )
            if let label = vm.selectedMonthLabel {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "calendar")
                        .font(.caption2)
                    Text("Filtre actif : \(label)")
                        .font(AppTheme.Typography.labelMedium)
                }
                .foregroundStyle(AppTheme.Colors.accent)
                .padding(.top, AppTheme.Spacing.xs)
                .onTapGesture {
                    withAnimation(AppTheme.Animations.spring) {
                        vm.selectedMonth = nil
                        vm.load()
                    }
                }
            }
        }
    }

    // MARK: - Top categories (list façon ranking, pas barchart)

    /// On remplace l'ancien `CategoryBarChartView` par une **liste éditoriale** des 5
    /// premières dépenses : numéro de rang, nom, montant, barre de progression
    /// proportionnelle au pourcentage du total. Beaucoup plus lisible et "premium"
    /// qu'un BarChart générique.
    private var topCategoriesSection: some View {
        let expenses = vm.categoryData
            .filter { $0.total < 0 }
            .sorted { abs($0.total) > abs($1.total) }
            .prefix(5)
        let maxAbs = expenses.map { abs($0.total) }.max() ?? 1

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(
                    "TOP DÉPENSES",
                    subtitle: vm.selectedMonthLabel.map { "Sur \($0)" } ?? "Sur l'année \(vm.selectedYear)"
                )
                Spacer()
                Toggle("Parente", isOn: $groupByParent)
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .tint(AppTheme.Colors.accent)
                    .font(AppTheme.Typography.labelMedium)
            }

            VStack(spacing: AppTheme.Spacing.md) {
                ForEach(Array(itemsForRanking(expenses: Array(expenses)).enumerated()), id: \.element.category) { idx, item in
                    rankRow(rank: idx + 1, item: item, maxAbs: maxAbs)
                }
            }
        }
    }

    /// Regroupe par parente si le toggle est ON, et garde le tri top-5.
    private func itemsForRanking(expenses: [CategoryTotal]) -> [CategoryTotal] {
        if !groupByParent { return expenses }
        var dict: [String: Double] = [:]
        for item in expenses {
            let key = item.parentCategory ?? item.category
            dict[key, default: 0] += item.total
        }
        return dict.map { CategoryTotal(category: $0.key, parentCategory: nil, total: $0.value) }
            .sorted { abs($0.total) > abs($1.total) }
    }

    /// Ligne d'un classement Top-Dépenses : rang + nom + barre progressive + montant.
    @ViewBuilder
    private func rankRow(rank: Int, item: CategoryTotal, maxAbs: Double) -> some View {
        let pct = maxAbs > 0 ? abs(item.total) / maxAbs : 0
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(rank).")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(width: 22, alignment: .leading)
                Text(item.category)
                    .font(AppTheme.Typography.titleSmall)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text(item.total, format: .currency(code: "EUR").presentation(.narrow))
                    .font(AppTheme.Typography.moneySmall)
                    .foregroundStyle(AppTheme.Colors.danger)
                    .lineLimit(1)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AppTheme.Colors.surfaceSecondary)
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AppTheme.Colors.dangerGradient)
                        .frame(width: max(8, geo.size.width * pct), height: 6)
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - Tags (chips, pas barchart)

    /// Remplace l'ancien `TagBarChartView` par des **chips fluides** — la donnée tag
    /// est mieux lue comme "étiquettes" qu'en barchart.
    private var tagSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionTitle(
                "TAGS",
                subtitle: vm.selectedMonthLabel.map { "Sur \($0)" } ?? "Sur l'année \(vm.selectedYear)"
            )
            FlowLayout(spacing: AppTheme.Spacing.sm) {
                ForEach(vm.tagData.prefix(15)) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.tag.displayColor)
                            .frame(width: 7, height: 7)
                        Text(item.tag.name)
                            .font(AppTheme.Typography.labelLarge)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                        Text(item.total, format: .currency(code: "EUR").presentation(.narrow))
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(item.total < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    }
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(AppTheme.Colors.surfaceSecondary.opacity(0.7))
                    )
                }
            }
        }
    }

    // MARK: - Section title helper

    /// Eyebrow uppercased + subtitle en text secondaire. Cohérent dans tous les
    /// blocs pour maintenir une grammaire éditoriale.
    @ViewBuilder
    private func sectionTitle(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.85))
            }
        }
    }
}

// MARK: - FlowLayout (wrapping chips horizontal)

/// Layout horizontal avec retour à la ligne automatique. Utilisé pour les chips
/// de tags. Implémentation minimaliste basée sur `Layout` (iOS 16+).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth, lineWidth > 0 {
                totalHeight += lineHeight + spacing
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : lineWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Onboarding empty state

private struct OnboardingImportCard: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(AppTheme.Colors.success.opacity(0.12))
                    .frame(width: 80, height: 80)
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(AppTheme.Colors.success)
            }
            VStack(spacing: AppTheme.Spacing.sm) {
                Text("Commencez par importer vos données")
                    .font(AppTheme.Typography.titleMedium)
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Exportez le relevé de votre compte bancaire au format CSV depuis votre banque en ligne, puis importez-le ici pour commencer à suivre vos finances.")
                    .font(AppTheme.Typography.bodySmall)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: action) {
                Label("Importer un fichier CSV", systemImage: "square.and.arrow.down")
                    .font(AppTheme.Typography.labelLarge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppTheme.Spacing.xl)
                    .padding(.vertical, AppTheme.Spacing.md)
                    .background(AppTheme.Colors.success, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppTheme.Spacing.xxxl)
        .padding(.top, 60)
    }
}
