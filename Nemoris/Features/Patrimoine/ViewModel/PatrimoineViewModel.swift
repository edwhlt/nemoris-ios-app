import Foundation
import Observation

// MARK: - PatrimoineViewModel
//
// The main VM for the Patrimoine module. Orchestrates:
//   • the 3 persisted collections (assets / real estate / loans)
//   • the dynamic resolution of values linked to existing accounts
//   • the opportunistic persistence of `last_known_value` for linked assets
//
// Only assets are truly "live" (loading + resolution) for now. Real estate
// and loans are loaded but not yet consumed by the UI — their
// sections come later. Everything is loaded right away to avoid
// scattering partial `load()`s over time.

/// The provenance of an asset's resolved value. Used to show a contextual badge
/// in the list (linked, manual, a broken link).
enum AssetValueSource {
    case manual              // A standalone mode, a value entered by the user
    case linkedAccount       // Linked to a bank account (Account)
    case linkedInvestment    // Linked to an investment account (InvestmentAccount)
    case brokenLink          // The linked ID still exists in memory but the account can't be found
                             // (an edge case — SQL should have SET NULL on the delete cascade)
}

@Observable
final class PatrimoineViewModel {

    // MARK: - State persistant

    var assets: [PatrimoineAsset] = []
    var realEstates: [PatrimoineRealEstate] = []
    var loans: [PatrimoineLoan] = []

    /// A cache of "transactions" accounts — used by the picker, the "Linked to:
    /// Livret A" label, and to quickly check that a link points to an account that
    /// still exists.
    var availableBankAccounts: [Account] = []

    /// A cache of investment accounts — the same use.
    var availableInvestmentAccounts: [InvestmentAccount] = []

    /// Resolved values: assetId → the current value. Recomputed on every `load()`.
    /// The map is kept rather than recomputing on every UI access: this avoids
    /// hitting the database again on every list scroll.
    var resolvedAssetValues: [Int: Double] = [:]

    /// A resolved value's source per asset — useful for badges in the UI.
    var resolvedAssetSources: [Int: AssetValueSource] = [:]

    /// The set of assets whose link is broken (their source account was deleted while
    /// a trace of the link still exists). Recomputed on every `load()` from the
    /// resolved sources. Lets the View target rows to highlight.
    var brokenLinkAssetIds: Set<Int> = []

    /// True if at least 1 asset has a broken link — used to decide whether
    /// to show an alert banner at the top of the List.
    var hasBrokenLinks: Bool { !brokenLinkAssetIds.isEmpty }

    var isLoading = false

    // MARK: - Repositories

    private let patrimoineRepo: PatrimoineRepository
    private let transactionRepo: TransactionRepository
    private let investmentRepo: InvestmentRepository
    private let goalRepo: GoalRepository

    /// The default value targets the app's database: no call site
    /// needs to change. Tests inject a temporary database.
    init(store: SQLiteStore = SQLiteStore()) {
        patrimoineRepo = PatrimoineRepository(store: store)
        transactionRepo = TransactionRepository(store: store)
        investmentRepo = InvestmentRepository(store: store)
        goalRepo = GoalRepository(store: store)
    }

    // MARK: - Computed (aggregates)

    /// The sum of every resolved asset (movable assets & cash).
    var totalAssetsValue: Double {
        PatrimoineSnapshotBuilder.totalAssetsValue(assets: assets, resolvedValues: resolvedAssetValues)
    }

    /// The sum of the current estimated value of every real-estate property.
    /// `currentValue` is entered manually by the user — no dynamic resolution
    /// needed (real estate isn't like an account that moves on its own).
    var totalRealEstateValue: Double {
        realEstates.reduce(0) { $0 + $1.currentValue }
    }

    /// The aggregated estimated gross gain (Σ currentValue − Σ purchasePrice).
    /// Shown in the Real Estate section's header.
    var totalRealEstateCapitalGain: Double {
        realEstates.reduce(0) { $0 + $1.capitalGain }
    }

    // MARK: - Aggregated snapshot (the global view)

