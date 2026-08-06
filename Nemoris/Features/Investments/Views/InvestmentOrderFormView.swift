import SwiftUI

// MARK: - AXE K — Formulaire d'ajout/édition d'un ordre
//
// Ouvert depuis InvestmentPositionDetailView en sheet. Permet de saisir/éditer
// un BUY / SELL / DIV avec date, qty, prix unitaire, frais, notes.
//
// Après save : appelle onSave qui se charge de
//   1. `addOrder` ou `updateOrder` dans le repo
//   2. `recomputePositionFromOrders(positionId:)` pour rafraîchir qty + PRU
//   3. refresh de la vue parente

struct InvestmentOrderFormView: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    let positionId: Int
    let currency: String
    /// nil = ajout d'un nouvel ordre ; non-nil = édition d'un existant
    let order: InvestmentOrder?
    let onSave: (InvestmentOrder, Bool) -> Void

    @State private var orderType: InvestmentOrderType
    @State private var quantity: String
    @State private var unitPrice: String
    @State private var fees: String
    @State private var executedAt: Date
    @State private var notes: String

    private var isEditing: Bool { order != nil }

    /// AXE M : init() set @State au build time depuis l'order passé. Évite
    /// le bug de stale state où une édition d'order pouvait écraser les nouvelles
    /// valeurs avec celles d'un ordre précédemment édité.
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
                            Label(type.label, systemImage: type.systemIcon).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Quantité et prix") {
                    HStack {
                        Text("Quantité")
                        Spacer()
                        TextField("0", text: $quantity)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text(orderType == .dividend ? "Montant unitaire" : "Prix unitaire")
                        Spacer()
                        TextField("0,00", text: $unitPrice)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                        Text(currency)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    HStack {
                        Text("Frais")
                        Spacer()
                        TextField("0,00", text: $fees)
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

                // Récap calcul total — utile pour vérifier avant save
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
            // Pas de .onAppear — init() set tout au build time.
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
        case .sell:     return AppTheme.Colors.success  // entrée de cash
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

    // populateFields() retiré — l'init() ci-dessus le fait au build time
    // (élimine le bug de stale state quand SwiftUI réutilise l'instance).

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
