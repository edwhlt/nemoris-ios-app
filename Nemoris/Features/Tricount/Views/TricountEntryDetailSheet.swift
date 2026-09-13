import SwiftUI
import TipKit

struct TricountEntryDetailSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    let entry: TricountEntry
    let myShare: Double?
    let myName: String
    let groupCurrency: String
    let repo: TricountRepository
    let txRepo: TransactionRepository
    let reimbursementRepo: ReimbursementRepository
    let allTags: [Tag]
    let onChanged: () -> Void

    @State private var reimbursements: [Reimbursement] = []
    /// The row being edited via "Edit…" — nil for a new assignment.
    /// Distinguishes a real update (by id) from a new upsert, so it never
    /// silently duplicates if the payee changes (a v44 fix).
    @State private var editingReimbursement: Reimbursement? = nil
    @State private var linkedTransaction: FinanceTransaction? = nil
    @State private var entryTags: [Tag] = []
    @State private var localAllTags: [Tag]
    @State private var showTransactionPicker = false
    @State private var showAddReimbursement = false
    @State private var showTagPicker = false
    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true

    init(entry: TricountEntry, myShare: Double?, myName: String, groupCurrency: String,
         repo: TricountRepository, txRepo: TransactionRepository, reimbursementRepo: ReimbursementRepository,
         allTags: [Tag], onChanged: @escaping () -> Void) {
        self.entry = entry
        self.myShare = myShare
        self.myName = myName
        self.groupCurrency = groupCurrency
        self.repo = repo
        self.txRepo = txRepo
        self.reimbursementRepo = reimbursementRepo
        self.allTags = allTags
        self.onChanged = onChanged
        _localAllTags = State(initialValue: allTags)
    }

    private var isPaidByMe: Bool { entry.whoPaid == myName }

    private var displayShare: Double? {
        guard let s = myShare else { return nil }
        let type = entry.typeTransaction.uppercased()
        if type == "TRANSFER" || type == "BALANCE" { return nil }
        if type == "INCOME" { return s }   // revenu → positif
        return -s                           // an expense → always negative
    }

    private var displayTotal: Double {
        entry.typeTransaction.uppercased() == "NORMAL" ? -entry.total : entry.total
    }

    private var entryTypeLabel: LocalizedStringResource {
        switch entry.typeTransaction.uppercased() {
        case "NORMAL":   return "Dépense"
        case "INCOME":   return "Revenu"
        case "BALANCE", "TRANSFER": return "Transfert"
        default:         return LocalizedStringResource(stringLiteral: entry.typeTransaction)
        }
    }

    var body: some View {
            Form {
                // Expense info
                Section("Dépense") {
                    LabeledContent("Type") {
                        Text(entryTypeLabel).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    LabeledContent("Description") {
                        Text(entry.description.isEmpty
                             ? entry.category.lowercased().replacingOccurrences(of: "_", with: " ").capitalized
                             : entry.description)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    LabeledContent("Payé par") { Text(entry.whoPaid == myName ? "Moi" : entry.whoPaid).foregroundStyle(AppTheme.Colors.textSecondary) }
                    LabeledContent("Total") {
                        Text(displayTotal, format: .currency(code: entry.currency))
                            .foregroundStyle(displayTotal < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    }
                    if let share = displayShare {
                        LabeledContent("Ma part") {
                            Text(share, format: .currency(code: groupCurrency))
                                // positive = I receive / negative = I owe
                                .foregroundStyle(share >= 0 ? AppTheme.Colors.accent : AppTheme.Colors.danger)
                        }
                    }
                    LabeledContent("Date") {
                        Text(entry.date, format: Date.FormatStyle(date: .abbreviated, time: .omitted)).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                // A linked transaction
                Section("Transaction liée") {
                    if let tx = linkedTransaction {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(tx.tiersName.isEmpty ? tx.information : tx.tiersName)
                                    .font(.subheadline)
                                Spacer()
                                Text(tx.amount, format: .currency(code: "EUR"))
                                    .font(.subheadline).bold()
                                    .foregroundStyle(tx.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                            }
                            Text(tx.date, format: Date.FormatStyle(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        Button("Modifier le lien") { showTransactionPicker = true }
                        Button("Supprimer le lien", role: .destructive) {
                            repo.updateLinkedTransaction(entryId: entry.id, transactionId: nil)
                            linkedTransaction = nil
                            onChanged()
                        }
                    } else {
                        Text("Aucune transaction liée")
                            .foregroundStyle(AppTheme.Colors.textSecondary).font(.caption)
                        Button("Lier une transaction…") { showTransactionPicker = true }
                    }
                }

                // Tags
                Section("Tags") {
                    Button {
                        showTagPicker = true
                    } label: {
                        HStack {
                            Label("Tags", systemImage: "tag").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            if entryTags.isEmpty {
                                Text("Aucun").foregroundStyle(AppTheme.Colors.textSecondary)
                            } else {
                                Text(entryTags.map(\.name).joined(separator: ", "))
                                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                }

                // Tricount reimbursements (1 max per entry)
                if reimbursementsEnabled {
                    Section {
                        if let r = reimbursements.first {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.payeeName).font(.subheadline)
                                }
                                Spacer()
                                Text(abs(r.amount), format: .currency(code: r.currency))
                                    .font(.subheadline).foregroundStyle(AppTheme.Colors.success)
                            }
                            Button("Modifier…") {
                                editingReimbursement = r
                                showAddReimbursement = true
                            }
                            Button("Supprimer", role: .destructive) {
                                reimbursementRepo.deleteReimbursement(id: r.id)
                                reimbursements = []
                                onChanged()
                            }
                        } else {
                            Text("Aucun remboursement").foregroundStyle(AppTheme.Colors.textSecondary).font(.caption)
                            Button("Assigner un remboursement…") {
                                editingReimbursement = nil
                                showAddReimbursement = true
                            }
                        }
                    } header: {
                        Text("Remboursement")
                    } footer: {
                        if displayShare != nil {
                            Text("Le montant par défaut est votre part sur cette dépense.")
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .onAppear { loadData() }
            .adaptivePane(isPresented: $showTagPicker) {
                TagManagementSheet(
                    initialTagIds: Set(entryTags.map(\.id)),
                    allTags: localAllTags,
                    repository: txRepo,
                    onSave: { tagIds in
                        txRepo.setTags(Array(tagIds), forTricountEntry: entry.id)
                        entryTags = txRepo.fetchTags(forTricountEntry: entry.id)
                    },
                    onNewTag: { newTag in
                        if !localAllTags.contains(where: { $0.id == newTag.id }) {
                            localAllTags.append(newTag)
                            localAllTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                        }
                    }
                )
            }
            .adaptivePane(isPresented: $showTransactionPicker) {
                TransactionPickerSheet(txRepo: txRepo, currentId: entry.linkedTransactionId) { tx in
                    repo.updateLinkedTransaction(entryId: entry.id, transactionId: tx.id)
                    linkedTransaction = tx
                    onChanged()
                }
            }
            .adaptivePane(isPresented: $showAddReimbursement) {
                AddTricountReimbursementSheet(
                    // The absolute value is passed: a reimbursement is always an amount > 0
                    // (what's expected to be received, regardless of the share's sign)
                    defaultAmount: abs(displayShare ?? 0),
                    currency: groupCurrency,
                    existingReimbursement: editingReimbursement
                ) { tiersId, amount, currency in
                    if let existing = editingReimbursement {
                        // Editing by id: updates the existing row even if
                        // the payee changes, never duplicates (a v44 fix).
                        reimbursementRepo.updateReimbursement(id: existing.id, payeeId: tiersId, amount: amount, currency: currency)
                    } else {
                        reimbursementRepo.addOrUpdateReimbursement(tricountEntryId: entry.id, payeeId: tiersId, amount: amount, currency: currency)
                    }
                    reimbursements = reimbursementRepo.fetchReimbursements(forTricountEntry: entry.id)
                    onChanged()
                }
            }
            .paneChrome("Détail dépense", cancelLabel: "Fermer", onCancel: { dismiss() })
    }

    private func loadData() {
        reimbursements = reimbursementRepo.fetchReimbursements(forTricountEntry: entry.id)
        entryTags = txRepo.fetchTags(forTricountEntry: entry.id)
        if let txId = entry.linkedTransactionId {
            linkedTransaction = txRepo.fetchAllTransactions(limit: 2000).first(where: { $0.id == txId })
        }
    }
}