    /// A complete snapshot of net worth at a point in time — used by the module's
    /// editorial hero and by the Dashboard banner. Computed in memory on every
    /// access (every operation is an O(n) sum over in-RAM collections,
    /// so negligible even for hundreds of items).
    var snapshot: PatrimoineSnapshot {
        PatrimoineSnapshotBuilder.snapshot(
            assets: assets,
            realEstates: realEstates,
            loans: loans,
            resolvedValues: resolvedAssetValues,
            loanStates: loanStates
        )
    }

    /// The debt/gross-assets ratio (0…1+). Used for the hero's bar, which
    /// conveys the liabilities' "weight". Returns 0 if there are no gross assets (avoids a /0).
    var leverageRatio: Double {
        let assets = snapshot.totalAssets
        guard assets > 0 else { return 0 }
        return min(2.0, snapshot.totalLiabilities / assets)
    }

    /// Loan states computed via `LoanCalculator` (the cache refreshed on every load).
    /// `loanId → LoanState` to avoid recomputing on every UI access.
    var loanStates: [Int: LoanState] = [:]

    /// The sum of the remaining principal on every loan (the liabilities side of net worth).
    var totalLoansRemainingCapital: Double {
        PatrimoineSnapshotBuilder.totalLiabilities(loans: loans, loanStates: loanStates)
    }

    // MARK: - Goals state

    /// Goals loaded from SQLite. Refreshed on every `load()`.
    var goals: [Goal] = []

    /// A cache of progressions computed via `GoalCalculator`. `goalId → progress`.
    /// Recomputed on every `load()` to stay aligned with the Patrimoine snapshot.
    var goalProgresses: [Int: GoalProgress] = [:]

    /// A debt baseline for `.debtPayoff` goals. Stored in UserDefaults
    /// by goal_id — the idea: the moment the user creates a debt-payoff goal,
    /// the MAX debt (= snapshot.totalLiabilities at that instant) is captured,
    /// becoming the 100% to reach. Without this, progress would always be 0%
    /// (current debt / current debt = 1 → ratio = 0).
    private func debtBaseline(forGoalId id: Int) -> Double {
        UserDefaults.standard.double(forKey: "goalDebtBaseline_\(id)")
    }

    private func captureDebtBaseline(forGoalId id: Int, value: Double) {
        UserDefaults.standard.set(value, forKey: "goalDebtBaseline_\(id)")
    }

    /// IDs of accounts already linked to a Patrimoine asset. Used by the picker to
    /// gray out unavailable choices (an account can only be linked to 1 asset
    /// at a time — a business rule enforced by a SQL UNIQUE INDEX).
    var linkedBankAccountIds: Set<Int> {
        Set(assets.compactMap { $0.linkedAccountId })
    }

    var linkedInvestmentAccountIds: Set<Int> {
        Set(assets.compactMap { $0.linkedInvestmentAccountId })
    }

    // MARK: - Public API

