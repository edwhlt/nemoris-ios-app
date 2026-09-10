import SwiftUI
import Charts
import TipKit

struct PatternEditSheet: View {
    @Bindable var vm: BudgetViewModel
    let pattern: RecurringPattern?
    /// Pré-remplissage optionnel pour une CRÉATION (pattern == nil) — utilisé
    /// pour laisser l'utilisateur ajuster un candidat détecté (montant, jour,
    /// catégorie…) avant de le valider, au lieu de ne pouvoir que l'accepter
    /// tel quel. Ignoré si `pattern` n'est pas nil (édition d'un existant).
    var prefill: RecurringPattern? = nil
    /// Appelé après une création réussie (pattern == nil) — permet à l'appelant
    /// (ex: la liste de candidats détectés) de retirer l'élément d'origine.
    var onCreated: (() -> Void)? = nil
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
                        // `LabeledContent` plutôt qu'un `TextField` nu : sur
                        // macOS, le titre d'un `TextField` devient un LABEL à
                        // gauche plutôt qu'un placeholder DANS le champ
                        // (contrairement à iOS) — le champ n'avait alors
                        // aucun label visible sur macOS. Retour d'usage
                        // 2026-08-28. Un placeholder "0,00" puis
                        // `.textFieldStyle(.roundedBorder)` ont été essayés
                        // pour rendre le champ plus visiblement "éditable",
                        // puis retirés à la demande — le style natif
                        // (sans bordure ni placeholder, cohérent avec le
                        // reste du Form) reste préférable.
                        // `.frame(minWidth:)` toujours nécessaire sur le
                        // conteneur : sans lui, cette ligne partage l'espace
                        // avec un Picker segmenté à largeur fixe (160pt) — sur
                        // macOS, l'un des deux se fait écraser à une largeur
                        // quasi nulle (invisible, non cliquable) au lieu de se
                        // répartir l'espace comme sur iOS. Retour d'usage
                        // 2026-08-19 : le champ montant disparaissait,
                        // rendant le formulaire impossible à valider
                        // (confirmDisabled restait vrai puisque le champ,
                        // invisible, ne pouvait jamais être rempli).
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
            .paneChrome(pattern != nil ? "Modifier" : (prefill != nil ? "Récurrent détecté" : "Nouveau récurrent"),
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark",
                        confirmDisabled: name.isEmpty || amount.isEmpty) {
                save(); dismiss()
            }
    }

    private func populateFields() {
        // Un pattern existant (édition) prime sur le pré-remplissage d'un
        // candidat détecté — les deux ne sont jamais fournis en même temps.
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
            // isManual reflète l'origine réelle : "détecté" si on part d'un
            // candidat (même ajusté), "saisi manuellement" sinon — cohérent
            // avec le champ "Origine" affiché dans PatternDetailPane.
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
