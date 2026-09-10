import SwiftUI
import Charts
import TipKit

struct EnvelopeDetailPane: View {
    let envelope: BudgetEnvelope
    let categories: [Category]

    private var categoryName: String? {
        categories.first { $0.id == envelope.categoryId }?.name
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    Image(systemName: "envelope.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.Colors.accent)
                        .frame(width: 36, height: 36)
                        .background(AppTheme.Colors.accent.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(envelope.name).font(AppTheme.Typography.bodyMedium)
                        Text(LocalizedStringKey(envelope.period.label))
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Text(envelope.amount, format: .currency(code: "EUR"))
                        .font(AppTheme.Typography.moneySmall)
                        .foregroundStyle(AppTheme.Colors.accent)
                }
                .padding(.vertical, 2)
            }

            Section("Détails") {
                LabeledContent("Plafond") { Text(envelope.amount, format: .currency(code: "EUR")) }
                LabeledContent {
                    Text(LocalizedStringKey(envelope.period.label))
                } label: {
                    Text("Période")
                }
                if let categoryName {
                    LabeledContent("Catégorie", value: categoryName)
                }
                LabeledContent("Début") { Text(envelope.startDate, format: Date.FormatStyle(date: .abbreviated, time: .omitted)) }
                LabeledContent("Statut", value: envelope.isActive ? "Active" : "Inactive")
            }
        }
        .nemorisFormStyle()
    }
}