    /// Loads the module's full data and resolves linked values.
    /// Deliberately synchronous — SQLite is local, no need for a Task.detached for
    /// a few dozen rows.
    func load() {
        isLoading = true
        // Account caches first — asset resolution needs them.
        availableBankAccounts = transactionRepo.fetchAccounts()
        availableInvestmentAccounts = investmentRepo.fetchAccounts()

        // Then the 3 Patrimoine entities.
        assets = patrimoineRepo.fetchAssets()
        realEstates = patrimoineRepo.fetchRealEstate()
        loans = patrimoineRepo.fetchLoans()

        // Resolving asset values via the pure engine, shared with the Dashboard.
        // Bank balances are fetched ONCE, and only for accounts
        // actually linked (a `fetchAccountBalance` = a SUM over the whole table).
        let (values, sources) = PatrimoineSnapshotBuilder.resolveValues(
            assets: assets,
            existingBankAccountIds: Set(availableBankAccounts.map(\.id)),
            bankBalances: bankBalances(for: assets),
            investmentAccounts: availableInvestmentAccounts
        )
        resolvedAssetValues = values
        resolvedAssetSources = sources

        // Opportunistic persistence of last_known_value — only if the link was
        // resolved as alive, so as not to overwrite a historical value with 0 when the
        // link is broken. Kept here: a pure engine doesn't write to the database.
        for asset in assets where sources[asset.id] == .linkedAccount || sources[asset.id] == .linkedInvestment {
            guard let value = values[asset.id], abs(value - asset.lastKnownValue) > 0.005 else { continue }
            patrimoineRepo.updateLastKnownValue(assetId: asset.id, value: value)
        }

        // Records broken links to highlight the affected rows and
        // allow an alert banner at the top of the List.
        brokenLinkAssetIds = Set(sources.compactMap { $0.value == .brokenLink ? $0.key : nil })

        // Computing loan states — pure Swift, blazing fast even for 50 loans.
        var states: [Int: LoanState] = [:]
        for loan in loans {
            states[loan.id] = LoanCalculator.compute(loan: loan)
        }
        loanStates = states

        // Goals — loaded after loans (the debt_payoff baseline needs the
        // current snapshot, and the snapshot depends on the already-loaded
        // assets/realEstates/loans).
        goals = goalRepo.fetchGoals()
        let snap = snapshot  // a single call to the computed property
        let assetsTotal = totalAssetsValue
        var progresses: [Int: GoalProgress] = [:]
        for goal in goals {
            // For debt_payoff: the persisted baseline is read. If absent (a
            // goal just created, or importing an old database), it's captured
            // now with the current debt — at least progress will be stable
            // over time even if it starts at 0.
            var baseline: Double? = nil
            if goal.kind == .debtPayoff {
                let stored = debtBaseline(forGoalId: goal.id)
                if stored > 0 {
                    baseline = stored
                } else if snap.totalLiabilities > 0 {
                    captureDebtBaseline(forGoalId: goal.id, value: snap.totalLiabilities)
                    baseline = snap.totalLiabilities
                }
            }
            progresses[goal.id] = GoalCalculator.progress(
                for: goal,
                snapshot: snap,
                totalAssetsValue: assetsTotal,
                initialDebtForPayoff: baseline
            )
        }
        goalProgresses = progresses

        isLoading = false
    }

    // MARK: - Goals — CRUD wrappers

    @discardableResult
    func createGoal(name: String, kind: GoalKind, targetAmount: Double,
                    deadlineDate: Date?, customCurrentAmount: Double,
                    notes: String?) -> Bool {
        let ok = goalRepo.addGoal(
            name: name, kind: kind, targetAmount: targetAmount,
            deadlineDate: deadlineDate, customCurrentAmount: customCurrentAmount,
            notes: notes
        )
        if ok { load() }
        return ok
    }

    @discardableResult
    func updateGoal(_ goal: Goal) -> Bool {
        let ok = goalRepo.updateGoal(goal)
        if ok { load() }
        return ok
    }

    @discardableResult
    func deleteGoal(id: Int) -> Bool {
        // Also cleans up the persisted baseline (otherwise UserDefaults grows for no
        // reason over goals deleted and recreated with the same auto-incremented id).
        UserDefaults.standard.removeObject(forKey: "goalDebtBaseline_\(id)")
        let ok = goalRepo.deleteGoal(id: id)
        if ok { load() }
        return ok
    }

    /// Resolves an asset's value based on its mode (linked or standalone).
    /// Exposed for the form and the picker (to show the read value in a preview).
    /// Delegates to the pure engine — the resolution rule exists in only one place.
    func resolveValue(for asset: PatrimoineAsset) -> (value: Double, source: AssetValueSource) {
        PatrimoineSnapshotBuilder.resolveValue(
            for: asset,
            existingBankAccountIds: Set(availableBankAccounts.map(\.id)),
            bankBalances: bankBalances(for: [asset]),
            investmentAccounts: availableInvestmentAccounts
        )
    }

