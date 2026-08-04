import SwiftUI
import TipKit

struct PayeeDetailPane: View {
    let tiers: Tiers
    let allCategories: [Category]
    let payeeGroups: [PayeeGroup]
    let accounts: [Account]
    let transactionCount: Int

    var body: some View {
        Form {
            Section {
                HStack(spacing: AppTheme.Spacing.md) {
                    MerchantLogo(tiers: tiers, allCategories: allCategories, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tiers.name)
                            .font(AppTheme.Typography.bodyMedium)
                            .lineLimit(2)
                        Text(tiers.tierType.displayName)
                            .font(AppTheme.Typography.labelSmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 2)
            }

            Section("Détails") {
                if let cat = allCategories.first(where: { $0.id == tiers.categoryId }) {
                    LabeledContent("Catégorie", value: cat.name)
                }
                if let gid = tiers.groupId,
                   let group = payeeGroups.first(where: { $0.id == gid }) {
                    LabeledContent("Groupe", value: group.displayName)
                }
                if let linkedId = tiers.linkedCompteId,
                   let account = accounts.first(where: { $0.id == linkedId }) {
                    LabeledContent("Virement interne", value: account.name)
                }
                LabeledContent("Transactions", value: "\(transactionCount)")
                LabeledContent("Identifiant", value: "#\(tiers.id)")
            }

            if (tiers.address?.isEmpty == false) || (tiers.city?.isEmpty == false) || (tiers.country?.isEmpty == false) {
                Section("Localisation") {
                    if let address = tiers.address, !address.isEmpty {
                        LabeledContent("Adresse", value: address)
                    }
                    if let city = tiers.city, !city.isEmpty {
                        LabeledContent("Ville", value: city)
                    }
                    if let country = tiers.country, !country.isEmpty {
                        LabeledContent("Pays", value: country.uppercased())
                    }
                }
            }

            if (tiers.domain?.isEmpty == false) || (tiers.engineMerchantId?.isEmpty == false) {
                Section("Avancé") {
                    if let domain = tiers.domain, !domain.isEmpty {
                        LabeledContent("Domaine", value: domain)
                    }
                    if let engineId = tiers.engineMerchantId, !engineId.isEmpty {
                        LabeledContent("ID moteur", value: engineId)
                    }
                }
            }

            if let note = tiers.note, !note.isEmpty {
                Section("Note") {
                    Text(note).font(AppTheme.Typography.bodySmall)
                }
            }
        }
        .formStyle(.grouped)
    }
}
