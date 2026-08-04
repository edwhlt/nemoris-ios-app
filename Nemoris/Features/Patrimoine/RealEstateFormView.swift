import SwiftUI

// MARK: - RealEstateFormView
//
// Sheet de création/édition d'un bien immobilier. Saisie 100% manuelle (pas de
// linking — l'immobilier n'a pas de "compte source" qui bouge tout seul).
//
// La preview live de la plus-value (chip vert/rouge en bas de section Achat) sert
// de feedback pédagogique pendant la saisie : tu vois immédiatement si ton bien
// a pris ou perdu de la valeur depuis l'achat.
//
// Validation : nom non vide. Le prix d'achat et la valeur actuelle peuvent être 0
// (utile pour un bien en construction ou en sinistre avant indemnisation).

struct RealEstateFormView: View {
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let viewModel: PatrimoineViewModel
    let existingItem: PatrimoineRealEstate?

    // ── Champs du draft ───────────────────────────────────────────
    @State private var name: String
    @State private var purchasePriceText: String
    @State private var purchaseDate: Date
    @State private var currentValueText: String
    @State private var estimatedAt: Date?
    @State private var address: String
    @State private var notes: String

    // ── UI state ──────────────────────────────────────────────────
    @State private var showDeleteConfirm = false

    init(viewModel: PatrimoineViewModel, existingItem: PatrimoineRealEstate? = nil) {
        self.viewModel = viewModel
        self.existingItem = existingItem

        let initialName = existingItem?.name ?? ""
        let initialPurchasePrice = existingItem?.purchasePrice ?? 0
        let initialPurchaseDate = existingItem?.purchaseDate ?? Date()
        let initialCurrentValue = existingItem?.currentValue ?? 0
        let initialEstimatedAt = existingItem?.estimatedAt
        let initialAddress = existingItem?.address ?? ""
        let initialNotes = existingItem?.notes ?? ""

        _name = State(initialValue: initialName)
        _purchasePriceText = State(initialValue: initialPurchasePrice == 0
                                    ? ""
                                    : String(format: "%.2f", initialPurchasePrice))
        _purchaseDate = State(initialValue: initialPurchaseDate)
        _currentValueText = State(initialValue: initialCurrentValue == 0
                                    ? ""
                                    : String(format: "%.2f", initialCurrentValue))
        _estimatedAt = State(initialValue: initialEstimatedAt)
        _address = State(initialValue: initialAddress)
        _notes = State(initialValue: initialNotes)
    }

    // MARK: - Computed

    private var purchasePrice: Double {
        Double(purchasePriceText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var currentValue: Double {
        Double(currentValueText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var capitalGain: Double { currentValue - purchasePrice }

    private var capitalGainPercent: Double {
        guard purchasePrice > 0 else { return 0 }
        return capitalGain / purchasePrice * 100
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Body

    var body: some View {
            Form {
                Section("Identité") {
                    TextField("Nom (ex. Appart Paris 11e)", text: $name)
                        .autocorrectionDisabled()

                    TextField("Adresse (optionnel)", text: $address, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section {
                    HStack {
                        Text("Prix d'achat")
                            .font(AppTheme.Typography.bodyMedium)
                        Spacer()
                        TextField("0,00", text: $purchasePriceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 160)
                    }
                    DatePicker("Date d'achat", selection: $purchaseDate, displayedComponents: .date)
                } header: {
                    Text("Achat")
                }

                Section {
                    HStack {
                        Text("Valeur estimée")
                            .font(AppTheme.Typography.bodyMedium)
                        Spacer()
                        TextField("0,00", text: $currentValueText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 160)
                    }

                    // Toggle "Date d'estimation" : l'user peut choisir de la marquer
                    // (utile pour se rappeler quand il a fait la dernière revalo) ou
                    // de la laisser nulle (estimation au doigt mouillé permanente).
                    Toggle("Marquer la date d'estimation", isOn: Binding(
                        get: { estimatedAt != nil },
                        set: { isOn in
                            estimatedAt = isOn ? (estimatedAt ?? Date()) : nil
                        }
                    ))
                    if let _ = estimatedAt {
                        DatePicker("Estimé le", selection: Binding(
                            get: { estimatedAt ?? Date() },
                            set: { estimatedAt = $0 }
                        ), displayedComponents: .date)
                    }

                    // Preview live de la plus-value. Donne un feedback éditorial
                    // immédiat à l'user pendant la saisie.
                    if purchasePrice > 0 && currentValue > 0 {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: capitalGain >= 0 ? "arrow.up.right" : "arrow.down.right")
                                .font(.system(size: 11, weight: .bold))
                            Text("Plus-value estimée :")
                                .font(AppTheme.Typography.labelMedium)
                            Text(capitalGain, format: .currency(code: "EUR").presentation(.narrow))
                                .font(AppTheme.Typography.labelLarge)
                                .fontWeight(.semibold)
                            Text(String(format: "(%@%.1f %%)",
                                        capitalGain >= 0 ? "+" : "",
                                        capitalGainPercent))
                                .font(AppTheme.Typography.labelMedium)
                        }
                        .foregroundStyle(capitalGain >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger)
                        .padding(.top, AppTheme.Spacing.xs)
                    }
                } header: {
                    Text("Valeur actuelle")
                } footer: {
                    Text("Saisissez la valeur estimée aujourd'hui (estimation libre, MeilleursAgents, expertise, etc.). La plus-value est calculée par différence avec le prix d'achat.")
                        .font(AppTheme.Typography.bodySmall)
                }

                Section("Note") {
                    TextField("Note libre", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if existingItem != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Supprimer ce bien")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .confirmationDialog(
                "Supprimer ce bien immobilier ?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) {
                    if let id = existingItem?.id {
                        viewModel.deleteRealEstate(id: id)
                        dismiss()
                    }
                }
            } message: {
                Text("Les prêts liés à ce bien deviendront orphelins mais ne seront pas supprimés (vous pourrez les rattacher à un autre bien plus tard).")
            }
            .paneChrome(existingItem == nil ? "Nouveau bien" : "Modifier",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmDisabled: !canSave,
                        onConfirm: { save() })
    }

    // MARK: - Save

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)

        let addressValue: String? = trimmedAddress.isEmpty ? nil : trimmedAddress
        let notesValue: String? = trimmedNotes.isEmpty ? nil : trimmedNotes

        let success: Bool
        if let existing = existingItem {
            var updated = existing
            updated.name = trimmedName
            updated.purchasePrice = purchasePrice
            updated.purchaseDate = purchaseDate
            updated.currentValue = currentValue
            updated.estimatedAt = estimatedAt
            updated.address = addressValue
            updated.notes = notesValue
            success = viewModel.updateRealEstate(updated)
        } else {
            success = viewModel.createRealEstate(
                name: trimmedName,
                purchasePrice: purchasePrice,
                purchaseDate: purchaseDate,
                currentValue: currentValue,
                estimatedAt: estimatedAt,
                address: addressValue,
                notes: notesValue
            )
        }

        if success {
            HapticService.shared.success()
            dismiss()
        } else {
            HapticService.shared.error()
            appState.postToast(.error, "Impossible d'enregistrer ce bien. Réessayez.")
        }
    }
}
