import Foundation

// MARK: - PatrimoineSnapshotBuilder
//
// **A pure engine** for resolving asset values and aggregating net worth.
// No database access: the caller fetches, the engine computes. This is what makes it
// testable and, above all, shareable between `PatrimoineViewModel` (the module) and the
// Dashboard, which until now had an inlined copy with the comment
// "resolution identical to PatrimoineViewModel but inlined here to avoid
// instantiating 2 VMs" — so two implementations free to diverge.
//
// ⚠️ A pure builder never writes to the database. The opportunistic persistence of
// `last_known_value` stays in `PatrimoineViewModel.load()`.

enum PatrimoineSnapshotBuilder {

    /// Bank accounts whose balance needs to be known to resolve assets.
    /// Lets the caller fetch ONLY the useful balances (a `fetchAccountBalance`
    /// is a `SUM(amount)` over the whole `transactions` table).
    static func linkedBankAccountIds(in assets: [PatrimoineAsset]) -> Set<Int> {
        Set(assets.compactMap(\.linkedAccountId))
    }

    /// Resolves an asset's current value.
    ///
    /// - Parameters:
    ///   - existingBankAccountIds: ids of bank accounts that ACTUALLY exist.
    ///     Essential to distinguish a deleted account (a broken link → falls back to
    ///     `lastKnownValue`) from a perfectly alive account whose balance is 0 — a balance
    ///     alone can't tell the difference.
    ///   - bankBalances: balances already fetched, indexed by account id.
    static func resolveValue(
        for asset: PatrimoineAsset,
        existingBankAccountIds: Set<Int>,
        bankBalances: [Int: Double],
        investmentAccounts: [InvestmentAccount]
    ) -> (value: Double, source: AssetValueSource) {
        if let bankId = asset.linkedAccountId {
            guard existingBankAccountIds.contains(bankId) else {
                return (asset.lastKnownValue, .brokenLink)
            }
            return (bankBalances[bankId] ?? asset.lastKnownValue, .linkedAccount)
        }
        if let investmentId = asset.linkedInvestmentAccountId {
            guard let account = investmentAccounts.first(where: { $0.id == investmentId }) else {
                return (asset.lastKnownValue, .brokenLink)
            }
            return (account.currentValue + account.cashBalance, .linkedInvestment)
        }
        return (asset.manualValue, .manual)
    }

    /// Resolves every asset at once.
    static func resolveValues(
        assets: [PatrimoineAsset],
        existingBankAccountIds: Set<Int>,
        bankBalances: [Int: Double],
        investmentAccounts: [InvestmentAccount]
    ) -> (values: [Int: Double], sources: [Int: AssetValueSource]) {
        var values: [Int: Double] = [:]
        var sources: [Int: AssetValueSource] = [:]
        for asset in assets {
            let resolved = resolveValue(
                for: asset,
                existingBankAccountIds: existingBankAccountIds,
                bankBalances: bankBalances,
                investmentAccounts: investmentAccounts
            )
            values[asset.id] = resolved.value
            sources[asset.id] = resolved.source
        }
        return (values, sources)
    }

    /// The sum of resolved assets. `lastKnownValue` serves as a safety net if an asset
    /// wasn't resolved (shouldn't happen, but prevents an oversight from
    /// silently dropping a line from net worth).
    static func totalAssetsValue(assets: [PatrimoineAsset], resolvedValues: [Int: Double]) -> Double {
        assets.reduce(0.0) { $0 + (resolvedValues[$1.id] ?? $1.lastKnownValue) }
    }

    /// The sum of remaining principals. `principal` serves as a safety net if a loan's
    /// state wasn't computed.
    static func totalLiabilities(loans: [PatrimoineLoan], loanStates: [Int: LoanState]) -> Double {
        loans.reduce(0.0) { $0 + (loanStates[$1.id]?.remainingCapital ?? $1.principal) }
    }

    /// Aggregates the full snapshot from already-resolved collections.
    static func snapshot(
        assets: [PatrimoineAsset],
        realEstates: [PatrimoineRealEstate],
        loans: [PatrimoineLoan],
        resolvedValues: [Int: Double],
        loanStates: [Int: LoanState]
    ) -> PatrimoineSnapshot {
        PatrimoineSnapshot(
            totalAssets: totalAssetsValue(assets: assets, resolvedValues: resolvedValues)
                + realEstates.reduce(0.0) { $0 + $1.currentValue },
            totalLiabilities: totalLiabilities(loans: loans, loanStates: loanStates),
            assetsCount: assets.count,
            realEstateCount: realEstates.count,
            loansCount: loans.count
        )
    }
}
