import SwiftUI

// MARK: - EnvelopeSuggestionSheet
//
// Sheet triggered from BudgetView → "Suggest envelopes". Shows
// the suggestions computed by `EnvelopeSuggestionService`; the user toggles
// the ones they want to create, adjusts the amount inline if needed, then confirms.
//
// **Target UX**: creating 4-5 envelopes at once should take 30s
// max — otherwise the user goes fishing for amounts by hand and gives up.

struct EnvelopeSuggestionSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let viewModel: BudgetViewModel
    let existingEnvelopes: [BudgetEnvelope]
    let allCategories: [Category]

    @State private var suggestions: [EnvelopeSuggestion] = []
    @State private var selected: Set<Int> = []           // selected categoryIds
    @State private var customBudgets: [Int: Double] = [:] // override par categoryId
    @State private var isLoading: Bool = true
    @State private var isCreating: Bool = false

    var body: some View {
            Group {
                if isLoading {
                    loadingState
                } else if suggestions.isEmpty {
                    emptyState
                } else {
                    suggestionsList
                }
            }
            .background(AppTheme.Colors.background)
            .task { await loadSuggestions() }
            .paneChrome("Suggestions",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: isCreating ? "Création…" : "Créer (\(selected.count))",
                        confirmIcon: "plus",
                        confirmDisabled: selected.isEmpty || isCreating) {
                Task { await createSelected() }
            }
    }

    // MARK: - States

    @ViewBuilder private var loadingState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            ProgressView().controlSize(.large).tint(AppTheme.Colors.accent)
            Text("Analyse de vos 90 derniers jours…")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "envelope.open")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
            Text("Pas assez de données")
                .font(AppTheme.Typography.titleSmall)
                .foregroundStyle(AppTheme.Colors.textPrimary)
            Text("Importez plus de transactions ou créez des enveloppes manuellement. Il faut au moins 3 transactions et 30 € sur 90 jours par catégorie pour être suggéré.")
                .font(AppTheme.Typography.bodySmall)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppTheme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var suggestionsList: some View {
        List {
            Section {
                ForEach(suggestions) { sug in
                    suggestionRow(sug)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4,
                                                  leading: AppTheme.Spacing.lg,
                                                  bottom: 4,
                                                  trailing: AppTheme.Spacing.lg))
                }
            } header: {
                Text("\(suggestions.count) suggestion\(suggestions.count > 1 ? "s" : "")")
            } footer: {
                Text("Basé sur les **90 derniers jours**. Budget suggéré = moyenne mensuelle observée + 10 % de marge, arrondi à la dizaine supérieure.")
                    .font(AppTheme.Typography.bodySmall)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func suggestionRow(_ sug: EnvelopeSuggestion) -> some View {
        let isSelected = selected.contains(sug.categoryId)
        let displayedBudget = customBudgets[sug.categoryId] ?? sug.suggestedBudget
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: sug.categoryIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
                    .frame(width: 36, height: 36)
                    .background((isSelected ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary).opacity(0.13), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(sug.categoryName)
                        .font(AppTheme.Typography.titleSmall)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    (Text("\(sug.transactionCount) tx · moyenne ") + Text(sug.averageMonthly, format: .currency(code: "EUR").presentation(.narrow)) + Text("/mois"))
                        .font(AppTheme.Typography.bodySmall)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { newValue in
                        if newValue {
                            selected.insert(sug.categoryId)
                        } else {
                            selected.remove(sug.categoryId)
                            customBudgets.removeValue(forKey: sug.categoryId)
                        }
                        HapticService.shared.selection()
                    }
                ))
                .labelsHidden()
                .tint(AppTheme.Colors.accent)
            }

            // Amount-adjustment slider — visible only if selected
            if isSelected {
                VStack(spacing: 4) {
                    HStack {
                        Text("Budget")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                        Spacer()
                        Text(displayedBudget, format: .currency(code: "EUR").presentation(.narrow))
                            .font(AppTheme.Typography.titleSmall)
                            .foregroundStyle(AppTheme.Colors.accent)
                    }
                    // Range = 0.5× → 2× the default suggestion, €10 steps to
                    // stay on readable round amounts.
                    Slider(
                        value: Binding(
                            get: { customBudgets[sug.categoryId] ?? sug.suggestedBudget },
                            set: { newValue in
                                let rounded = (newValue / 10.0).rounded() * 10.0
                                customBudgets[sug.categoryId] = rounded
                            }
                        ),
                        in: max(10, sug.suggestedBudget * 0.5)...(sug.suggestedBudget * 2.0),
                        step: 10
                    )
                    .tint(AppTheme.Colors.accent)
                }
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(AppTheme.Colors.surface, in: RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .contentShape(Rectangle())
        .onTapGesture {
            // Tap the whole row to select — less friction than a tiny toggle
            if isSelected {
                selected.remove(sug.categoryId)
                customBudgets.removeValue(forKey: sug.categoryId)
            } else {
                selected.insert(sug.categoryId)
            }
            HapticService.shared.selection()
        }
    }

    // MARK: - Logic

    private func loadSuggestions() async {
        // Detached because fetchTransactionsAllAccounts can be a bit slow on
        // large databases. Not blocking for the UI thanks to `isLoading`.
        let result = await Task.detached(priority: .userInitiated) {
            EnvelopeSuggestionService.computeSuggestions(
                existingEnvelopes: existingEnvelopes,
                allCategories: allCategories
            )
        }.value
        suggestions = result
        // Pre-selects the 5 most impactful ones — minimal friction for the user,
        // who only has to confirm.
        selected = Set(result.prefix(5).map(\.categoryId))
        isLoading = false
    }

    private func createSelected() async {
        guard !selected.isEmpty else { return }
        isCreating = true
        defer { isCreating = false }
        let toCreate = suggestions.filter { selected.contains($0.categoryId) }
        let count = toCreate.count
        for sug in toCreate {
            let budget = customBudgets[sug.categoryId] ?? sug.suggestedBudget
            let env = BudgetEnvelope(
                id: 0,
                name: sug.categoryName,
                categoryId: sug.categoryId,
                amount: budget,
                period: .monthly,
                startDate: Date(),
                isActive: true
            )
            _ = BudgetRepository.shared.insertEnvelope(env)
        }
        // Refreshes the VM so the envelope list shows the new ones
        viewModel.refresh()
        HapticService.shared.success()
        appState.postToast(.success, "\(count) enveloppe\(count > 1 ? "s" : "") créée\(count > 1 ? "s" : "")")
        dismiss()
    }
}
