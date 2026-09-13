import SwiftUI

// MARK: - GoalFormView
//
// A sheet for creating/editing a financial goal.
//
// **Templates**: 4 starters offered at the top of the form for new goals,
// to speed up the most common creations (emergency fund, down payment,
// net worth, zero debt). Tap → pre-fills name/kind/targetAmount, the user
// can still edit everything.
//
// **Adaptive fields**:
//   - kind == .custom → an editable "Current amount" field (no auto tracking)
//   - kind == .debtPayoff → targetAmount = 0 by default + an explanatory footer about
//     the persisted baseline
//   - all others → targetAmount visible, current derived from the Patrimoine snapshot

struct GoalFormView: View {
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let viewModel: PatrimoineViewModel
    let existingGoal: Goal?

    @State private var name: String
    @State private var kind: GoalKind
    @State private var targetAmountText: String
    @State private var hasDeadline: Bool
    @State private var deadlineDate: Date
    @State private var customCurrentAmountText: String
    @State private var notes: String

    @State private var showDeleteConfirm = false

    init(viewModel: PatrimoineViewModel, existingGoal: Goal? = nil) {
        self.viewModel = viewModel
        self.existingGoal = existingGoal

        _name = State(initialValue: existingGoal?.name ?? "")
        _kind = State(initialValue: existingGoal?.kind ?? .savings)
        let initialTarget = existingGoal?.targetAmount ?? 0
        _targetAmountText = State(initialValue: initialTarget == 0 ? "" : String(format: "%.2f", initialTarget))
        _hasDeadline = State(initialValue: existingGoal?.deadlineDate != nil)
        // Default: 1 year in the future if no deadline was entered
        _deadlineDate = State(initialValue: existingGoal?.deadlineDate
                              ?? Calendar.current.date(byAdding: .year, value: 1, to: Date()) ?? Date())
        let initialCustom = existingGoal?.customCurrentAmount ?? 0
        _customCurrentAmountText = State(initialValue: initialCustom == 0 ? "" : String(format: "%.2f", initialCustom))
        _notes = State(initialValue: existingGoal?.notes ?? "")
    }

