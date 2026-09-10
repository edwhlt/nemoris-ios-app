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
                        // `LabeledContent` plutôt qu'un `TextField` nu : sur
                        // macOS, le titre d'un `TextField` devient un LABEL à
                        // gauche plutôt qu'un placeholder DANS le champ
                        // (contrairement à iOS) — le champ n'avait alors
                        // aucun label visible sur macOS. Un placeholder
                        // "0,00" puis `.textFieldStyle(.roundedBorder)` ont
                        // été essayés pour rendre le champ plus visiblement
                        // "éditable", puis retirés à la demande — le style
                        // natif (sans bordure ni placeholder, cohérent avec
                        // le reste du Form) reste préférable. Cf.
                        // PatternEditSheet (même symptôme). `.frame(minWidth:)`
                        // sur le conteneur : sans lui, cette ligne partage
                        // l'espace avec un Picker segmenté — sur macOS l'un
                        // des deux peut se faire écraser à une largeur quasi
                        // nulle (invisible, non cliquable) au lieu de se
                        // répartir l'espace comme sur iOS (retour d'usage
                        // 2026-08-19).
                        LabeledContent("Montant") {
                            TextField("", text: $amount)
                                .keyboardType(.decimalPad)
                        }
                        .frame(minWidth: 140)
                        Picker("", selection: $period) {
                            ForEach(BudgetPeriod.allCases, id: \.self) { p in Text(LocalizedStringKey(p.label)).tag(p) }
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
