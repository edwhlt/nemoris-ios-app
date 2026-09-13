import SwiftUI
import TipKit

struct AddTricountReimbursementSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let defaultAmount: Double
    let currency: String
    /// Non-nil = editing an existing row — pre-filled instead of starting
    /// from the theoretical share calculation (a v44 fix: "Edit…" used to
    /// silently duplicate if the user changed the payee).
    var existingReimbursement: Reimbursement? = nil
    let onAdd: (Int, Double, String) -> Void

    private let txRepo = TransactionRepository()
    @State private var allTiers: [Tiers] = []
    @State private var selectedTiersId: Int = -1
    @State private var amountText: String = ""
    @State private var showTiersPicker = false

    private var parsedAmount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: "."))
    }

    private var selectedTiersName: String {
        guard selectedTiersId != -1 else { return "Aucun" }
        return allTiers.first(where: { $0.id == selectedTiersId })?.name ?? "Inconnu"
    }

    var body: some View {
            Form {
                Section("Personne qui me doit") {
                    Button {
                        showTiersPicker = true
                    } label: {
                        HStack {
                            Text("Tiers").foregroundStyle(AppTheme.Colors.textPrimary)
                            Spacer()
                            Text(selectedTiersName)
                                .foregroundStyle(selectedTiersId == -1 ? AppTheme.Colors.textSecondary : AppTheme.Colors.warning)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        }
                    }
                }

                Section("Montant dû") {
                    HStack {
                        Text("Montant (\(currency))")
                        Spacer()
                        // An empty title: the row already has its label ("Amount (…)")
                        // — see TransactionEditSheet for the macOS reason.
                        TextField("", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .nemorisFormStyle()
            .onAppear {
                if let existing = existingReimbursement {
                    amountText = String(format: "%.2f", abs(existing.amount))
                    selectedTiersId = existing.payeeId
                } else {
                    amountText = String(format: "%.2f", defaultAmount)
                }
                allTiers = txRepo.fetchTiers()
            }
            .sheet(isPresented: $showTiersPicker) {
                // Re-injecting \.locale is required: a level-2+ `.sheet()` on
                // macOS doesn't inherit the environment from an ancestor
                // above a `NavigationSplitView` (see CLAUDE.md §5).
                // `\.paneHostContext` too: this sheet is opened from a
                // view itself hosted in the macOS inspector (`.inspector`,
                // this sheet is presented via `.adaptivePane`) — without resetting to
                // `.modal`, `TiersSearchSheet`'s `.paneChrome` would publish
                // its buttons in the system bar instead of drawing them
                // in THIS separate window (no button visible).
                TiersSearchSheet(allTiers: allTiers, selectedId: $selectedTiersId)
                    .environment(\.locale, AppLocalization.locale)
                    .environment(\.paneHostContext, .modal)
            }
            .paneChrome(existingReimbursement == nil ? "Nouveau remboursement" : "Modifier le remboursement",
                        cancelLabel: "Annuler", onCancel: { dismiss() },
                        confirmLabel: existingReimbursement == nil ? "Ajouter" : "Enregistrer",
                        confirmIcon: existingReimbursement == nil ? "plus" : "checkmark",
                        confirmDisabled: parsedAmount == nil || selectedTiersId == -1) {
                guard let amount = parsedAmount, selectedTiersId != -1 else { return }
                onAdd(selectedTiersId, amount, currency)
                dismiss()
            }
    }
}
