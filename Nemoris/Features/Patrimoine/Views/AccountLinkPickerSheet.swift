import SwiftUI

// MARK: - LinkSelection (a lightweight model returned by the picker)

/// Represents the selection result in `AccountLinkPickerSheet`.
/// `.none` = no link (manual mode). The 2 other cases carry the source account's ID.
/// Used as `AssetFormView`'s form state.
enum LinkSelection: Equatable, Hashable {
    case none
    case bank(Int)        // accounts.id
    case investment(Int)  // investment_accounts.id
}

// MARK: - AccountLinkPickerSheet

/// A sheet for picking the source account for a Patrimoine asset.
///
/// Shown in sections:
///   • Bank accounts (savings, checking — EPARGNE / COURANT types only)
///   • Investment accounts (PEA, CTO, crypto wallets, etc.)
///   • A "None — enter manually" option
///
/// An account already linked to ANOTHER Patrimoine asset is listed but disabled, with
/// a "(already linked)" label. The asset currently being edited (`excludingAssetId`)
/// is exempt from this graying-out — otherwise its own link couldn't be kept.
///
/// Tapping a row **selects immediately and closes the sheet**. No separate
/// "Confirm" button (deliberately fast UX).
struct AccountLinkPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: PatrimoineViewModel
    let currentSelection: LinkSelection
    /// The ID of the asset currently being edited (nil if creating). Used to NOT gray
    /// out the account this asset already uses — it must be able to keep it.
    let excludingAssetId: Int?
    let onSelect: (LinkSelection) -> Void

    @State private var search = ""

    /// Only accounts relevant to net worth are offered (savings / checking).
    /// Deferred and "other" are excluded: they don't represent net worth
    /// in the net-worth sense (deferred is transient, "other" is ambiguous).
    private var eligibleBankAccounts: [Account] {
        viewModel.availableBankAccounts.filter { acc in
            acc.accountType == .epargne || acc.accountType == .courant
        }
    }

    private var filteredBankAccounts: [Account] {
        guard !search.isEmpty else { return eligibleBankAccounts }
        return eligibleBankAccounts.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private var filteredInvestmentAccounts: [InvestmentAccount] {
        guard !search.isEmpty else { return viewModel.availableInvestmentAccounts }
        return viewModel.availableInvestmentAccounts.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.broker.localizedCaseInsensitiveContains(search)
        }
    }

    private var hasNoResultsForSearch: Bool {
        !search.isEmpty && filteredBankAccounts.isEmpty && filteredInvestmentAccounts.isEmpty
    }

    var body: some View {
            List {
                // ── Comptes & livrets ────────────────────────────────────
                if !filteredBankAccounts.isEmpty {
                    Section {
                        ForEach(filteredBankAccounts) { acc in
                            bankAccountRow(acc)
                        }
                    } header: {
                        Text("Comptes & livrets")
                    } footer: {
                        Text("Le solde du livret est calculé en temps réel depuis les transactions enregistrées.")
                            .font(AppTheme.Typography.bodySmall)
                    }
                }

                // ── Comptes investissements ──────────────────────────────
                if !filteredInvestmentAccounts.isEmpty {
                    Section {
                        ForEach(filteredInvestmentAccounts) { acc in
                            investmentAccountRow(acc)
                        }
                    } header: {
                        Text("Investissements")
                    } footer: {
                        Text("La valeur du compte = somme des positions valorisées + cash disponible.")
                            .font(AppTheme.Typography.bodySmall)
                    }
                }

                if hasNoResultsForSearch {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "Aucun résultat",
                        verbatimMessage: "Aucun résultat pour « \(search) »"
                    )
                }

                // ── Mode manuel ───────────────────────────────────────────
                Section {
                    Button {
                        onSelect(.none)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .frame(width: 32, height: 32)
                                .background(AppTheme.Colors.surfaceSecondary, in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Aucun — saisir manuellement")
                                    .font(AppTheme.Typography.titleSmall)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                                Text("La valeur sera figée à ce que vous entrez.")
                                    .font(AppTheme.Typography.bodySmall)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                            Spacer()
                            if currentSelection == .none {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(AppTheme.Colors.accent)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                // The case where no account is available anywhere.
                if eligibleBankAccounts.isEmpty && viewModel.availableInvestmentAccounts.isEmpty {
                    Section {
                        Text("Aucun compte existant à lier. Créez un compte dans **Données** ou **Investissements** d'abord, ou continuez en mode manuel.")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
            #if os(macOS)
            // `List` paints ITS OWN system background on macOS ON TOP OF
            // the host pane's — without this modifier, the user's
            // desktop shows through.
            .scrollContentBackground(.hidden)
            #endif
            .paneSearchable(text: $search, prompt: "Rechercher un compte…")
            // `.paneChrome` draws its own bars on macOS-sheet — the earlier
            // attempt (`.toolbarBackground(for: .windowToolbar)`)
            // compiled but had NO visual effect at all, confirmed by a live
            // screenshot. See the
            // `macSheetChrome` comment in AdaptivePane.swift.
            .paneChrome("Source de la valeur", cancelLabel: "Annuler", onCancel: { dismiss() })
    }

    // MARK: - Rows

    /// Determines whether a bank account should be grayed out: it's linked to another
    /// Patrimoine asset than the one being edited.
    private func isBankConflicting(_ acc: Account) -> Bool {
        guard viewModel.linkedBankAccountIds.contains(acc.id) else { return false }
        // The asset being edited already uses this account → don't gray it out.
        if case let .bank(currentId) = currentSelection, currentId == acc.id {
            return false
        }
        if let editingId = excludingAssetId,
           let existing = viewModel.assets.first(where: { $0.id == editingId }),
           existing.linkedAccountId == acc.id {
            return false
        }
        return true
    }

    private func isInvestmentConflicting(_ acc: InvestmentAccount) -> Bool {
        guard viewModel.linkedInvestmentAccountIds.contains(acc.id) else { return false }
        if case let .investment(currentId) = currentSelection, currentId == acc.id {
            return false
        }
        if let editingId = excludingAssetId,
           let existing = viewModel.assets.first(where: { $0.id == editingId }),
           existing.linkedInvestmentAccountId == acc.id {
            return false
        }
        return true
    }

    @ViewBuilder
    private func bankAccountRow(_ acc: Account) -> some View {
        let conflict = isBankConflicting(acc)
        let isSelected: Bool = {
            if case let .bank(id) = currentSelection { return id == acc.id }
            return false
        }()
        Button {
            guard !conflict else { return }
            onSelect(.bank(acc.id))
            dismiss()
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: acc.accountType == .epargne ? "building.columns.fill" : "creditcard.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.Colors.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(acc.name)
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(conflict ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary)
                        .strikethrough(conflict)
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(acc.accountType.label))
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        if conflict {
                            Text("· déjà lié à un autre élément")
                                .font(AppTheme.Typography.labelMedium)
                                .foregroundStyle(AppTheme.Colors.warning)
                        }
                    }
                }
                Spacer()
                if !conflict {
                    Text(viewModel.liveValue(forBankAccountId: acc.id),
                         format: .currency(code: "EUR").presentation(.narrow))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Colors.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(conflict)
    }

    @ViewBuilder
    private func investmentAccountRow(_ acc: InvestmentAccount) -> some View {
        let conflict = isInvestmentConflicting(acc)
        let isSelected: Bool = {
            if case let .investment(id) = currentSelection { return id == acc.id }
            return false
        }()
        Button {
            guard !conflict else { return }
            onSelect(.investment(acc.id))
            dismiss()
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.Colors.accentSecondary.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(acc.name)
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(conflict ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary)
                        .strikethrough(conflict)
                    HStack(spacing: 4) {
                        Text(acc.accountType)
                            .font(AppTheme.Typography.labelMedium)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        if conflict {
                            Text("· déjà lié à un autre élément")
                                .font(AppTheme.Typography.labelMedium)
                                .foregroundStyle(AppTheme.Colors.warning)
                        }
                    }
                }
                Spacer()
                if !conflict {
                    Text(viewModel.liveValue(forInvestmentAccountId: acc.id),
                         format: .currency(code: "EUR").presentation(.narrow))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppTheme.Colors.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(conflict)
    }
}
