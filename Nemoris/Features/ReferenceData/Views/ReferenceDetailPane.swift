import SwiftUI
import TipKit

struct ReferenceDetailPane: View {
    let target: ReferenceDataView.ReferenceDetailTarget
    let categories: [Category]
    let counts: Int
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onShowTransactions: (Int, String) -> Void

    @Environment(\.paneDismiss) private var paneDismiss

    private var canEdit: Bool {
        if case .tag = target { return false }
        return true
    }

    private var navTitle: String {
        switch target {
        case .account:     return "Compte"
        case .category:    return "Catégorie"
        case .paymentType: return "Moyen de paiement"
        case .tag:         return "Tag"
        }
    }

    var body: some View {
            Form {
                switch target {
                case .account(let a):     accountSections(a)
                case .category(let c):    categorySections(c)
                case .paymentType(let p): paymentSections(p)
                case .tag(let t):         tagSections(t)
                }
            }
            .formStyle(.grouped)
            .paneChrome(navTitle,
                        cancelLabel: "Fermer", onCancel: { paneDismiss() },
                        destructiveLabel: "Supprimer", onDestructive: { onDelete(); paneDismiss() },
                        confirmLabel: canEdit ? "Modifier" : nil,
                        onConfirm: canEdit ? { onEdit() } : nil)
    }

    // MARK: Sections par entité

    @ViewBuilder
    private func accountSections(_ a: Account) -> some View {
        Section {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "building.columns.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.Colors.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(AppTheme.Typography.bodyMedium)
                    Text(a.accountType.label)
                        .font(AppTheme.Typography.labelSmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        Section("Détails") {
            LabeledContent("Type", value: a.accountType.label)
            LabeledContent("Transactions", value: "\(counts)")
            LabeledContent("Identifiant", value: "#\(a.id)")
        }
        Section {
            Button {
                onShowTransactions(a.id, a.name)
                paneDismiss()
            } label: {
                Label("Voir les transactions", systemImage: "list.bullet.rectangle")
            }
        }
    }

    @ViewBuilder
    private func categorySections(_ c: Category) -> some View {
        Section {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: c.displayIcon)
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.Colors.accent.opacity(0.12), in: Circle())
                Text(c.name).font(AppTheme.Typography.bodyMedium)
            }
        }
        Section("Détails") {
            if let parentId = c.parentId,
               let parent = categories.first(where: { $0.id == parentId }) {
                LabeledContent("Catégorie parente", value: parent.name)
            } else {
                let childCount = categories.filter { $0.parentId == c.id }.count
                if childCount > 0 {
                    LabeledContent("Sous-catégories", value: "\(childCount)")
                }
            }
            LabeledContent("Transactions", value: "\(counts)")
            LabeledContent("Identifiant", value: "#\(c.id)")
        }
    }

    @ViewBuilder
    private func paymentSections(_ p: PaymentType) -> some View {
        Section {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "creditcard.fill")
                    .font(.title3)
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.Colors.accent.opacity(0.12), in: Circle())
                Text(p.name).font(AppTheme.Typography.bodyMedium)
            }
        }
        Section("Détails") {
            if let r = p.regex, !r.isEmpty {
                LabeledContent("Regex") {
                    Text(r).font(.system(.caption, design: .monospaced))
                }
            }
            LabeledContent("Transactions", value: "\(counts)")
            LabeledContent("Identifiant", value: "#\(p.id)")
        }
    }

    @ViewBuilder
    private func tagSections(_ t: Tag) -> some View {
        Section {
            HStack(spacing: AppTheme.Spacing.md) {
                Circle()
                    .fill(t.displayColor)
                    .frame(width: 14, height: 14)
                Text(t.name).font(AppTheme.Typography.bodyMedium)
            }
        }
        Section {
            LabeledContent("Transactions", value: "\(counts)")
            LabeledContent("Identifiant", value: "#\(t.id)")
        } header: {
            Text("Détails")
        } footer: {
            Text("Le renommage des tags n'est pas encore disponible.")
        }
    }
}
