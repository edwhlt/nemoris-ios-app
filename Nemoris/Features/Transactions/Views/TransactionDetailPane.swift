import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TransactionDetailPane: View {
    let tx: FinanceTransaction
    let accounts: [Account]
    let allTiers: [Tiers]
    let allCategories: [Category]
    let repository: TransactionRepository

    /// Lecture fraîche à chaque rendu : après une édition (tags modifiés dans
    /// le sheet), le retour au détail reflète l'état réel en base.
    private var tags: [Tag] {
        repository.fetchTagsForTransactions([tx.id])[tx.id] ?? []
    }

    private var accountName: String {
        accounts.first { $0.id == tx.accountId }?.name ?? "Compte #\(tx.accountId)"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    MerchantLogo(transaction: tx, allTiers: allTiers, allCategories: allCategories, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tx.tiersName.isEmpty ? "Sans tiers" : tx.tiersName)
                            .font(AppTheme.Typography.bodyMedium)
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(2)
                        Text(tx.date.formatted(date: .long, time: .omitted))
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Text(tx.amount, format: .currency(code: "EUR"))
                        .font(AppTheme.Typography.moneyMedium)
                        .foregroundStyle(tx.amount >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                }
                .padding(.vertical, 2)
            }

            Section("Détails") {
                LabeledContent("Compte", value: accountName)
                LabeledContent("Catégorie", value: tx.categoryName.isEmpty ? "—" : tx.categoryName)
                LabeledContent("Moyen de paiement", value: tx.paymentTypeName.isEmpty ? "—" : tx.paymentTypeName)
                if !tx.remboursementTiersName.isEmpty {
                    LabeledContent("Remboursement", value: tx.remboursementTiersName)
                }
            }

            if !tags.isEmpty {
                Section("Tags") {
                    Text(tags.map(\.name).joined(separator: " · "))
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }

            if !tx.information.isEmpty {
                Section("Note") {
                    Text(tx.information)
                        .font(AppTheme.Typography.bodySmall)
                }
            }

            if let brut = tx.libelleBrut, !brut.isEmpty {
                Section("Libellé bancaire brut") {
                    Text(brut)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
