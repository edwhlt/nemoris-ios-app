import SwiftUI
import Charts
import TipKit

struct PatternDetailPane: View {
    let pattern: RecurringPattern
    let categories: [Category]

    /// Tiers chargés localement pour résoudre le nom du tier associé
    /// (RecurringManagementView ne les possède pas).
    @State private var allTiers: [Tiers] = []

    private var categoryName: String? {
        categories.first { $0.id == pattern.categoryId }?.name
    }

    private var tierName: String? {
        guard let pid = pattern.payeeId else { return nil }
        return allTiers.first { $0.id == pid }?.name
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .foregroundStyle(pattern.isExpense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                        .frame(width: 36, height: 36)
                        .background((pattern.isExpense ? AppTheme.Colors.danger : AppTheme.Colors.success).opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pattern.name).font(AppTheme.Typography.bodyMedium)
                        Text(pattern.frequency.label)
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Text(pattern.amountAvg, format: .currency(code: "EUR"))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(pattern.isExpense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                }
                .padding(.vertical, 2)
            }

            Section("Détails") {
                LabeledContent("Fréquence", value: pattern.frequency.label)
                if pattern.frequency == .monthly, let day = pattern.anchorDay {
                    LabeledContent("Jour du mois", value: "\(day)")
                }
                if let categoryName {
                    LabeledContent("Catégorie", value: categoryName)
                }
                if let tierName {
                    LabeledContent("Tier associé", value: tierName)
                }
                LabeledContent("Statut", value: pattern.isActive ? "Actif" : "Inactif")
                LabeledContent("Origine", value: pattern.isManual ? "Saisi manuellement" : "Détecté automatiquement")
            }

            Section("Période") {
                LabeledContent("Début", value: pattern.startDate.formatted(date: .abbreviated, time: .omitted))
                if let end = pattern.endDate {
                    LabeledContent("Fin", value: end.formatted(date: .abbreviated, time: .omitted))
                }
                if let detected = pattern.lastDetectedAt {
                    LabeledContent("Dernière détection", value: detected.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if pattern.payeeId != nil, allTiers.isEmpty {
                allTiers = TransactionRepository().fetchTiers()
            }
        }
    }
}
