import Foundation

// MARK: - PatrimoineSnapshotBuilder
//
// **Moteur pur** de résolution des valeurs d'assets et d'agrégation du patrimoine.
// Aucun accès base : l'appelant fetche, le moteur calcule. C'est ce qui le rend
// testable et surtout partageable entre `PatrimoineViewModel` (module) et le
// Dashboard, qui en avait jusqu'ici une copie inlinée avec le commentaire
// « résolution identique au PatrimoineViewModel mais inlinée ici pour ne pas
// instancier 2 VMs » — donc deux implémentations libres de diverger.
//
// ⚠️ Un builder pur n'écrit jamais en base. La persistance opportuniste de
// `last_known_value` reste dans `PatrimoineViewModel.load()`.

enum PatrimoineSnapshotBuilder {

    /// Comptes bancaires dont il faut connaître le solde pour résoudre les assets.
    /// Permet à l'appelant de ne fetcher QUE les soldes utiles (un `fetchAccountBalance`
    /// est un `SUM(amount)` sur toute la table `transactions`).
    static func linkedBankAccountIds(in assets: [PatrimoineAsset]) -> Set<Int> {
        Set(assets.compactMap(\.linkedAccountId))
    }

    /// Résout la valeur courante d'un asset.
    ///
    /// - Parameters:
    ///   - existingBankAccountIds: ids des comptes bancaires qui existent RÉELLEMENT.
    ///     Indispensable pour distinguer un compte supprimé (lien rompu → fallback sur
    ///     `lastKnownValue`) d'un compte bien vivant dont le solde vaut 0 — un solde
    ///     seul ne permet pas de faire la différence.
    ///   - bankBalances: soldes déjà fetchés, indexés par id de compte.
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

    /// Résout tous les assets d'un coup.
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

    /// Somme des assets résolus. `lastKnownValue` sert de filet si un asset n'a pas
    /// été résolu (ne devrait pas arriver, mais évite qu'un oubli fasse disparaître
    /// silencieusement une ligne du patrimoine).
    static func totalAssetsValue(assets: [PatrimoineAsset], resolvedValues: [Int: Double]) -> Double {
        assets.reduce(0.0) { $0 + (resolvedValues[$1.id] ?? $1.lastKnownValue) }
    }

    /// Somme des capitaux restants dus. `principal` sert de filet si l'état du prêt
    /// n'a pas été calculé.
    static func totalLiabilities(loans: [PatrimoineLoan], loanStates: [Int: LoanState]) -> Double {
        loans.reduce(0.0) { $0 + (loanStates[$1.id]?.remainingCapital ?? $1.principal) }
    }

    /// Agrège le snapshot complet à partir des collections déjà résolues.
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
