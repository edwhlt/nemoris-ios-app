import SwiftUI

// MARK: - LoanFormView
//
// A sheet for creating/editing a loan. The `LoanType` picker determines both the
// calculation mode AND the display: deferral-specific fields only appear for
// DEFERRED_* types, and REVOLVING hides the rate + duration (not relevant).
//
// The "Preview" block at the bottom of the form recomputes live via `LoanCalculator`:
//   - The current monthly payment
//   - The remaining principal owed today
//   - The total interest paid to date
// → Editorial feedback while typing, and lets a scenario be tested before
// it's even saved.

struct LoanFormView: View {
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let viewModel: PatrimoineViewModel
    let existingLoan: PatrimoineLoan?

    // ── Champs ────────────────────────────────────────────────────
    @State private var name: String
    @State private var loanType: LoanType
    @State private var principalText: String
    /// Entered as a percentage (e.g. 3.4 = 3.4%). Converted to a decimal on save (÷100).
    @State private var annualRatePercentText: String
    @State private var durationMonths: Int
    @State private var deferralMonths: Int
    @State private var startDate: Date
    @State private var insuranceMonthlyText: String
    @State private var linkedRealEstateId: Int?
    @State private var notes: String

    // ── UI state ──────────────────────────────────────────────────
    @State private var showDeleteConfirm = false

    init(viewModel: PatrimoineViewModel, existingLoan: PatrimoineLoan? = nil) {
        self.viewModel = viewModel
        self.existingLoan = existingLoan

        _name = State(initialValue: existingLoan?.name ?? "")
        _loanType = State(initialValue: existingLoan?.loanType ?? .amortizing)
        let initialPrincipal = existingLoan?.principal ?? 0
        _principalText = State(initialValue: initialPrincipal == 0 ? "" : String(format: "%.2f", initialPrincipal))
        let initialRate = (existingLoan?.annualRate ?? 0) * 100
        _annualRatePercentText = State(initialValue: initialRate == 0 ? "" : String(format: "%.2f", initialRate))
        _durationMonths = State(initialValue: existingLoan?.durationMonths ?? 240)  // 20 years by default
        _deferralMonths = State(initialValue: existingLoan?.deferralMonths ?? 0)
        _startDate = State(initialValue: existingLoan?.startDate ?? Date())
        let initialInsurance = existingLoan?.insuranceMonthly ?? 0
        _insuranceMonthlyText = State(initialValue: initialInsurance == 0 ? "" : String(format: "%.2f", initialInsurance))
        _linkedRealEstateId = State(initialValue: existingLoan?.linkedRealEstateId)
        _notes = State(initialValue: existingLoan?.notes ?? "")
    }

    // MARK: - Computed

