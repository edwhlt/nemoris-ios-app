import SwiftUI

// MARK: - Order add/edit form
//
// Opened as a sheet from InvestmentPositionDetailView. Enters/edits a
// BUY / SELL / DIV with date, quantity, unit price, fees, notes.
//
// After save: calls onSave, which takes care of
//   1. `addOrder` or `updateOrder` in the repository
//   2. `recomputePositionFromOrders(positionId:)` to refresh quantity + average cost
//   3. refreshing the parent view

struct InvestmentOrderFormView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    let positionId: Int
    let currency: String
    /// nil = adding a new order; non-nil = editing an existing one
    let order: InvestmentOrder?
    let onSave: (InvestmentOrder, Bool) -> Void

    @State private var orderType: InvestmentOrderType
    @State private var quantity: String
    @State private var unitPrice: String
    @State private var fees: String
    @State private var executedAt: Date
    @State private var notes: String

    private var isEditing: Bool { order != nil }

    /// init() sets the @State at build time from the given order. Avoids stale
    /// state, where editing an order could overwrite the new values with those
    /// of a previously edited order.
    init(positionId: Int, currency: String, order: InvestmentOrder?, onSave: @escaping (InvestmentOrder, Bool) -> Void) {
        self.positionId = positionId
        self.currency = currency
        self.order = order
        self.onSave = onSave
        _orderType = State(initialValue: order?.orderType ?? .buy)
        _quantity = State(initialValue: order.map { String(format: "%.6f", $0.quantity).trimmedZeros } ?? "")
        _unitPrice = State(initialValue: order.map { String(format: "%.4f", $0.unitPrice).trimmedZeros } ?? "")
        _fees = State(initialValue: order.map { String(format: "%.2f", $0.fees).trimmedZeros } ?? "")
        _executedAt = State(initialValue: order?.executedAt ?? Date())
        _notes = State(initialValue: order?.notes ?? "")
    }
    private var canSave: Bool {
        Double(quantity.replacingOccurrences(of: ",", with: ".")) ?? 0 > 0 &&
        Double(unitPrice.replacingOccurrences(of: ",", with: ".")) ?? 0 >= 0
    }

    var body: some View {
            Form {
                Section("Type d'opération") {
                    Picker("Type", selection: $orderType) {
                        ForEach(InvestmentOrderType.allCases) { type in
                            Label(LocalizedStringKey(type.label), systemImage: type.systemIcon).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Quantité et prix") {
                    HStack {
                        Text("Quantité")
                        Spacer()
                        // Empty title: the row already has its label — see TransactionEditSheet
                        // for the macOS reason.
                        TextField("", text: $quantity)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text(orderType == .dividend ? "Montant unitaire" : "Prix unitaire")
                        Spacer()
                        TextField("", text: $unitPrice)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                        Text(currency)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    HStack {
                        Text("Frais")
                        Spacer()
                        TextField("", text: $fees)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                        Text(currency)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                Section("Date") {
                    DatePicker("Date d'exécution", selection: $executedAt, displayedComponents: .date)
                }

                Section("Notes (optionnel)") {
                    TextField("Ex: courtier, raison de l'opération…", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                // Total recap — useful to double-check before saving
                Section {
                    HStack {
                        Text("Total brut")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Spacer()
                        Text(totalPreview, format: .currency(code: currency))
                            .fontWeight(.semibold)
                            .foregroundStyle(totalColor)
                    }
                } footer: {
                    footerText
                }
            }
            .nemorisFormStyle()
            // No .onAppear — init() sets everything at build time.
            .paneChrome(isEditing ? "Modifier l'ordre" : "Nouvel ordre",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: isEditing ? "Mettre à jour" : "Ajouter",
                        confirmIcon: isEditing ? "checkmark" : "plus",
                        confirmDisabled: !canSave,
                        onConfirm: { save() })
    }

    // MARK: - Helpers

    private var totalPreview: Double {
        let q = Double(quantity.replacingOccurrences(of: ",", with: ".")) ?? 0
        let p = Double(unitPrice.replacingOccurrences(of: ",", with: ".")) ?? 0
        let f = Double(fees.replacingOccurrences(of: ",", with: ".")) ?? 0
        return q * p + f
    }

    private var totalColor: Color {
        switch orderType {
        case .buy:      return AppTheme.Colors.danger   // sortie de cash
        case .sell:     return AppTheme.Colors.success  // cash inflow
        case .dividend: return AppTheme.Colors.success
        }
    }

    @ViewBuilder
    private var footerText: some View {
        switch orderType {
        case .buy:
            Text("Achat : qty + PRU ajoutés à la position. Frais inclus dans le PRU pondéré.")
        case .sell:
            Text("Vente : réduit la quantité de la position. Le PRU moyen reste inchangé (calculé sur les achats uniquement).")
        case .dividend:
            Text("Dividende : tracking du revenu reçu. N'affecte ni la quantité ni le PRU.")
        }
    }

    // init() above sets the fields at build time (avoids stale state when
    // SwiftUI reuses the instance).

    private func save() {
        let q = Double(quantity.replacingOccurrences(of: ",", with: ".")) ?? 0
        let p = Double(unitPrice.replacingOccurrences(of: ",", with: ".")) ?? 0
        let f = Double(fees.replacingOccurrences(of: ",", with: ".")) ?? 0
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)

        let saved = InvestmentOrder(
            id: order?.id ?? 0,
            positionId: positionId,
            orderType: orderType,
            quantity: q,
            unitPrice: p,
            fees: f,
            executedAt: executedAt,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes
        )
        onSave(saved, !isEditing)
        dismiss()
    }
}

private extension String {
    var trimmedZeros: String {
        guard contains(".") else { return self }
        var s = self
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
