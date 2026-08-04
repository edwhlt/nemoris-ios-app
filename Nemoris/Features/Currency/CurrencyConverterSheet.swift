import SwiftUI

// MARK: - CurrencyConverterSheet
//
// Sheet de conversion de devises — accessible depuis Settings → Confidentialité.
// MVP : usage ad-hoc (l'user tape un montant + 2 devises). Pas de conversion
// automatique des transactions de la base — c'est une calculatrice avec cache
// des taux + persistance dans `currency_rates`.
//
// **Flux** :
//   - User saisit montant + from + to
//   - Tap "Convertir" → CurrencyService.convert() (cache RAM/SQL/réseau)
//   - Affichage résultat avec taux utilisé + date du taux
//
// Devise par défaut au launch :
//   - `from` = devise préférée user (AppState.preferredCurrency)
//   - `to`   = EUR (sauf si preferredCurrency == EUR, alors USD)

struct CurrencyConverterSheet: View {
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var amountText: String = "100"
    @State private var fromCurrency: String
    @State private var toCurrency: String
    @State private var convertedAmount: Double? = nil
    @State private var rate: Double? = nil
    @State private var isConverting: Bool = false
    @State private var errorMessage: String? = nil

    init() {
        let preferred = UserDefaults.standard.string(forKey: "preferredCurrency") ?? "EUR"
        _fromCurrency = State(initialValue: preferred)
        _toCurrency = State(initialValue: preferred == "EUR" ? "USD" : "EUR")
    }

    private var amount: Double {
        Double(amountText.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    var body: some View {
            Form {
                Section("Montant") {
                    HStack {
                        TextField("0,00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 22, weight: .semibold))
                        Picker("De", selection: $fromCurrency) {
                            ForEach(CurrencyService.supportedCurrencies) { c in
                                Text(c.code).tag(c.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(AppTheme.Colors.accent)
                    }
                }

                Section {
                    Button {
                        // Swap from ↔ to (UX classique des convertisseurs)
                        let tmp = fromCurrency
                        fromCurrency = toCurrency
                        toCurrency = tmp
                        convertedAmount = nil
                        rate = nil
                        HapticService.shared.selection()
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                                .font(.system(size: 22))
                            Text("Inverser")
                            Spacer()
                        }
                    }
                    .tint(AppTheme.Colors.accent)
                }

                Section("Vers") {
                    HStack {
                        if let converted = convertedAmount {
                            Text(converted, format: .number.precision(.fractionLength(0...2)))
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.accent)
                        } else {
                            Text("—")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                        Spacer()
                        Picker("Vers", selection: $toCurrency) {
                            ForEach(CurrencyService.supportedCurrencies) { c in
                                Text(c.code).tag(c.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(AppTheme.Colors.accent)
                    }
                    if let r = rate {
                        Text("1 \(fromCurrency) = \(r.formatted(.number.precision(.fractionLength(0...6)))) \(toCurrency)")
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .font(AppTheme.Typography.bodySmall)
                            .foregroundStyle(AppTheme.Colors.danger)
                    }
                }

                Section {
                    Button {
                        Task { await convert() }
                    } label: {
                        HStack {
                            Spacer()
                            if isConverting {
                                ProgressView().controlSize(.small)
                                    .padding(.trailing, 6)
                            }
                            Text("Convertir")
                                .font(AppTheme.Typography.titleSmall)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(amount <= 0 || isConverting || fromCurrency == toCurrency)
                    .tint(AppTheme.Colors.accent)
                } footer: {
                    Text("Taux de change mis à jour quotidiennement. Mis en cache localement après le 1er fetch.")
                        .font(AppTheme.Typography.bodySmall)
                }

                // Devise préférée — utilisée comme default `from` au prochain
                // lancement du sheet.
                Section {
                    Picker(selection: Binding(
                        get: { appState.preferredCurrency },
                        set: { appState.preferredCurrency = $0 }
                    )) {
                        ForEach(CurrencyService.supportedCurrencies) { c in
                            Text("\(c.code) — \(c.name)").tag(c.code)
                        }
                    } label: {
                        Label("Devise préférée", systemImage: "globe.europe.africa.fill")
                    }
                } header: {
                    Text("Préférence")
                }
            }
            .nemorisFormStyle()
            .paneChrome("Convertisseur", cancelLabel: "Fermer", onCancel: { dismiss() })
    }

    private func convert() async {
        isConverting = true
        errorMessage = nil
        defer { isConverting = false }
        guard let r = await CurrencyService.shared.rate(from: fromCurrency, to: toCurrency, date: Date()) else {
            errorMessage = "Impossible de récupérer le taux. Vérifiez votre connexion."
            HapticService.shared.error()
            return
        }
        rate = r
        convertedAmount = amount * r
        HapticService.shared.success()
    }
}
