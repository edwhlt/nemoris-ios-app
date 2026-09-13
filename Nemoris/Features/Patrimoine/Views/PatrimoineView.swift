import SwiftUI

// MARK: - PatrimoineView
//
// The Patrimoine module's root view. A functional "Movable Assets & Cash"
// section (create / edit / delete assets + linking to existing
// accounts). Real Estate / Loans / Global net-worth sections stay
// hidden until implemented.
//
// A visual pattern aligned with the redesigned Dashboard: no cards-everywhere,
// uppercased eyebrows to structure sections, full-width rows with
// the value on the right.

struct PatrimoineView: View {
    @Environment(AppState.self) private var appState
    @Environment(PurchaseManager.self) private var store
    @State private var vm = PatrimoineViewModel()

    // Sheets — actifs
    @State private var showCreateAsset = false
    @State private var editingAsset: PatrimoineAsset? = nil
    @State private var assetToDelete: PatrimoineAsset? = nil

    // Sheets — biens immobiliers
    @State private var showCreateRealEstate = false
    @State private var editingRealEstate: PatrimoineRealEstate? = nil
    @State private var realEstateToDelete: PatrimoineRealEstate? = nil

    // Sheets — loans
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

    /// The body is split into layers (coreContent → panesLayer → navBody):
    /// a single expression exceeded the Swift type checker's budget after
    /// the macOS detail panes were added (adaptiveEntityPane ×4).
    private var coreContent: some View {
        Group {
            if vm.assets.isEmpty && vm.realEstates.isEmpty && vm.loans.isEmpty {
                // A full-page empty state — a plain ScrollView is kept so as not
                // to show an empty List when an editorial intro is wanted instead.
                ZStack {
                    AppTheme.Colors.background.ignoresSafeArea()
                    ScrollView {
                        emptyState
                            .padding(.top, AppTheme.Spacing.xxxl)
                            .padding(.horizontal, AppTheme.Spacing.lg)
                    }
                }
            } else {
                // A native List — each row can be deleted via trailing swipe and
                // edited via leading swipe. Rows keep their "floating card" look
                // via `listRowBackground(.clear)` + `listRowSeparator(.hidden)`.
                List {
                    // The global net-worth hero (1st section, natural scroll).
                    // ⚠️ `.macGroupedRow` (NOT a custom `.listRowInsets`/`.background`):
                    // it's the SAME mechanism as the goals/movable-assets/real-estate/
                    // loans rows below (and Tricount/ReferenceData/Investments) —
                    // guarantees this card has exactly the same left/right edge and
                    // the same corner radius as every other one on screen (the cards
                    // weren't aligned with each other, each section reinvented its own
                    // margin/radius). The gradient
                    // becomes the card's background, the way `AppTheme.Colors.surface` is
                    // for a normal row.
                    Section {
                        heroSection
                            .listRowSeparator(.hidden)
                            .macGroupedRow(first: true, last: true) {
                                LinearGradient(
                                    colors: [
                                        AppTheme.Colors.accent.opacity(0.18),
                                        AppTheme.Colors.accent.opacity(0.04)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            }
                    }
                    // A "broken links" banner if at least 1 linked asset lost its
                    // source account (a SET NULL cascade). Shown between the hero and the
                    // donut to be impossible to miss but without blocking the scroll.
                    if vm.hasBrokenLinks {
                        Section {
                            brokenLinksBanner
                                .listRowSeparator(.hidden)
                                .macGroupedRow(first: true, last: true) {
                                    AppTheme.Colors.warning.opacity(0.08)
                                }
                        }
                    }
                    // Financial goals — shown at high priority (right under
                    // the hero) to convey "where I'm going" before "what I have".
                    goalsListSection
                    // The allocation donut (visible only if there's gross assets to show)
                    if vm.snapshot.totalAssets > 0 {
                        Section {
                            allocationCard
                                .listRowSeparator(.hidden)
                                .macGroupedRow(first: true, last: true)
                        }
                    }
                    mobilierListSection
                    immobilierListSection
                    pretsListSection
                }
                #if os(macOS)
                // macOS: .plain = a neutral base for the custom cards drawn by
                // macGroupedRow (first/last rounded corners, inset, internal
                // separators). iOS keeps its native insetGrouped — macGroupedRow there
                // only sets the listRowBackground (see TransactionsView, the same pattern).
                .listStyle(.plain)
                .macGroupedListTopGap()
                #else
                // iOS: the screen stacks 7 `Section`s (hero, broken links, goals,
                // donut, movable assets, real estate, loans) — without this modifier, the
                // system's spacing between `.insetGrouped` sections (~35pt) piles up at
                // every boundary and gives a "disjointed" screen compared to modules
                // that group their content more tightly.
                .listSectionSpacing(.compact)
                #endif
                .scrollContentBackground(.hidden)
                .background(AppTheme.Colors.background)
            }
        }
        .localizedNavigationTitle("Patrimoine")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            #if os(macOS)
            // macOS: the "+" menu is spread into icon-only buttons + a
            // native tooltip, grouped in ONE pill (ControlGroup).
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                PaneToggleButton(label: "Nouvel actif", systemImage: "banknote.fill", isOn: $showCreateAsset)
                PaneToggleButton(label: "Nouveau bien", systemImage: "house.fill", isOn: $showCreateRealEstate)
                PaneToggleButton(label: "Nouveau prêt", systemImage: "creditcard.fill", isOn: $showCreateLoan)
                PaneToggleButton(label: "Nouvel objectif", systemImage: "target", isOn: $showCreateGoal)
            }
            #else
            ToolbarItem(placement: .navigationBarTrailing) {
                // The toolbar "+" becomes a Menu now that there are 2 entry
                // types (a liquid asset vs. a real-estate property). A future step will add "Loan" here.
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
            #endif
        }
    }

    /// The cluster of presentations (creation panes + detail/edit).
    private var panesLayer: some View {
        coreContent
        .adaptivePane(isPresented: $showCreateAsset) {
            AssetFormView(viewModel: vm, existingAsset: nil)
                .environment(appState)
        }
        .adaptiveEntityPane(
            item: $editingAsset,
            title: "Actif",
            refresh: { a in vm.assets.first { $0.id == a.id } },
            onDelete: { assetToDelete = $0 }
        ) { asset in
            AssetDetailPane(asset: asset, vm: vm)
        } edit: { asset in
            AssetFormView(viewModel: vm, existingAsset: asset)
                .environment(appState)
        }
        .adaptivePane(isPresented: $showCreateRealEstate) {
            RealEstateFormView(viewModel: vm, existingItem: nil)
                .environment(appState)
        }
        .adaptiveEntityPane(
            item: $editingRealEstate,
            title: "Bien immobilier",
            refresh: { r in vm.realEstates.first { $0.id == r.id } },
            onDelete: { realEstateToDelete = $0 }
        ) { item in
            RealEstateDetailPane(item: item)
        } edit: { item in
            RealEstateFormView(viewModel: vm, existingItem: item)
                .environment(appState)
        }
        .adaptivePane(isPresented: $showCreateLoan) {
            LoanFormView(viewModel: vm, existingLoan: nil)
                .environment(appState)
        }
        .adaptiveEntityPane(
            item: $editingLoan,
            title: "Prêt",
            refresh: { l in vm.loans.first { $0.id == l.id } },
            onDelete: { loanToDelete = $0 }
        ) { loan in
            LoanDetailPane(loan: loan, realEstates: vm.realEstates)
        } edit: { loan in
            LoanFormView(viewModel: vm, existingLoan: loan)
                .environment(appState)
        }
        .adaptivePane(isPresented: $showCreateGoal) {
            GoalFormView(viewModel: vm, existingGoal: nil)
                .environment(appState)
        }
        .adaptiveEntityPane(
            item: $editingGoal,
            title: "Objectif",
            refresh: { g in vm.goals.first { $0.id == g.id } },
            onDelete: { goalToDelete = $0 }
        ) { goal in
            GoalDetailPane(goal: goal)
        } edit: { goal in
            GoalFormView(viewModel: vm, existingGoal: goal)
                .environment(appState)
        }
        .adaptivePane(isPresented: $showProjection) {
            ProjectionView(viewModel: vm)
                .environment(appState)
        }
    }

    @ViewBuilder private var navBody: some View {
        panesLayer
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

    // MARK: - Editorial hero (global net Patrimoine)

    /// A full-width hero at the top of the List: an eyebrow + a 44pt big number of net
    /// worth + Gross/Debts subtotals + a leverage bar (debt/gross assets).
    /// Consistent with DashboardView's editorial hero.
    @ViewBuilder private var heroSection: some View {
        let snap = vm.snapshot
        let isPositive = snap.netWorth >= 0
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            // A dated eyebrow — gives the temporal context with no need for a
            // period picker (the snapshot always reflects "now").
            let now = Date().formatted(.dateTime.month(.wide).year().locale(AppLocalization.locale))
            Text("Patrimoine net · \(now)")
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            // The big number — a dynamic color (green if positive, terracotta if negative).
            // 44pt bold to compete with the Dashboard hero and rank this screen.
            MoneyText(
                amount: snap.netWorth,
                font: .system(size: 44, weight: .bold, design: .default),
                color: isPositive ? AppTheme.Colors.textPrimary : AppTheme.Colors.danger,
                maskedPlaceholder: "•• ••• €"
            )
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            // Gross/Debts subtotals aligned horizontally
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

            // A "leverage" bar — visually conveys the debt/gross-asset ratio.
            // Shown only if there's actually some debt (otherwise it's noise).
            if snap.totalLiabilities > 0 {
                leverageBar
                    .padding(.top, AppTheme.Spacing.sm)
            }

            // A "5-year projection" button — discreet but accessible. Shown if
            // there's something to project (a non-empty snapshot).
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
                        if !store.isUnlocked(.patrimoineProjection) {
                            ProBadge()
                        }
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
        // ⚠️ The background (gradient) is provided by `.macGroupedRow(...)` AT THE CALL SITE,
        // NOT here — see the comment at the call in `coreContent`. Before, this
        // background was drawn internally (`.background` + a border `.overlay`) while
        // the call site ALSO set its own custom `.listRowInsets`: two
        // different margin/rounding mechanisms for the same card, never
        // guaranteed identical to the `.macGroupedRow` rows below (goals,
        // movable assets…) — hence cards that were visibly misaligned/at a
        // different radius on iOS. By going through `.macGroupedRow`, the hero shares
        // EXACTLY the same margin/rounding mechanism as every other
        // card on screen (and Tricount/ReferenceData/Investments).
    }

    /// The hero's Gross / Debts subtotals — a colored icon + an uppercased label + a value.
    @ViewBuilder
    private func heroSubtotal(icon: String, label: LocalizedStringKey, value: Double, color: Color) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26, height: 26)
                .background(color.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .textCase(.uppercase)
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

    /// A leverage bar: shows what proportion of gross assets is funded by
    /// debt. > 50% = a visual warning, > 100% = danger (liabilities > assets).
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
                Text("Dette / actif brut · \(ratioPercent.formatted(.number.precision(.fractionLength(1)))) %")
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

    /// A warning banner at the top of the List when at least 1 linked asset lost its
    /// source account (the account was deleted). The asset stays shown with its
    /// `lastKnownValue` but no longer updates. Tapping opens the first affected
    /// asset so the user can relink it or switch it back to manual.
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
            // A background provided by `.macGroupedRow(...)` at the call site — see
            // `heroSection`'s detailed comment, the same fix.
        }
        .buttonStyle(.plain)
    }

