import SwiftUI
import Charts
import TipKit

struct PatternEditSheet: View {
    @Bindable var vm: BudgetViewModel
    let pattern: RecurringPattern?
    /// Optional pre-fill for a CREATION (pattern == nil) — used
    /// to let the user adjust a detected candidate (amount, day,
    /// category…) before confirming it, instead of only being able to accept it
    /// as is. Ignored if `pattern` isn't nil (editing an existing one).
    var prefill: RecurringPattern? = nil
    /// Called after a successful creation (pattern == nil) — lets the caller
    /// (e.g. the list of detected candidates) remove the original item.
    var onCreated: (() -> Void)? = nil
    // paneDismiss (not \.dismiss): the view is presented via adaptivePane —
    // an iOS sheet OR a macOS pane, dismissal is uniform either way.
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

    // Payees loaded on open for the picker (read-only, not via the VM)
    @State private var allTiers: [Tiers] = []
    @State private var showCategoryPicker = false
    @State private var showPayeePicker = false

    var body: some View {
            Form {
                Section("Informations") {
                    TextField("Nom (ex: Netflix, Loyer)", text: $name)
                    HStack {
                        // `LabeledContent` rather than a bare `TextField`: on
                        // macOS, a `TextField`'s title becomes a LABEL on the
                        // left rather than a placeholder INSIDE the field
                        // (unlike on iOS) — the field then had
                        // no visible label on macOS. A "0.00" placeholder then
                        // `.textFieldStyle(.roundedBorder)` were tried
                        // to make the field look more visibly "editable",
                        // then removed on request — the native style
                        // (no border or placeholder, consistent with
                        // the rest of the Form) remains preferable.
                        // `.frame(minWidth:)` is still needed on the
                        // container: without it, this row shares space
                        // with a fixed-width (160pt) segmented Picker — on
                        // macOS, one of the two gets squeezed to
                        // near-zero width (invisible, unclickable) instead of
                        // splitting the space as on iOS. The amount field
                        // used to disappear, making the form impossible to submit
                        // (confirmDisabled stayed true since the field,
                        // invisible, could never be filled in).
                        LabeledContent("Montant") {
                            TextField("", text: $amount)
                                .keyboardType(.decimalPad)
                        }
                        .frame(minWidth: 140)
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
                        ForEach(RecurrenceFrequency.allCases) { f in Text(LocalizedStringKey(f.label)).tag(f) }
                    }
                    if frequency.usesDayOfMonthAnchor {
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
                    Button {
                        showCategoryPicker = true
                    } label: {
                        HStack {
                            Text("Catégorie").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text(vm.categories.first(where: { $0.id == categoryId })?.name ?? "Aucune")
                                .foregroundStyle(categoryId == nil ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                }
                // The associated payee pre-fills the picker when the matched transaction arrives,
                // and lets auto-matching target that payee as a priority (TransactionMatcher).
                Section {
                    Button {
                        showPayeePicker = true
                    } label: {
                        HStack {
                            Text("Tier").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text(allTiers.first(where: { $0.id == payeeId })?.name ?? "Aucun")
                                .foregroundStyle(payeeId == nil ? AppTheme.Colors.textSecondary : AppTheme.Colors.textPrimary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
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
            .paneChrome(pattern != nil ? "Modifier" : (prefill != nil ? "Récurrent détecté" : "Nouveau récurrent"),
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark",
                        confirmDisabled: name.isEmpty || amount.isEmpty) {
                save(); dismiss()
            }
            .adaptivePane(isPresented: $showCategoryPicker) {
                CategoryQuickPickSheet(currentCategoryId: categoryId, allCategories: vm.categories) { newId, _ in
                    categoryId = newId
                }
            }
            .adaptivePane(isPresented: $showPayeePicker) {
                TiersSearchSheet(allTiers: allTiers, selectedId: Binding(
                    get: { payeeId ?? -1 },
                    set: { payeeId = $0 == -1 ? nil : $0 }
                ))
            }
    }

    private func populateFields() {
        // An existing pattern (editing) takes priority over pre-filling from a
        // detected candidate — the two are never provided at the same time.
        guard let p = pattern ?? prefill else { return }
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
            // isManual reflects the real origin: "detected" if starting from a
            // candidate (even adjusted), "entered manually" otherwise — consistent
            // with the "Origin" field shown in PatternDetailPane.
            let new = RecurringPattern(
                id: 0, name: name, amountAvg: signed, amountTolerance: 0.15,
                categoryId: categoryId, payeeId: payeeId, frequency: frequency,
                anchorDay: anchorDay, isActive: true, isManual: prefill == nil,
                createdAt: Date(), lastDetectedAt: prefill?.lastDetectedAt,
                startDate: startDate, endDate: effectiveEndDate
            )
            vm.addManualPattern(new)
            onCreated?()
        }
    }
}
