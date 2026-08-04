import SwiftUI
import Charts
import TipKit

struct PatternEditSheet: View {
    @Bindable var vm: BudgetViewModel
    let pattern: RecurringPattern?
    // paneDismiss (pas \.dismiss) : la vue est présentée via adaptivePane —
    // sheet iOS OU panneau macOS, la fermeture est uniforme.
    @Environment(\.paneDismiss) private var dismiss

    @State private var name = ""
    @State private var amount = ""
    @State private var isExpense = true
    @State private var frequency = RecurrenceFrequency.monthly
    @State private var categoryId: Int? = nil
    @State private var payeeId: Int? = nil
    @State private var anchorDay: Int? = nil
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()

    // Tiers chargés à l'ouverture pour le picker (lecture seule, pas via VM)
    @State private var allTiers: [Tiers] = []

    var body: some View {
            Form {
                Section("Informations") {
                    TextField("Nom (ex: Netflix, Loyer)", text: $name)
                    HStack {
                        TextField("Montant", text: $amount).keyboardType(.decimalPad)
                        Picker("", selection: $isExpense) {
                            Text("Dépense").tag(true)
                            Text("Revenu").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                }
                Section("Fréquence") {
                    Picker("Fréquence", selection: $frequency) {
                        ForEach(RecurrenceFrequency.allCases) { f in Text(f.label).tag(f) }
                    }
                    if frequency == .monthly {
                        Stepper("Jour du mois : \(anchorDay ?? 1)",
                                value: Binding(get: { anchorDay ?? 1 }, set: { anchorDay = $0 }),
                                in: 1...31)
                    }
                }
                Section("Période") {
                    DatePicker("Début", selection: $startDate, displayedComponents: .date)
                    Toggle("Date de fin", isOn: $hasEndDate)
                    if hasEndDate {
                        DatePicker("Fin", selection: $endDate, in: startDate..., displayedComponents: .date)
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
                // Le tier associé pré-remplit le picker quand la transaction matchée arrive,
                // et permet à l'auto-matching de cibler ce tier en priorité (TransactionMatcher).
                // Tri alpha + section "Aucun" pour éviter d'imposer un choix.
                Section {
                    Picker("Tier", selection: $payeeId) {
                        Text("Aucun").tag(nil as Int?)
                        ForEach(allTiers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { t in
                            Text(t.name).tag(t.id as Int?)
                        }
                    }
                } header: {
                    Text("Tier associé")
                } footer: {
                    Text("Optionnel — facilite l'auto-matching d'une transaction réelle à cette échéance et permet d'afficher le logo du marchand.")
                        .font(.caption)
                }
            }
            .nemorisFormStyle()
            .onAppear {
                populateFields()
                if allTiers.isEmpty {
                    allTiers = TransactionRepository().fetchTiers()
                }
            }
            .paneChrome(pattern == nil ? "Nouveau récurrent" : "Modifier",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer",
                        confirmDisabled: name.isEmpty || amount.isEmpty) {
                save(); dismiss()
            }
    }

    private func populateFields() {
        guard let p = pattern else { return }
        name = p.name
        amount = String(format: "%.2f", p.displayAmount)
        isExpense = p.isExpense
        frequency = p.frequency
        categoryId = p.categoryId
        payeeId = p.payeeId
        anchorDay = p.anchorDay
        startDate = p.startDate
        hasEndDate = p.endDate != nil
        endDate = p.endDate ?? Date()
    }

    private func save() {
        let raw = Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
        let signed = isExpense ? -abs(raw) : abs(raw)
        let effectiveEndDate = hasEndDate ? endDate : nil
        if let existing = pattern {
            let updated = RecurringPattern(
                id: existing.id, name: name, amountAvg: signed, amountTolerance: existing.amountTolerance,
                categoryId: categoryId, payeeId: payeeId, frequency: frequency,
                anchorDay: anchorDay, isActive: existing.isActive, isManual: existing.isManual,
                createdAt: existing.createdAt, lastDetectedAt: existing.lastDetectedAt,
                startDate: startDate, endDate: effectiveEndDate
            )
            vm.updatePattern(updated)
        } else {
            let new = RecurringPattern(
                id: 0, name: name, amountAvg: signed, amountTolerance: 0.15,
                categoryId: categoryId, payeeId: payeeId, frequency: frequency,
                anchorDay: anchorDay, isActive: true, isManual: true,
                createdAt: Date(), lastDetectedAt: nil,
                startDate: startDate, endDate: effectiveEndDate
            )
            vm.addManualPattern(new)
        }
    }
}