    // MARK: - Gross asset allocation (donut + legend)

    /// A "Composition of your net worth" card: a donut + a vertical legend reusing
    /// the Investments module's `AllocationDonutChart`. Slices = totals per asset
    /// category (Liquid movable assets, Real estate). Debts are deliberately
    /// **excluded** — the donut represents GROSS assets, not the net (already
    /// shown prominently in the hero).
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
        // A background provided by `.macGroupedRow(...)` at the call site — see
        // `heroSection`'s detailed comment, the same fix (and it's already exactly
        // `.macGroupedRow()`'s default background, `AppTheme.Colors.surface`).
    }

    /// Builds the donut's slices. Movable assets (every asset, whatever
    /// its kind) and Real estate are grouped into 2 broad categories so as
    /// not to saturate the donut. Splitting by AssetKind could be added later if the user
    /// wants it (a toggle in the card).
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

    // `EmptyStateView` (icon/title/message) is the single mechanism for
    // empty screens — see CLAUDE.md §5. Patrimoine needs two extra CTAs
    // (Asset/Property), hence the `actions` slot rather than a custom empty
    // state that stood out (an 88pt tinted circle vs. a flat icon, titleLarge vs.
    // titleMedium) from the other modules.
    @ViewBuilder private var emptyState: some View {
        EmptyStateView(
            icon: "house.fill",
            title: "Construisez votre patrimoine",
            message: "Commencez par ajouter un actif liquide (livret, compte épargne, PEA…) en mode lié pour suivre automatiquement sa valeur, ou saisissez-le à la main."
        ) {
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
    }

    /// A unified section header: an uppercased eyebrow + a total in `moneyMedium`
    /// (a configurable color to tell assets and liabilities apart) + an
    /// optional addition on the right (an item count, monthly cost, aggregated gain).
    ///
    /// Centralized here rather than duplicated in every section.
    @ViewBuilder
    private func sectionHeader(eyebrow: LocalizedStringKey,
                               total: Double,
                               accent: Color,
                               trailingNote: Text? = nil,
                               gainChip: Double? = nil,
                               hideTotal: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                // For sections with no relevant monetary total (e.g. "GOALS",
                // which has no meaningful "sum"), the figure line is hidden.
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
                note
                    .font(AppTheme.Typography.labelMedium)
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
        .textCase(nil)  // SwiftUI uppercases section headers by default — turned off
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    // MARK: - Goals section

    /// A "Goals" section at the top of the Patrimoine collections. Shown only
    /// if the user has at least 1 goal — otherwise nothing is shown (header included) to
    /// stay consistent with the other sections' pattern.
    ///
    /// The toolbar's "+" Menu stays the single entry point to create one.
    @ViewBuilder private var goalsListSection: some View {
        if !vm.goals.isEmpty {
            Section {
                ForEach(vm.goals) { goal in
                    goalRow(goal)
                        // ⚠️ Identity PREFIXED by type (see `mobilierListSection`):
                        // goal/asset/property/loan share `id: Int`s that
                        // overlap, and macOS's `List` (NSTableView) recycles its
                        // rows BY IDENTITY across EVERY section — without a
                        // prefix, a goal row showed up in the assets or
                        // loans section. iOS scopes by section, hence a bug
                        // invisible on mobile.
                        .id("goal-\(goal.id)")
                        .rowActions(
                            leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { editingGoal = goal }],
                            trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { goalToDelete = goal }],
                            leadingFullSwipe: false,
                            trailingFullSwipe: false
                        )
                        .macGroupedRow(first: goal.id == vm.goals.first?.id, last: goal.id == vm.goals.last?.id)
                }
            } header: {
                sectionHeader(
                    eyebrow: "OBJECTIFS",
                    total: 0,                                  // No relevant monetary total here
                    accent: AppTheme.Colors.textPrimary,
                    trailingNote: Text("\(vm.goals.count) objectif\(vm.goals.count > 1 ? "s" : "")"),
                    hideTotal: true                            // Hides the €0 — irrelevant
                )
                .macGroupedSectionHeader()
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
                // Line 1: icon + name + % reached
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
                        goalSubtitle(goal: goal, progress: progress)
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

                // Line 2: a progress bar with a dynamic color depending on state
                // (success if reached, warning if overdue, accent green otherwise)
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

                    // Line 3: current / target + required monthly payment (if there's a deadline)
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
        }
        .buttonStyle(.plain)
    }

    /// A goal row's subtitle: the kind label + deadline status + a contextual hint.
    /// For a debt_payoff at 0% an explanatory note is added ("Baseline captured…")
    /// so the user doesn't think it's broken.
    private func goalSubtitle(goal: Goal, progress: GoalProgress?) -> Text {
        var parts: [Text] = [Text(LocalizedStringKey(goal.kind.label))]
        if let progress, progress.isCompleted {
            parts.append(Text("Atteint ✓"))
        } else if let days = progress?.daysRemaining {
            if days < 0 {
                parts.append(Text("En retard de \(abs(days)) j"))
            } else if days == 0 {
                parts.append(Text("Échéance aujourd'hui"))
            } else if days < 365 {
                parts.append(Text("Dans \(days) j"))
            } else {
                let years = days / 365
                parts.append(Text("Dans ~\(years) an\(years > 1 ? "s" : "")"))
            }
        }
        // A teaching hint for a debt_payoff at 0%: the calculation is correct but
        // counter-intuitive (it's at 0% because nothing has been paid off
        // **since the goal was created**, not since the start of the loan).
        if goal.kind == .debtPayoff, let progress, progress.ratio == 0 {
            parts.append(Text("Point de départ"))
        }
        return parts.dropFirst().reduce(parts.first ?? Text("")) { result, part in
                result + Text(" · ") + part
        }
    }

    // MARK: - Movable Assets & Cash section (a native List)

    @ViewBuilder private var mobilierListSection: some View {
        // A section fully hidden when empty (header + content) — avoids an
        // orphaned header. Creation happens via the toolbar's "+" Menu.
        if !vm.assets.isEmpty {
            Section {
                ForEach(vm.assets) { asset in
                    assetRow(asset)
                        // A prefixed identity — see `goalsListSection` (an id collision
                        // between collections + macOS's NSTableView recycling).
                        .id("asset-\(asset.id)")
                        // Actions adaptatives : swipe iOS / clic droit macOS (cf. RowActions).
                        .rowActions(
                            leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { editingAsset = asset }],
                            trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { assetToDelete = asset }],
                            leadingFullSwipe: false,
                            trailingFullSwipe: false
                        )
                        .macGroupedRow(first: asset.id == vm.assets.first?.id, last: asset.id == vm.assets.last?.id)
                }
            } header: {
                sectionHeader(
                    eyebrow: "MOBILIER & LIQUIDITÉS",
                    total: vm.totalAssetsValue,
                    accent: AppTheme.Colors.textPrimary,
                    trailingNote: Text("\(vm.assets.count) actif\(vm.assets.count > 1 ? "s" : "")")
                )
                .macGroupedSectionHeader()
            }
        }
    }

    // MARK: - Section Immobilier (List native)

    @ViewBuilder private var immobilierListSection: some View {
        if !vm.realEstates.isEmpty {
            Section {
                ForEach(vm.realEstates) { item in
                    realEstateRow(item)
                        // A prefixed identity — see `goalsListSection`.
                        .id("realestate-\(item.id)")
                        .rowActions(
                            leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { editingRealEstate = item }],
                            trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { realEstateToDelete = item }],
                            leadingFullSwipe: false,
                            trailingFullSwipe: false
                        )
                        .macGroupedRow(first: item.id == vm.realEstates.first?.id, last: item.id == vm.realEstates.last?.id)
                }
            } header: {
                sectionHeader(
                    eyebrow: "IMMOBILIER",
                    total: vm.totalRealEstateValue,
                    accent: AppTheme.Colors.textPrimary,
                    gainChip: vm.totalRealEstateCapitalGain == 0 ? nil : vm.totalRealEstateCapitalGain
                )
                .macGroupedSectionHeader()
            }
        }
    }

    // (addRealEstateCard removed — creation via the toolbar's "+" Menu only.)

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
                    realEstateSubtitle(item)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(item.currentValue, format: .currency(code: "EUR").presentation(.narrow))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)

                    // A mini gain chip (+X € / +Y%) if the user entered a purchase
                    // price — otherwise hidden (not relevant).
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
        }
        .buttonStyle(.plain)
        // The contextMenu was removed in favor of native swipeActions (configured on the
        // List's side in immobilierListSection).
    }

    /// An educational subtitle: "Bought €240,000 in Oct. 2018" + the address if entered.
    ///
    /// Returns a `Text` (not a `String`): `.formatted()` called directly on a
    /// value outside a `Text(_:format:)` ignores the app-forced environment
    /// `\.locale` and falls back to the device's ACTUAL locale — hence a mix of
    /// "36 323,38 €" / "€1,041.69" on screen when the iPhone is set to English (see
    /// CLAUDE.md "iPhone in English, FR-first app"). `Text(_:format:)` alone respects the environment.
    private func realEstateSubtitle(_ item: PatrimoineRealEstate) -> Text {
        let price: Text = item.purchasePrice > 0
            ? Text(item.purchasePrice, format: .currency(code: "EUR").presentation(.narrow))
            : Text("—")
        let date = Text(item.purchaseDate, format: .dateTime.month(.abbreviated).year())
        let baseLine = Text("Acheté ") + price + Text(" en ") + date
        if let address = item.address, !address.isEmpty {
            // The first address line is kept, to avoid cluttering the row.
            let firstLine = address.split(separator: "\n").first.map(String.init) ?? address
            return baseLine + Text(" · \(firstLine)")
        }
        return baseLine
    }

    // MARK: - Loans & Debts section (a native List)

    @ViewBuilder private var pretsListSection: some View {
        if !vm.loans.isEmpty {
            Section {
                ForEach(vm.loans) { loan in
                    loanRow(loan)
                        // A prefixed identity — see `goalsListSection`.
                        .id("loan-\(loan.id)")
                        .rowActions(
                            leading: [RowAction("Modifier", systemImage: "pencil", tint: AppTheme.Colors.accent) { editingLoan = loan }],
                            trailing: [RowAction("Supprimer", systemImage: "trash", role: .destructive) { loanToDelete = loan }],
                            leadingFullSwipe: false,
                            trailingFullSwipe: false
                        )
                        .macGroupedRow(first: loan.id == vm.loans.first?.id, last: loan.id == vm.loans.last?.id)
                }
            } header: {
                // A debt header: the amount in danger (terracotta) + the total monthly cost
                // (payments + insurance) in a chip to convey the liability's "weight".
                sectionHeader(
                    eyebrow: "PRÊTS & DETTES",
                    total: vm.totalLoansRemainingCapital,
                    accent: AppTheme.Colors.danger,
                    trailingNote: vm.totalMonthlyLoanCost > 0
                        ? Text(vm.totalMonthlyLoanCost, format: .currency(code: "EUR").presentation(.narrow)) + Text(" / mois")
                        : Text("\(vm.loans.count) prêt\(vm.loans.count > 1 ? "s" : "")")
                )
                .macGroupedSectionHeader()
            }
        }
    }

    // (addLoanCard removed — creation via the toolbar's "+" Menu only.)

    @ViewBuilder
    private func loanRow(_ loan: PatrimoineLoan) -> some View {
        let state = vm.loanStates[loan.id]
        Button {
            editingLoan = loan
        } label: {
            VStack(spacing: AppTheme.Spacing.sm) {
                // The main line: icon + name + remaining principal.
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
                        loanSubtitle(loan)
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
                        // Monthly cost = the loan payment + insurance (if entered).
                        // Shown on 1 line so as not to stretch the row, with a
                        // "+ ins." tooltip to convey the presence of insurance.
                        if let state, !state.isPending && !state.isCompleted {
                            let totalMonthly = state.monthlyPayment + loan.insuranceMonthly
                            if totalMonthly > 0 {
                                (Text(totalMonthly, format: .currency(code: "EUR").presentation(.narrow)) + Text(" / mois"))
                                    .font(AppTheme.Typography.labelMedium)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                if loan.insuranceMonthly > 0 {
                                    (Text("dont ") + Text(loan.insuranceMonthly, format: .currency(code: "EUR").presentation(.narrow)) + Text(" d'assurance"))
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(AppTheme.Colors.warning)
                                }
                            }
                        }
                    }
                }

                // A % repaid progress bar — instantly visualizes the loan's
                // progress. Hidden for REVOLVING (not relevant) and for loans
                // not yet started (a pending state).
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
                        Text("\(Int((state.progressRatio * 100).rounded())) % remboursé")
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Spacer()
                        Text("Mois \(state.monthsElapsed) / \(loan.durationMonths)")
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        // The contextMenu was removed in favor of native swipeActions (configured on the
        // List's side in pretsListSection).
    }

    /// A loan row's subtitle: type + duration + the linked property if applicable.
    private func loanSubtitle(_ loan: PatrimoineLoan) -> Text {
        var parts: [Text] = [Text(LocalizedStringKey(loan.loanType.label))]
        if loan.loanType != .revolving {
            let years = loan.durationMonths / 12
            let rem = loan.durationMonths % 12
            if years > 0 && rem == 0 {
                parts.append(Text("\(years) an\(years > 1 ? "s" : "")"))
            } else if years > 0 {
                parts.append(Text("\(years) an\(years > 1 ? "s" : "") \(rem) mois"))
            } else {
                parts.append(Text("\(loan.durationMonths) mois"))
            }
            if loan.annualRate > 0 {
                parts.append(Text(String(format: "%.2f %%", loan.annualRate * 100)))
            }
        }
        if let realEstateName = vm.realEstateName(forLoanLinked: loan.linkedRealEstateId) {
            parts.append(Text("→ \(realEstateName)"))
        }
        return parts.dropFirst().reduce(parts.first ?? Text("")) { result, part in
                result + Text(" · ") + part
        }
    }

    // (addAssetCard removed — creation via the toolbar's "+" Menu only.)

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
                        // A contextual badge depending on the resolved source.
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
        }
        .buttonStyle(.plain)
        // The contextMenu was removed in favor of native swipeActions (configured on the
        // List's side in mobilierListSection).
    }

    /// A small pictogram to the right of the name that instantly conveys the value's
    /// source (an active link, manual, a broken link). Saves the user from reading the
    /// subtitle to understand the state.
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
            // An explicit warning triangle — the `link.badge.plus` icon was too
            // discreet and confused with "active link". This one clearly signals
            // a user action is needed (fix it or switch back to manual).
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

    // (The "Coming soon" teaser was removed — every section is now
    //  implemented: Movable assets, Real estate, Loans, the global view via the hero.)
}

