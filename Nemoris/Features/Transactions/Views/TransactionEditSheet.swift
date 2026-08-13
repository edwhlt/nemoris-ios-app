import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import TipKit

struct TransactionEditSheet: View {
    // Rebind sur paneDismiss (inspector macOS / sheet iOS) — dismiss() reste valide.
    @Environment(\.paneDismiss) private var dismiss

    let draft: TransactionEditDraft
    let allCategories: [Category]
    let allMdps: [PaymentType]
    let allTags: [Tag]
    let repository: TransactionRepository
    let onSave: () -> Void

    @AppStorage("nemoris.reimbursementsEnabled") private var reimbursementsEnabled = true

    @State private var localTiers: [Tiers]
    @State private var tiersId: Int
    @State private var categoryId: Int
    @State private var paymentTypeId: Int
    @State private var remboursementTiersId: Int
    @State private var information: String
    @State private var amountText: String
    @State private var type: TransactionTypePicker
    @State private var date: Date
    @State private var selectedTagIds: Set<Int> = []
    @State private var showTiersPicker = false
    @State private var showRemboursementPicker = false
    @State private var showCreateTiersForm = false
    @State private var showTagPicker = false
    @State private var newTiersPrefillName = ""
    @State private var localAllTags: [Tag]

    init(draft: TransactionEditDraft, allTiers: [Tiers], allCategories: [Category],
         allMdps: [PaymentType], allTags: [Tag], repository: TransactionRepository, onSave: @escaping () -> Void) {
        self.draft          = draft
        self.allCategories  = allCategories
        self.allMdps        = allMdps
        self.allTags        = allTags
        self.repository     = repository
        self.onSave         = onSave
        _localTiers             = State(initialValue: allTiers)
        _localAllTags           = State(initialValue: allTags)
        _tiersId                = State(initialValue: draft.tiersId ?? -1)
        _categoryId             = State(initialValue: draft.categoryId ?? -1)
        _paymentTypeId          = State(initialValue: draft.paymentTypeId ?? -1)
        _remboursementTiersId   = State(initialValue: draft.remboursementTiersId ?? -1)
        _information            = State(initialValue: draft.information)
        _amountText             = State(initialValue: String(abs(draft.amount)))
        _date                   = State(initialValue: draft.date)
        _type                   = State(initialValue: draft.type)
    }

    private var tiersDisplayName: String {
        guard tiersId != -1 else { return "Aucun" }
        return localTiers.first(where: { $0.id == tiersId })?.name ?? "Inconnu"
    }

    private var remboursementDisplayName: String {
        guard remboursementTiersId != -1 else { return "Aucun" }
        return localTiers.first(where: { $0.id == remboursementTiersId })?.name ?? "Inconnu"
    }

    var body: some View {
            Form {
                Section("Détails") {
                    TextField("Description", text: $information)
                    if let brut = draft.libelleBrut, !brut.isEmpty {
                        LabeledContent("Libellé bancaire") {
                            Text(brut)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                                .multilineTextAlignment(.trailing)
                                .font(.footnote)
                        }
                    }
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
                }

                // ⚠️ Remplace le picker « Moyen de paiement ». Ce champ imposait
                // sa sémantique à tout le monde ; il est devenu une métadonnée
                // parmi d'autres (migration v46). `payment_type_id` reste écrit
                // tel quel sur les transactions existantes mais n'est plus lu
                // par l'UI — dépréciation, pas suppression (doctrine du projet).
                TransactionMetadataSection(transactionId: draft.id)

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

                Section("Tags") {
                    Button {
                        showTagPicker = true
                    } label: {
                        HStack {
                            Label("Tags", systemImage: "tag").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            if selectedTagIds.isEmpty {
                                Text("Aucun").foregroundStyle(AppTheme.Colors.textSecondary)
                            } else {
                                // Afficher les noms des tags sélectionnés
                                Text(localAllTags.filter { selectedTagIds.contains($0.id) }.map(\.name).joined(separator: ", "))
                                    .foregroundStyle(AppTheme.Colors.accentSecondary)
                                    .lineLimit(1)
                            }
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .onAppear {
                selectedTagIds = Set(repository.fetchTags(forTransaction: draft.id).map(\.id))
            }
            .adaptivePane(isPresented: $showTagPicker) {
                TagPickerSheet(allTags: $localAllTags, selectedTagIds: $selectedTagIds, repository: repository)
            }
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
                    // Insert le tiers minimal puis updatePayeeFull pour tous les champs
                    guard let id = repository.addTiersAndGetId(
                        name: newTiers.name,
                        regex: newTiers.regex ?? "",
                        categoryId: newTiers.categoryId
                    ) else { return }
                    var fullTiers = newTiers
                    fullTiers = Tiers(
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
            .paneChrome("Modifier la transaction",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark", onConfirm: { save() })
    }

    private func save() {
        let absValue = Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? abs(draft.amount)
        let amount = type == .expense ? -absValue : absValue
        var updated = draft
        updated.tiersId             = tiersId == -1 ? nil : tiersId
        updated.categoryId          = categoryId == -1 ? nil : categoryId
        updated.paymentTypeId       = paymentTypeId == -1 ? nil : paymentTypeId
        updated.remboursementTiersId = remboursementTiersId == -1 ? nil : remboursementTiersId
        updated.information         = information
        updated.amount              = amount
        updated.date                = date
        repository.updateTransaction(updated)
        ReimbursementRepository().setReimbursement(transactionId: draft.id, payeeId: updated.remboursementTiersId)
        repository.setTags(Array(selectedTagIds), forTransaction: draft.id)
        onSave()
        dismiss()
    }
}
