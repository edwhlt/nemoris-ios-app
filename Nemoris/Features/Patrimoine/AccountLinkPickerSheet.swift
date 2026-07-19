import SwiftUI

// MARK: - LinkSelection (modèle léger remonté par le picker)

/// Représente le résultat de la sélection dans `AccountLinkPickerSheet`.
/// `.none` = pas de lien (mode manuel). Les 2 autres cas portent l'ID du compte source.
/// Utilisé comme état du form `AssetFormView`.
enum LinkSelection: Equatable, Hashable {
    case none
    case bank(Int)        // accounts.id
    case investment(Int)  // investment_accounts.id
}

// MARK: - AccountLinkPickerSheet

/// Sheet de sélection du compte source pour un asset Patrimoine.
///
/// Affiche en sections :
///   • Comptes bancaires (livrets, courants — types EPARGNE / COURANT uniquement)
///   • Comptes investissements (PEA, CTO, crypto wallets, etc.)
///   • Option "Aucun — saisir manuellement"
///
/// Un compte déjà lié à un AUTRE asset Patrimoine est listé mais désactivé, avec
/// un libellé "(déjà lié)". L'asset en cours d'édition (`excludingAssetId`)
/// échappe à ce grisage — sinon on ne pourrait pas conserver son propre lien.
///
/// Le tap sur une ligne **sélectionne immédiatement et ferme la sheet**. Pas de
/// bouton "Confirmer" séparé (UX volontairement rapide).
struct AccountLinkPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: PatrimoineViewModel
    let currentSelection: LinkSelection
    /// ID de l'asset en cours d'édition (nil si création). Sert à ne PAS griser
    /// le compte que cet asset utilise déjà — il doit pouvoir le conserver.
    let excludingAssetId: Int?
    let onSelect: (LinkSelection) -> Void

    /// On ne propose que les comptes pertinents pour le patrimoine (épargne / courant).
    /// Différé et "autre" sont écartés : ils ne représentent pas du patrimoine
    /// au sens net worth (le différé est transitoire, "autre" est ambigu).
    private var eligibleBankAccounts: [Account] {
        viewModel.availableBankAccounts.filter { acc in
            acc.accountType == .epargne || acc.accountType == .courant
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Comptes & livrets ────────────────────────────────────
                if !eligibleBankAccounts.isEmpty {
                    Section {
                        ForEach(eligibleBankAccounts) { acc in
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
                if !viewModel.availableInvestmentAccounts.isEmpty {
                    Section {
                        ForEach(viewModel.availableInvestmentAccounts) { acc in
                            investmentAccountRow(acc)
                        }
                    } header: {
                        Text("Investissements")
                    } footer: {
                        Text("La valeur du compte = somme des positions valorisées + cash disponible.")
                            .font(AppTheme.Typography.bodySmall)
                    }
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

                // Cas où aucun compte n'est disponible nulle part.
                if eligibleBankAccounts.isEmpty && viewModel.availableInvestmentAccounts.isEmpty {
                    Section {
                        Text("Aucun compte existant à lier. Créez un compte dans **Données** ou **Investissements** d'abord, ou continuez en mode manuel.")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
            .navigationTitle("Source de la valeur")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    // MARK: - Rows

    /// Détermine si un compte bancaire doit être grisé : il est lié à un autre asset
    /// Patrimoine que celui en cours d'édition.
    private func isBankConflicting(_ acc: Account) -> Bool {
        guard viewModel.linkedBankAccountIds.contains(acc.id) else { return false }
        // L'asset en cours d'édition utilise déjà ce compte → ne pas griser.
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
                        Text(acc.accountType.label)
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
