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
    @State private var showCategoryPicker = false

    var body: some View {
            Form {
                Section {
                    TextField("Nom (ex: Alimentation)", text: $name)
                    HStack {
                        // `LabeledContent` rather than a bare `TextField`: on
                        // macOS, a `TextField`'s title becomes a LABEL on the
                        // left rather than a placeholder INSIDE the field
                        // (unlike on iOS) — the field then had
                        // no visible label on macOS. A
                        // "0.00" placeholder then `.textFieldStyle(.roundedBorder)`
                        // were tried to make the field look more visibly
                        // "editable", then removed on request — the
                        // native style (no border or placeholder, consistent with
                        // the rest of the Form) remains preferable. See
                        // PatternEditSheet (same symptom). `.frame(minWidth:)`
                        // on the container: without it, this row shares
                        // the space with a segmented Picker — on macOS one
                        // of the two can get squeezed to near-zero
                        // width (invisible, unclickable) instead of
                        // splitting the space as on iOS.
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
            .adaptivePane(isPresented: $showCategoryPicker) {
                CategoryQuickPickSheet(currentCategoryId: categoryId, allCategories: vm.categories) { newId, _ in
                    categoryId = newId
                }
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