#Preview {
    PatrimoineView()
        .environment(AppState())
}

// MARK: - macOS detail panes (Patrimoine)

/// A read-only detail of an asset — the "view" mode of the macOS pane.
/// Never instantiated on iOS (there, tapping opens editing directly as a sheet).
private struct AssetDetailPane: View {
    let asset: PatrimoineAsset
    let vm: PatrimoineViewModel

    private var resolvedValue: Double {
        asset.isLinked ? asset.lastKnownValue : asset.manualValue
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: asset.assetKind.systemIcon)
                        .font(.title3)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.Colors.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.name).font(AppTheme.Typography.bodyMedium)
                        Text(LocalizedStringKey(asset.assetKind.label))
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Text(resolvedValue, format: .currency(code: "EUR"))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                .padding(.vertical, 2)
            }

            Section("Détails") {
                LabeledContent("Famille", value: asset.assetKind.label)
                LabeledContent("Valeur") { Text(resolvedValue, format: .currency(code: "EUR")) }
                LabeledContent("Source", value: asset.isLinked ? "Compte lié (auto)" : "Saisie manuelle")
                LabeledContent("Créé le") { Text(asset.createdAt, format: Date.FormatStyle(date: .abbreviated, time: .omitted)) }
            }

            if let notes = asset.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes).font(AppTheme.Typography.bodySmall)
                }
            }
        }
        .nemorisFormStyle()
    }
}

