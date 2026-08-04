import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct AddTransactionSheet: View {
    // Rebind sur paneDismiss (inspector macOS / sheet iOS) — dismiss() reste valide.
    @Environment(\.paneDismiss) private var dismiss

    let accounts: [Account]
    let allCategories: [Category]
    let allMdps: [PaymentType]
    let repository: TransactionRepository
    let onSave: () -> Void

    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true

    @State private var localTiers: [Tiers]
    @State private var accountId: Int
    @State private var tiersId: Int = -1
    @State private var categoryId: Int = -1
    @State private var paymentTypeId: Int = -1
    @State private var remboursementTiersId: Int = -1
    @State private var information: String = ""
    @State private var amountText: String = ""
    @State private var type: TransactionTypePicker = .expense
    @State private var date: Date = Date()
    @State private var showTiersPicker = false
    @State private var showRemboursementPicker = false
    @State private var showCreateTiersForm = false
    @State private var newTiersPrefillName = ""
    @State private var errorMessage: String? = nil

    init(accounts: [Account], defaultAccountId: Int, allTiers: [Tiers],
         allCategories: [Category], allMdps: [PaymentType],
         repository: TransactionRepository, onSave: @escaping () -> Void) {
        self.accounts = accounts
        self.allCategories = allCategories
        self.allMdps = allMdps
        self.repository = repository
        self.onSave = onSave
        _localTiers = State(initialValue: allTiers)
        _accountId = State(initialValue: defaultAccountId)
    }

    private var tiersDisplayName: String {
        guard tiersId != -1 else { return "Aucun" }
        return localTiers.first(where: { $0.id == tiersId })?.name ?? "Inconnu"
    }
    private var remboursementDisplayName: String {
        guard remboursementTiersId != -1 else { return "Aucun" }
        return localTiers.first(where: { $0.id == remboursementTiersId })?.name ?? "Inconnu"
    }
    private var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
            Form {
                Section("Compte") {
                    Picker("Compte", selection: $accountId) {
                        ForEach(accounts.groupedByType, id: \.type) { group in
                            Section(group.type.label) {
                                ForEach(group.accounts) { a in Text(a.name).tag(a.id) }
                            }
                        }
                    }
                }

                Section("Détails") {
                    HStack {
                        Text("Montant")
                        Spacer()
                        Button {
                            type = (type == .expense) ? .income : .expense
                        } label: {
                            Text(type == .expense ? "−" : "+")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(type == .expense ? AppTheme.Colors.danger : AppTheme.Colors.success)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(type == .expense ? AppTheme.Colors.danger.opacity(0.12) : AppTheme.Colors.success.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        TextField("0.00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Information / description", text: $information)
                }

                Section("Classification") {
                    Button {
                        showTiersPicker = true
                    } label: {
                        HStack {
                            Text("Tiers").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text(tiersDisplayName).foregroundStyle(AppTheme.Colors.textSecondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                    Picker("Catégorie", selection: $categoryId) {
                        Text("Aucune").tag(-1)
                        ForEach(allCategories) { c in
                            Label(c.name, systemImage: c.displayIcon).tag(c.id)
                        }
                    }
                    Picker("Moyen de paiement", selection: $paymentTypeId) {
                        Text("Aucun").tag(-1)
                        ForEach(allMdps) { m in Text(m.name).tag(m.id) }
                    }
                }

                if reimbursementsEnabled {
                    Section("Remboursement") {
                        Button {
                            showRemboursementPicker = true
                        } label: {
                            HStack {
                                Text("Remboursé par").foregroundStyle(AppTheme.Colors.textPrimary)
                                Spacer()
                                Text(remboursementDisplayName)
                                    .foregroundStyle(remboursementTiersId == -1 ? AppTheme.Colors.textSecondary : AppTheme.Colors.warning)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                            }
                        }
                    }
                }

                if let err = errorMessage {
                    Section {
                        Text(err).foregroundStyle(AppTheme.Colors.danger).font(.caption)
                    }
                }
            }
            .nemorisFormStyle()
            .adaptivePane(isPresented: $showTiersPicker) {
                TiersSearchSheet(allTiers: localTiers, selectedId: $tiersId,
                                 onCreateTiers: { prefill in
                                     newTiersPrefillName = prefill
                                     showCreateTiersForm = true
                                 })
            }
            .adaptivePane(isPresented: $showRemboursementPicker) {
                TiersSearchSheet(allTiers: localTiers, selectedId: $remboursementTiersId)
            }
            .adaptivePane(isPresented: $showCreateTiersForm) {
                PayeeCreationFormSheet(prefilledName: newTiersPrefillName, allCategories: allCategories) { newTiers in
                    guard let id = repository.addTiersAndGetId(
                        name: newTiers.name,
                        regex: newTiers.regex ?? "",
                        categoryId: newTiers.categoryId
                    ) else { return }
                    var fullTiers = Tiers(
                        id: id, name: newTiers.name, regex: newTiers.regex,
                        categoryId: newTiers.categoryId, linkedCompteId: newTiers.linkedCompteId,
                        engineMerchantId: newTiers.engineMerchantId, domain: newTiers.domain,
                        address: newTiers.address, city: newTiers.city, country: newTiers.country,
                        groupId: newTiers.groupId, custom: newTiers.custom, note: newTiers.note,
                        tierType: newTiers.tierType, contactIdentifier: newTiers.contactIdentifier
                    )
                    repository.updatePayeeFull(fullTiers)
                    localTiers.append(fullTiers)
                    localTiers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    tiersId = id
                    if categoryId == -1 {
                        categoryId = newTiers.categoryId ?? -1
                    }
                }
            }
            .onChange(of: tiersId) { _, newId in
                guard newId != -1, categoryId == -1 else { return }
                if let tiers = localTiers.first(where: { $0.id == newId }) {
                    categoryId = tiers.categoryId ?? -1
                }
            }
            .paneChrome("Nouvelle transaction",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Ajouter",
                        confirmDisabled: parsedAmount == nil || amountText.isEmpty,
                        onConfirm: { save() })
    }

    private func save() {
        guard let absValue = parsedAmount else { return }
        let amount = type == .expense ? -abs(absValue) : abs(absValue)
        let newId = repository.addTransaction(
            accountId: accountId,
            tiersId: tiersId == -1 ? nil : tiersId,
            categoryId: categoryId == -1 ? nil : categoryId,
            paymentTypeId: paymentTypeId == -1 ? nil : paymentTypeId,
            information: information,
            amount: amount,
            date: date
        )
        if let newId {
            if remboursementTiersId != -1 {
                ReimbursementRepository().setReimbursement(transactionId: newId, payeeId: remboursementTiersId)
            }
            onSave()
            dismiss()
        } else {
            errorMessage = "Impossible d'enregistrer la transaction."
        }
    }
}