    private var principal: Double {
        Double(principalText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
    private var annualRate: Double {
        // The user enters a %, it's stored as a decimal (0.034 = 3.4%).
        (Double(annualRatePercentText.replacingOccurrences(of: ",", with: ".")) ?? 0) / 100
    }
    private var insuranceMonthly: Double {
        Double(insuranceMonthlyText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// A live preview of the loan as the form currently stands. Recomputed on every
    /// keystroke — a negligible cost (pure Swift, a few additions/exponentiations).
    private var livePreviewState: LoanState? {
        guard principal > 0 else { return nil }
        let draft = PatrimoineLoan(
            id: 0,
            name: "preview",
            loanType: loanType,
            principal: principal,
            annualRate: annualRate,
            durationMonths: max(1, durationMonths),
            deferralMonths: max(0, deferralMonths),
            startDate: startDate,
            insuranceMonthly: insuranceMonthly,
            linkedRealEstateId: nil,
            notes: nil,
            createdAt: Date()
        )
        return LoanCalculator.compute(loan: draft)
    }

    private var showsDeferralSection: Bool {
        loanType == .deferredTotal || loanType == .deferredPartial
    }

    private var hidesRateAndDuration: Bool {
        loanType == .revolving
    }

    // MARK: - Body

    var body: some View {
            Form {
                // ── Identity ────────────────────────────────────────
                Section("Identité") {
                    TextField("Nom (ex. Prêt immo Paris)", text: $name)
                        .autocorrectionDisabled()
                }

                // ── Loan type ────────────────────────────────────────
                Section {
                    Picker("Type", selection: $loanType) {
                        ForEach(LoanType.allCases, id: \.self) { t in
                            Text(LocalizedStringKey(t.label)).tag(t)
                        }
                    }
                    Text(LocalizedStringKey(loanType.explanation))
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } header: {
                    Text("Type de prêt")
                }

                // ── Characteristics ────────────────────────────────
                Section {
                    HStack {
                        Text(loanType == .revolving ? "Capital restant" : "Capital emprunté")
                            .font(AppTheme.Typography.bodyMedium)
                        Spacer()
                        // An empty title: the row already has its label — see
                        // TransactionEditSheet for the macOS reason.
                        TextField("", text: $principalText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 160)
                    }

                    if !hidesRateAndDuration {
                        HStack {
                            Text("Taux annuel")
                                .font(AppTheme.Typography.bodyMedium)
                            Spacer()
                            TextField("", text: $annualRatePercentText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                            Text("%")
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }

                        Stepper(value: $durationMonths, in: 1...600, step: 12) {
                            HStack {
                                Text("Durée")
                                    .font(AppTheme.Typography.bodyMedium)
                                Spacer()
                                Text(durationLabel(durationMonths))
                                    .font(AppTheme.Typography.bodyMedium)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                            }
                        }
                    }

                    DatePicker("Date de début", selection: $startDate, displayedComponents: .date)
                } header: {
                    Text("Caractéristiques")
                }

                // ── Deferral (conditional) ──────────────────────────
                if showsDeferralSection {
                    Section {
                        Stepper(value: $deferralMonths, in: 0...max(durationMonths - 1, 0), step: 1) {
                            HStack {
                                Text("Mois de différé")
                                    .font(AppTheme.Typography.bodyMedium)
                                Spacer()
                                Text("\(deferralMonths) mois")
                                    .font(AppTheme.Typography.bodyMedium)
                                    .foregroundStyle(AppTheme.Colors.textPrimary)
                            }
                        }
                    } header: {
                        Text("Période de différé")
                    } footer: {
                        Text(loanType == .deferredTotal
                             ? "Aucun paiement pendant le différé ; les intérêts sont capitalisés et rajoutés au capital."
                             : "Seuls les intérêts sont payés pendant le différé ; le capital reste inchangé.")
                            .font(AppTheme.Typography.bodySmall)
                    }
                }

                // ── Borrower's insurance ────────────────────────────
                // A separate monthly cost — does NOT change the amortization calculation.
                Section {
                    HStack {
                        Text("Assurance / mois")
                            .font(AppTheme.Typography.bodyMedium)
                        Spacer()
                        TextField("", text: $insuranceMonthlyText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 160)
                    }
                    if insuranceMonthly > 0 && durationMonths > 0 {
                        HStack {
                            Text("Coût total estimé")
                                .font(AppTheme.Typography.labelMedium)
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                            Spacer()
                            Text(insuranceMonthly * Double(durationMonths),
                                 format: .currency(code: "EUR").presentation(.narrow))
                                .font(AppTheme.Typography.labelLarge)
                                .foregroundStyle(AppTheme.Colors.warning)
                        }
                    }
                } header: {
                    Text("Assurance emprunteur")
                } footer: {
                    Text("Charge mensuelle indépendante de la mensualité du prêt. N'affecte pas le capital restant dû. Laissez à 0 si vous ne souhaitez pas la suivre ici.")
                        .font(AppTheme.Typography.bodySmall)
                }

                // ── Linked real-estate property (optional) ─────────────────
                if !viewModel.realEstates.isEmpty {
                    Section {
                        Picker("Bien lié", selection: Binding(
                            get: { linkedRealEstateId ?? -1 },
                            set: { linkedRealEstateId = ($0 == -1 ? nil : $0) }
                        )) {
                            Text("Aucun").tag(-1)
                            ForEach(viewModel.realEstates) { item in
                                Text(item.name).tag(item.id)
                            }
                        }
                    } header: {
                        Text("Bien immobilier lié")
                    } footer: {
                        Text("Optionnel. Si vous vendez le bien, le prêt deviendra orphelin mais ne sera pas supprimé.")
                            .font(AppTheme.Typography.bodySmall)
                    }
                }

                // ── Live preview ─────────────────────────────────────
                if let preview = livePreviewState {
                    Section {
                        previewRow(label: "Mensualité prêt",
                                   value: preview.monthlyPayment,
                                   tint: AppTheme.Colors.textPrimary)
                        if insuranceMonthly > 0 {
                            previewRow(label: "Assurance / mois",
                                       value: insuranceMonthly,
                                       tint: AppTheme.Colors.warning)
                            previewRow(label: "Coût mensuel total",
                                       value: preview.monthlyPayment + insuranceMonthly,
                                       tint: AppTheme.Colors.textPrimary)
                        }
                        previewRow(label: "Capital restant dû",
                                   value: preview.remainingCapital,
                                   tint: AppTheme.Colors.danger)
                        if preview.capitalPaid > 0 {
                            previewRow(label: "Capital remboursé",
                                       value: preview.capitalPaid,
                                       tint: AppTheme.Colors.success)
                        }
                        if preview.interestsPaid > 0 {
                            previewRow(label: loanType == .deferredTotal && preview.monthsElapsed < deferralMonths
                                              ? "Intérêts capitalisés (différé)"
                                              : "Intérêts payés à date",
                                       value: preview.interestsPaid,
                                       tint: AppTheme.Colors.warning)
                        }
                    } header: {
                        Text("Aperçu à aujourd'hui")
                    } footer: {
                        if preview.isPending {
                            Text("Le prêt n'a pas encore commencé.")
                                .font(AppTheme.Typography.bodySmall)
                        } else if preview.isCompleted {
                            Text("Le prêt est entièrement remboursé selon la formule.")
                                .font(AppTheme.Typography.bodySmall)
                        }
                    }
                }

                Section("Note") {
                    TextField("Note libre", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if existingLoan != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Supprimer ce prêt")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .confirmationDialog(
                "Supprimer ce prêt ?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) {
                    if let id = existingLoan?.id {
                        viewModel.deleteLoan(id: id)
                        dismiss()
                    }
                }
            } message: {
                Text("Cette action ne peut pas être annulée.")
            }
            .paneChrome(existingLoan == nil ? "Nouveau prêt" : "Modifier",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark", confirmDisabled: !canSave,
                        onConfirm: { save() })
    }

    // MARK: - Helpers UI

    @ViewBuilder
    private func previewRow(label: LocalizedStringKey, value: Double, tint: Color) -> some View {
        HStack {
            Text(label)
                .font(AppTheme.Typography.bodyMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)
            Spacer()
            Text(value, format: .currency(code: "EUR").presentation(.narrow))
                .font(AppTheme.Typography.titleSmall)
                .foregroundStyle(tint)
        }
    }

    /// A human-readable duration (e.g. "240 months · 20 years" or "18 months · 1 year and 6 months").
    private func durationLabel(_ months: Int) -> String {
        let years = months / 12
        let rem = months % 12
        if years == 0 { return "\(months) mois" }
        if rem == 0 { return "\(months) mois · \(years) an\(years > 1 ? "s" : "")" }
        return "\(months) mois · \(years) an\(years > 1 ? "s" : "") et \(rem) mois"
    }

    // MARK: - Save

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        let notesValue: String? = trimmedNotes.isEmpty ? nil : trimmedNotes

        // For REVOLVING, deferralMonths is clamped to 0 and the entered duration is ignored.
        let safeDeferral = (loanType == .deferredTotal || loanType == .deferredPartial)
            ? deferralMonths
            : 0

        let success: Bool
        if let existing = existingLoan {
            var updated = existing
            updated.name = trimmedName
            updated.loanType = loanType
            updated.principal = principal
            updated.annualRate = annualRate
            updated.durationMonths = durationMonths
            updated.deferralMonths = safeDeferral
            updated.startDate = startDate
            updated.insuranceMonthly = insuranceMonthly
            updated.linkedRealEstateId = linkedRealEstateId
            updated.notes = notesValue
            success = viewModel.updateLoan(updated)
        } else {
            success = viewModel.createLoan(
                name: trimmedName,
                loanType: loanType,
                principal: principal,
                annualRate: annualRate,
                durationMonths: durationMonths,
                deferralMonths: safeDeferral,
                startDate: startDate,
                insuranceMonthly: insuranceMonthly,
                linkedRealEstateId: linkedRealEstateId,
                notes: notesValue
            )
        }

        if success {
            HapticService.shared.success()
            dismiss()
        } else {
            HapticService.shared.error()
            appState.postToast(.error, "Impossible d'enregistrer ce prêt. Réessayez.")
        }
    }
}