/// A read-only detail of a real-estate property — the "view" mode of the macOS pane.
private struct RealEstateDetailPane: View {
    let item: PatrimoineRealEstate

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "house.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.Colors.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(AppTheme.Typography.bodyMedium)
                        if let address = item.address, !address.isEmpty {
                            Text(address)
                                .font(AppTheme.Typography.labelSmall)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(item.currentValue, format: .currency(code: "EUR"))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                .padding(.vertical, 2)
            }

            Section("Valorisation") {
                LabeledContent("Prix d'achat") { Text(item.purchasePrice, format: .currency(code: "EUR")) }
                LabeledContent("Valeur actuelle") { Text(item.currentValue, format: .currency(code: "EUR")) }
                LabeledContent("Plus-value") {
                    (Text(item.capitalGain >= 0 ? "+" : "") + Text(item.capitalGain, format: .currency(code: "EUR")) + Text(" (\(String(format: "%.1f", item.capitalGainPercent)) %)"))
                        .foregroundStyle(item.capitalGain >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                }
            }

            Section("Dates") {
                LabeledContent("Achat") { Text(item.purchaseDate, format: Date.FormatStyle(date: .abbreviated, time: .omitted)) }
                if let estimated = item.estimatedAt {
                    LabeledContent("Dernière estimation") { Text(estimated, format: Date.FormatStyle(date: .abbreviated, time: .omitted)) }
                }
            }

            if let notes = item.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes).font(AppTheme.Typography.bodySmall)
                }
            }
        }
        .nemorisFormStyle()
    }
}

