import SwiftUI

// MARK: - MoneyText
//
// Centralized component for displaying a monetary amount that **honors the
// global masking toggle** (`AppState.amountsHidden`). When masked, it shows a
// placeholder string ("•• ••• €") instead of the real value.
//
// **Why a dedicated component instead of a `String.maskedAmount`?**
//   - SwiftUI needs to redraw **automatically** when `amountsHidden` changes.
//     Via Environment(AppState), the component observes the flag.
//   - The transition animation between the 2 states is smooth thanks to
//     `.id()`, which forces a re-creation when the state changes.
//
// **Usage**:
//   ```swift
//   MoneyText(123.45)
//   MoneyText(123.45, font: AppTheme.Typography.moneyLarge, color: .green)
//   MoneyText(123.45, currency: "USD")
//   ```

struct MoneyText: View {
    @Environment(AppState.self) private var appState

    let amount: Double
    var currency: String = "EUR"
    var font: Font = AppTheme.Typography.moneySmall
    var color: Color = AppTheme.Colors.textPrimary
    /// Cosmetic detail: the masked value is displayed with a number of bullets
    /// proportional to the original size, keeping a consistent width so the
    /// layout doesn't jump (a masked amount reads as a "typical" amount for
    /// the app — neither too short nor too long).
    var maskedPlaceholder: String = "•• ••• €"

    /// Defaults to `.narrow` presentation (consistent with the rest of the app,
    /// which uses `.currency(code:).presentation(.narrow)`).
    var presentation: Decimal.FormatStyle.Currency.Configuration.Presentation = .narrow

    var body: some View {
        Group {
            if appState.amountsHidden {
                Text(maskedPlaceholder)
                    .monospacedDigit()  // avoids jitter between digits and bullets
            } else {
                Text(amount, format: .currency(code: currency).presentation(presentation))
            }
        }
        .font(font)
        .foregroundStyle(color)
        // Smooth transition on toggle. `.opacity` rather than a slide, so it
        // doesn't disturb the reading of the surrounding information.
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: appState.amountsHidden)
    }
}
