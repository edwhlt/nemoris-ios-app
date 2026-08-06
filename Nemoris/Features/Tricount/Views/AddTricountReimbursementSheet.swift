import SwiftUI
import TipKit

struct AddTricountReimbursementSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    let defaultAmount: Double
    let currency: String
    /// Non-nil = édition d'une ligne existante — préchargée au lieu de repartir
    /// du calcul théorique de part (fix bug v44 AXE R : "Modifier…" dupliquait
    /// silencieusement si l'utilisateur changeait de payee).
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
                        TextField("0.00", text: $amountText)
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
                TiersSearchSheet(allTiers: allTiers, selectedId: $selectedTiersId)
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