/// A read-only detail of a loan — the "view" mode of the macOS pane.
private struct LoanDetailPane: View {
    let loan: PatrimoineLoan
    let realEstates: [PatrimoineRealEstate]

    private var linkedRealEstateName: String? {
        guard let id = loan.linkedRealEstateId else { return nil }
        return realEstates.first { $0.id == id }?.name
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "creditcard.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.Colors.warning)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.Colors.warning.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loan.name).font(AppTheme.Typography.bodyMedium)
                        Text(LocalizedStringKey(loan.loanType.label))
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Text(loan.principal, format: .currency(code: "EUR"))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(AppTheme.Colors.warning)
                }
                .padding(.vertical, 2)
            }

            Section("Conditions") {
                LabeledContent {
                    Text(LocalizedStringKey(loan.loanType.label))
                } label: {
                    Text("Type")
                }
                LabeledContent("Capital emprunté") { Text(loan.principal, format: .currency(code: "EUR")) }
                LabeledContent("Taux annuel", value: String(format: "%.2f %%", loan.annualRate * 100))
                LabeledContent {
                    Text("\(loan.durationMonths) mois")
                } label: {
                    Text("Durée")
                }
                if loan.deferralMonths > 0 {
                    LabeledContent("Différé", value: "\(loan.deferralMonths) mois")
                }
                if loan.insuranceMonthly > 0 {
                    LabeledContent("Assurance") { Text(loan.insuranceMonthly, format: .currency(code: "EUR")) + Text(" / mois") }
                }
            }

            Section("Détails") {
                LabeledContent("Début") { Text(loan.startDate, format: Date.FormatStyle(date: .abbreviated, time: .omitted)) }
                if let linkedRealEstateName {
                    LabeledContent("Bien financé", value: linkedRealEstateName)
                }
            }

            if let notes = loan.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes).font(AppTheme.Typography.bodySmall)
                }
            }
        }
        .nemorisFormStyle()
    }
}