    private var targetAmount: Double {
        Double(targetAmountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var customCurrentAmount: Double {
        Double(customCurrentAmountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // For debt_payoff, target = 0 is valid (= fully repaid).
        if kind == .debtPayoff { return true }
        return targetAmount > 0
    }

    var body: some View {
            Form {
                // ── Templates (creation only) ────────────────
                if existingGoal == nil {
                    Section {
                        templateRow(name: "Fonds d'urgence", target: 6000, kind: .savings,
                                    icon: "shield.lefthalf.filled", subtitle: "3 mois de dépenses")
                        templateRow(name: "Apport immobilier", target: 25000, kind: .savings,
                                    icon: "house.fill", subtitle: "Pour un futur achat")
                        templateRow(name: "Indépendance financière", target: 500000, kind: .netWorth,
                                    icon: "chart.pie.fill", subtitle: "Patrimoine net global")
                        templateRow(name: "Zéro dette", target: 0, kind: .debtPayoff,
                                    icon: "creditcard.trianglebadge.exclamationmark",
                                    subtitle: "Rembourser tous les prêts")
                    } header: {
                        Text("Starters (optionnel)")
                    } footer: {
                        Text("Tapez sur un modèle pour pré-remplir les champs. Vous pouvez tout modifier après.")
                            .font(AppTheme.Typography.bodySmall)
                    }
                }

                // ── Identity ────────────────────────────────────────
                Section("Identité") {
                    TextField("Nom de l'objectif", text: $name)
                        .autocorrectionDisabled()

                    Picker("Type", selection: $kind) {
                        ForEach(GoalKind.allCases, id: \.self) { k in
                            Label(LocalizedStringKey(k.label), systemImage: k.systemIcon).tag(k)
                        }
                    }
                    Text(kind.explanation)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }

                // ── Cible ───────────────────────────────────────────
                Section {
                    if kind != .debtPayoff {
                        HStack {
                            Text("Montant cible")
                                .font(AppTheme.Typography.bodyMedium)
                            Spacer()
                            // Empty title: the row already has its label ("Target
                            // amount") — see TransactionEditSheet for the macOS reason.
                            TextField("", text: $targetAmountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 160)
                        }
                    } else {
                        // debt_payoff: target always 0 (= debt cleared)
                        HStack {
                            Text("Montant cible")
                                .font(AppTheme.Typography.bodyMedium)
                            Spacer()
                            Text("0 € (dette remboursée)")
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }

                    if kind == .custom {
                        HStack {
                            Text("Montant actuel")
                                .font(AppTheme.Typography.bodyMedium)
                            Spacer()
                            // Empty title: the row already has its label ("Current
                            // amount") — see TransactionEditSheet.
                            TextField("", text: $customCurrentAmountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 160)
                        }
                    }
                } header: {
                    Text("Cible")
                } footer: {
                    if kind == .debtPayoff && existingGoal == nil {
                        Text("À la création, la dette actuelle est capturée comme baseline (= 100 % à atteindre). **Vous démarrerez à 0 %** — c'est normal, le compteur ne reflète que les remboursements à venir, pas l'historique antérieur du prêt.")
                            .font(AppTheme.Typography.bodySmall)
                    }
                }

                // ── Deadline ────────────────────────────────────────
                Section {
                    Toggle("Définir une date butoir", isOn: $hasDeadline)
                        .tint(AppTheme.Colors.accent)
                    if hasDeadline {
                        DatePicker("Date butoir", selection: $deadlineDate, in: Date()..., displayedComponents: .date)
                    }
                } footer: {
                    if hasDeadline {
                        Text("Une mensualité indicative sera affichée : combien mettre de côté chaque mois pour atteindre la cible à cette date.")
                            .font(AppTheme.Typography.bodySmall)
                    } else {
                        Text("Sans deadline, l'objectif est purement directionnel (pas de pression temporelle).")
                            .font(AppTheme.Typography.bodySmall)
                    }
                }

                Section("Note") {
                    TextField("Note libre", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if existingGoal != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Supprimer cet objectif")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .nemorisFormStyle()
            .confirmationDialog(
                "Supprimer cet objectif ?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Supprimer", role: .destructive) {
                    if let id = existingGoal?.id {
                        viewModel.deleteGoal(id: id)
                        dismiss()
                    }
                }
            }
            .paneChrome(existingGoal == nil ? "Nouvel objectif" : "Modifier",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: "Enregistrer", confirmIcon: "checkmark", confirmDisabled: !canSave,
                        onConfirm: { save() })
    }

    // MARK: - Template row

    @ViewBuilder
    private func templateRow(name templateName: String, target: Double, kind templateKind: GoalKind,
                             icon: String, subtitle: LocalizedStringKey) -> some View {
        Button {
            self.name = templateName
            self.kind = templateKind
            self.targetAmountText = target == 0 ? "" : String(format: "%.0f", target)
        } label: {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.accent)
                    .frame(width: 32, height: 32)
                    .background(AppTheme.Colors.accent.opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(templateName)
                        .font(AppTheme.Typography.bodyMedium)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Text(subtitle)
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Spacer()
                if target > 0 {
                    Text(target, format: .currency(code: "EUR").presentation(.narrow))
                        .font(AppTheme.Typography.labelLarge)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespaces)
        let notesValue: String? = trimmedNotes.isEmpty ? nil : trimmedNotes
        let deadline: Date? = hasDeadline ? deadlineDate : nil

        let success: Bool
        if let existing = existingGoal {
            var updated = existing
            updated.name = trimmedName
            updated.kind = kind
            updated.targetAmount = kind == .debtPayoff ? 0 : targetAmount
            updated.deadlineDate = deadline
            updated.customCurrentAmount = kind == .custom ? customCurrentAmount : 0
            updated.notes = notesValue
            success = viewModel.updateGoal(updated)
        } else {
            success = viewModel.createGoal(
                name: trimmedName,
                kind: kind,
                targetAmount: kind == .debtPayoff ? 0 : targetAmount,
                deadlineDate: deadline,
                customCurrentAmount: kind == .custom ? customCurrentAmount : 0,
                notes: notesValue
            )
        }

        if success {
            HapticService.shared.success()
            dismiss()
        } else {
            HapticService.shared.error()
            appState.postToast(.error, "Impossible d'enregistrer l'objectif.")
        }
    }
}