    /// Balances of the bank accounts linked to the given assets. A single
    /// `fetchAccountBalance` per account, and only for accounts that still exist —
    /// a deleted account must stay detected as a broken link, not read as €0.
    private func bankBalances(for assets: [PatrimoineAsset]) -> [Int: Double] {
        let existing = Set(availableBankAccounts.map(\.id))
        var balances: [Int: Double] = [:]
        for id in PatrimoineSnapshotBuilder.linkedBankAccountIds(in: assets) where existing.contains(id) {
            balances[id] = transactionRepo.fetchAccountBalance(accountId: id, upToDate: nil)
        }
        return balances
    }

    /// A VM-side wrapper that computes a source account's fresh value without touching
    /// the VM's state. Used by the picker to show "Value read: €X" next to
    /// each selectable account.
    func liveValue(forBankAccountId id: Int) -> Double {
        transactionRepo.fetchAccountBalance(accountId: id, upToDate: nil)
    }

    func liveValue(forInvestmentAccountId id: Int) -> Double {
        guard let acc = availableInvestmentAccounts.first(where: { $0.id == id }) else { return 0 }
        return acc.currentValue + acc.cashBalance
    }

    // MARK: - Assets — CRUD wrapper

    /// Creates an asset. If linked, `lastKnownValue` is initialized with the freshly
    /// read value, so it can be shown as a fallback if the source account disappears.
    @discardableResult
    func createAsset(name: String, kind: AssetKind,
                     linkedAccountId: Int?, linkedInvestmentAccountId: Int?,
                     manualValue: Double, notes: String?) -> Bool {
        // Conflict detection before the INSERT (the UNIQUE INDEX is the 2nd line of defense).
        if let conflict = patrimoineRepo.assetIdLinkedTo(
            accountId: linkedAccountId,
            investmentAccountId: linkedInvestmentAccountId,
            excludingAssetId: nil
        ) {
            print("[Patrimoine] createAsset refused — link conflict with asset id \(conflict)")
            return false
        }
        // For a linked asset, the snapshot's initial last_known_value is computed
        // so it isn't 0 even if the user doesn't check the list right away.
        var lastKnown: Double = manualValue
        if let bankId = linkedAccountId {
            lastKnown = transactionRepo.fetchAccountBalance(accountId: bankId, upToDate: nil)
        } else if let invId = linkedInvestmentAccountId,
                  let acc = availableInvestmentAccounts.first(where: { $0.id == invId }) {
            lastKnown = acc.currentValue + acc.cashBalance
        }

        let ok = patrimoineRepo.addAsset(
            name: name,
            assetKind: kind,
            linkedAccountId: linkedAccountId,
            linkedInvestmentAccountId: linkedInvestmentAccountId,
            manualValue: manualValue,
            lastKnownValue: lastKnown,
            notes: notes
        )
        if ok { load() }
        return ok
    }

    @discardableResult
    func updateAsset(_ asset: PatrimoineAsset) -> Bool {
        // A conflict is also possible on update if the user re-links to another account
        if let conflict = patrimoineRepo.assetIdLinkedTo(
            accountId: asset.linkedAccountId,
            investmentAccountId: asset.linkedInvestmentAccountId,
            excludingAssetId: asset.id
        ) {
            print("[Patrimoine] updateAsset refused — link conflict with asset id \(conflict)")
            return false
        }
        let ok = patrimoineRepo.updateAsset(asset)
        if ok { load() }
        return ok
    }

    @discardableResult
    func deleteAsset(id: Int) -> Bool {
        let ok = patrimoineRepo.deleteAsset(id: id)
        if ok { load() }
        return ok
    }

    // MARK: - Real estate — CRUD wrapper

    @discardableResult
    func createRealEstate(name: String, purchasePrice: Double, purchaseDate: Date,
                          currentValue: Double, estimatedAt: Date?,
                          address: String?, notes: String?) -> Bool {
        let ok = patrimoineRepo.addRealEstate(
            name: name,
            purchasePrice: purchasePrice,
            purchaseDate: purchaseDate,
            currentValue: currentValue,
            estimatedAt: estimatedAt,
            address: address,
            notes: notes
        )
        if ok { load() }
        return ok
    }

