import SwiftUI
import Charts
import TipKit

struct EnvelopeEditSheet: View {
    @Bindable var vm: BudgetViewModel
    let envelope: BudgetEnvelope?
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    @State private var name = ""
    @State private var amount = ""
    @State private var period = BudgetPeriod.monthly
    @State private var categoryId: Int? = nil

    var body: some View {
            Form {
                Section {
                    TextField("Nom (ex: Alimentation)", text: $name)
                    HStack {
                        TextField("Montant", text: $amount).keyboardType(.decimalPad)
                        Picker("", selection: $period) {
                            ForEach(BudgetPeriod.allCases, id: \.self) { p in Text(p.label).tag(p) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Catégorie") {
                    Picker("Catégorie", selection: $categoryId) {
                        Text("Aucune").tag(nil as Int?)
                        ForEach(vm.categories.hierarchicallySorted, id: \.category.id) { entry in
                            Text(entry.indentedName).tag(entry.category.id as Int?)
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .onAppear {
                if let e = envelope {
                    name = e.name
                    amount = String(format: "%.2f", e.amount)
                    period = e.period
                    categoryId = e.categoryId
                }
            }
            .paneChrome(envelope == nil ? "Nouvelle enveloppe" : "Modifier",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark",
                        confirmDisabled: name.isEmpty || amount.isEmpty) {
                save(); dismiss()
            }
    }

    private func save() {
        let raw = Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
        if let existing = envelope {
            let updated = BudgetEnvelope(id: existing.id, name: name, categoryId: categoryId,
                                         amount: raw, period: period,
                                         startDate: existing.startDate, isActive: existing.isActive)
            vm.updateEnvelope(updated)
        } else {
            let new = BudgetEnvelope(id: 0, name: name, categoryId: categoryId,
                                      amount: raw, period: period, startDate: Date(), isActive: true)
            vm.addEnvelope(new)
        }
    }
}
