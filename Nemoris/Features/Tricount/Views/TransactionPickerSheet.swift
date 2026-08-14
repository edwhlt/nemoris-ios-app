import SwiftUI
import TipKit

struct TransactionPickerSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let txRepo: TransactionRepository
    let currentId: Int?
    let onSelect: (FinanceTransaction) -> Void

    @State private var transactions: [FinanceTransaction] = []
    @State private var search = ""

    private var filtered: [FinanceTransaction] {
        guard !search.isEmpty else { return transactions }
        return transactions.filter {
            $0.tiersName.localizedCaseInsensitiveContains(search) ||
            $0.information.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
            List(filtered) { tx in
                Button {
                    onSelect(tx)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tx.tiersName.isEmpty ? tx.information : tx.tiersName)
                                .font(.subheadline).foregroundStyle(AppTheme.Colors.textPrimary)
                            Text(tx.date, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                            if !tx.information.isEmpty && !tx.tiersName.isEmpty {
                                Text(tx.information).font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5)).lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(tx.amount, format: .currency(code: "EUR"))
                                .font(.subheadline).bold()
                                .foregroundStyle(tx.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                            if tx.id == currentId {
                                Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent).font(.caption)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher une transaction…")
            .onAppear { transactions = txRepo.fetchAllTransactions() }
            .paneChrome("Choisir une transaction", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}