    @discardableResult
    func updateRealEstate(_ item: PatrimoineRealEstate) -> Bool {
        let ok = patrimoineRepo.updateRealEstate(item)
        if ok { load() }
        return ok
    }

    @discardableResult
    func deleteRealEstate(id: Int) -> Bool {
        // ON DELETE SET NULL on the SQL side means loans linked to this property
        // (loan.linked_real_estate_id) automatically become an "orphaned loan" without
        // being deleted — exactly the desired semantics (the user can keep
        // tracking the debt even after the property is sold).
        let ok = patrimoineRepo.deleteRealEstate(id: id)
        if ok { load() }
        return ok
    }

    // MARK: - Loans — CRUD wrapper

    @discardableResult
    func createLoan(name: String, loanType: LoanType, principal: Double,
                    annualRate: Double, durationMonths: Int, deferralMonths: Int,
                    startDate: Date, insuranceMonthly: Double,
                    linkedRealEstateId: Int?, notes: String?) -> Bool {
        let ok = patrimoineRepo.addLoan(
            name: name,
            loanType: loanType,
            principal: principal,
            annualRate: annualRate,
            durationMonths: durationMonths,
            deferralMonths: deferralMonths,
            startDate: startDate,
            insuranceMonthly: insuranceMonthly,
            linkedRealEstateId: linkedRealEstateId,
            notes: notes
        )
        if ok { load() }
        return ok
    }

    /// The total monthly cost (amortization payment + insurance) summed across
    /// every active loan (not finished and not pending). Shown in the Loans
    /// section's header to convey the liabilities' total monthly "weight".
    var totalMonthlyLoanCost: Double {
        loans.reduce(0) { acc, loan in
            let state = loanStates[loan.id]
            // The payment is only counted if the loan is currently amortizing.
            // Insurance, however, runs as long as the loan isn't finished (deferred included).
            let m = (state?.isPending == true || state?.isCompleted == true) ? 0 : (state?.monthlyPayment ?? 0)
            let ins = (state?.isCompleted == true) ? 0 : loan.insuranceMonthly
            return acc + m + ins
        }
    }

    @discardableResult
    func updateLoan(_ loan: PatrimoineLoan) -> Bool {
        let ok = patrimoineRepo.updateLoan(loan)
        if ok { load() }
        return ok
    }

    @discardableResult
    func deleteLoan(id: Int) -> Bool {
        let ok = patrimoineRepo.deleteLoan(id: id)
        if ok { load() }
        return ok
    }

    /// The name of the real-estate property linked to a loan, or nil if there's no link
    /// (or the property was deleted).
    func realEstateName(forLoanLinked id: Int?) -> String? {
        guard let id else { return nil }
        return realEstates.first(where: { $0.id == id })?.name
    }

    // MARK: - Display helpers ("Linked to …" labels)

    /// A short descriptive text for an asset's source, ready to be shown as a
    /// row subtitle. No conditional logic in the View.
    ///
    /// Returns a `LocalizedStringResource`, not a `Text`: this type is resolved AT
    /// READ time by the view, so it follows a language change mid-session, where a
    /// `Text` built here would freeze the translation at
    /// computation time. It also keeps this file free of SwiftUI — the
    /// architecture rule verified in continuous integration.
    func sourceLabel(for asset: PatrimoineAsset) -> LocalizedStringResource {
        if let bankId = asset.linkedAccountId,
           let acc = availableBankAccounts.first(where: { $0.id == bankId }) {
            return LocalizedStringResource("Lié à \(acc.name)")
        }
        if let invId = asset.linkedInvestmentAccountId,
           let acc = availableInvestmentAccounts.first(where: { $0.id == invId }) {
            return LocalizedStringResource("Lié à \(acc.name)")
        }
        if asset.isLinked {
            // The link exists in memory but the source account has disappeared — the
            // UNIQUE INDEX and ON DELETE SET NULL should prevent this case, but
            // this label is kept as a safety net.
            return LocalizedStringResource("Lien rompu (dernière valeur connue)")
        }
        return LocalizedStringResource("Valeur saisie manuellement")
    }
}
