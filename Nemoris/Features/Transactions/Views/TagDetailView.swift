import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TagDetailView: View {
    let tag: Tag
    let repository: TransactionRepository

    @State private var transactions: [FinanceTransaction] = []
    @State private var tricountEntries: [TaggedTricountEntry] = []
    @State private var isSyncingRates = false

    private var txTotal: Double { transactions.reduce(0) { $0 + $1.amount } }
    // Exclut les entrées sans taux (devise étrangère non convertie) du total EUR
    private var tcTotal: Double { tricountEntries.reduce(0) { $0 + ($1.needsConversion ? 0 : $1.signedAmount) } }
    private var grandTotal: Double { txTotal + tcTotal }
    private var hasConvertedEntries: Bool { tricountEntries.contains { $0.isConverted } }
    private var hasUnconvertedEntries: Bool { tricountEntries.contains { $0.needsConversion } }

    var body: some View {
        List {
            // Résumé
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Total").font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                        Text(grandTotal, format: .currency(code: "EUR"))
                            .font(.title3).fontWeight(.bold)
                            .foregroundStyle(grandTotal < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    }
                    Spacer()
                    if transactions.count > 0 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(transactions.count) transaction(s)")
                                .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                            Text(txTotal, format: .currency(code: "EUR"))
                                .font(.caption).foregroundStyle(txTotal < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                    }
                    if tricountEntries.count > 0 {
                        Divider().frame(height: 32)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(tricountEntries.count) Tricount\(hasConvertedEntries ? " ~EUR" : "")\(hasUnconvertedEntries ? " ⚠" : "")")
                                .font(.caption2).foregroundStyle(hasUnconvertedEntries ? AppTheme.Colors.warning : AppTheme.Colors.textSecondary)
                            (Text(hasUnconvertedEntries ? "≈ " : "") + Text(tcTotal, format: .currency(code: "EUR")))
                                .font(.caption).foregroundStyle(tcTotal < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if !transactions.isEmpty {
                Section("Transactions (\(transactions.count))") {
                    ForEach(transactions) { tx in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tx.tiersName.isEmpty ? tx.information : tx.tiersName)
                                    .font(.subheadline)
                                HStack(spacing: 4) {
                                    if !tx.categoryName.isEmpty {
                                        Text(tx.categoryName)
                                            .font(.caption2)
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(AppTheme.Colors.accent.opacity(0.12), in: Capsule())
                                            .foregroundStyle(AppTheme.Colors.accent)
                                    }
                                    Text(tx.date, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                                }
                            }
                            Spacer()
                            Text(tx.amount, format: .currency(code: "EUR"))
                                .font(.subheadline).fontWeight(.semibold)
                                .foregroundStyle(tx.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !tricountEntries.isEmpty {
                Section {
                    ForEach(tricountEntries) { entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.description.isEmpty ? entry.groupTitle : entry.description)
                                    .font(.subheadline)
                                HStack(spacing: 4) {
                                    Text(entry.groupTitle)
                                        .font(.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(tag.displayColor.opacity(0.12), in: Capsule())
                                        .foregroundStyle(tag.displayColor)
                                    Text(entry.date, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                                        .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                if entry.needsConversion {
                                    // Pas de taux disponible : afficher en devise originale avec indicateur
                                    let rawSigned = entry.isExpense ? -entry.myShare : entry.myShare
                                    Text(rawSigned, format: .currency(code: entry.currency))
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(AppTheme.Colors.warning)
                                    Text("non converti")
                                        .font(.caption2).foregroundStyle(AppTheme.Colors.warning)
                                } else {
                                    // Montant en EUR (signé : négatif si dépense, positif si revenu)
                                    Text(entry.signedAmount, format: .currency(code: "EUR"))
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(entry.isExpense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                                    // Montant original si devise étrangère convertie
                                    if entry.isConverted {
                                        let rawSigned = entry.isExpense ? -entry.myShare : entry.myShare
                                        Text(rawSigned, format: .currency(code: entry.currency))
                                            .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Text("Tricount (\(tricountEntries.count))")
                        if hasConvertedEntries {
                            Spacer()
                            Label("Converti en EUR", systemImage: "arrow.triangle.2.circlepath")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                }
            }
        }
        #if os(macOS)
        // `List` peint SON PROPRE fond système sur macOS PAR-DESSUS celui du
        // panneau hôte — sans ce modificateur, le bureau de l'utilisateur
        // transparaît (retour d'usage 2026-08-19).
        .scrollContentBackground(.hidden)
        #endif
        .navigationTitle(tag.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSyncingRates {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ProgressView().scaleEffect(0.8)
                }
            }
        }
        .onAppear {
            transactions = repository.fetchTransactions(forTagId: tag.id)
            tricountEntries = repository.fetchTricountEntries(forTagId: tag.id)
            // Si des entrées non-EUR sont sans taux, déclencher la sync
            if tricountEntries.contains(where: { $0.needsConversion }) {
                Task {
                    isSyncingRates = true
                    await CurrencyRateService.syncAllGroups()
                    tricountEntries = repository.fetchTricountEntries(forTagId: tag.id)
                    isSyncingRates = false
                }
            }
        }
    }
}