/// A read-only detail of a goal — the "view" mode of the macOS pane.
private struct GoalDetailPane: View {
    let goal: Goal

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: goal.kind.systemIcon)
                        .font(.title3)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.Colors.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(goal.name).font(AppTheme.Typography.bodyMedium)
                        Text(LocalizedStringKey(goal.kind.label))
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Text(goal.targetAmount, format: .currency(code: "EUR"))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                .padding(.vertical, 2)
            }

            Section("Détails") {
                LabeledContent {
                    Text(LocalizedStringKey(goal.kind.label))
                } label: {
                    Text("Type")
                }
                LabeledContent("Objectif") { Text(goal.targetAmount, format: .currency(code: "EUR")) }
                if goal.kind == .custom {
                    LabeledContent("Montant atteint") { Text(goal.customCurrentAmount, format: .currency(code: "EUR")) }
                }
                if let deadline = goal.deadlineDate {
                    LabeledContent("Échéance") { Text(deadline, format: Date.FormatStyle(date: .abbreviated, time: .omitted)) }
                }
                LabeledContent("Créé le") { Text(goal.createdAt, format: Date.FormatStyle(date: .abbreviated, time: .omitted)) }
            }

            if let notes = goal.notes, !notes.isEmpty {
                Section("Notes") {
                    Text(notes).font(AppTheme.Typography.bodySmall)
                }
            }
        }
        .nemorisFormStyle()
    }
}
