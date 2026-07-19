import SwiftUI

// MARK: - MoneyText
//
// Composant centralisé pour afficher un montant monétaire qui **respecte le
// toggle de masquage global** (`AppState.amountsHidden`). Quand masqué, affiche
// une chaîne placeholder ("•• ••• €") au lieu de la valeur réelle.
//
// **Pourquoi un composant dédié et pas un `String.maskedAmount`** ?
//   - On veut que SwiftUI redessine **automatiquement** quand `amountsHidden`
//     change. Via Environment(AppState), le composant observe le flag.
//   - L'animation de transition entre les 2 états est fluide grâce à `.id()`
//     qui force une re-création quand l'état change.
//
// **Usage** :
//   ```swift
//   MoneyText(123.45)
//   MoneyText(123.45, font: AppTheme.Typography.moneyLarge, color: .green)
//   MoneyText(123.45, currency: "USD")
//   ```
//
// **Migration** : on remplace les `Text(amount, format: .currency(code: "EUR")...)`
// existants progressivement. Pas tout d'un coup — seules les zones où la
// confidentialité importe vraiment (heros, bandeaux, rows transactions).

struct MoneyText: View {
    @Environment(AppState.self) private var appState

    let amount: Double
    var currency: String = "EUR"
    var font: Font = AppTheme.Typography.moneySmall
    var color: Color = AppTheme.Colors.textPrimary
    /// Variation cosmétique : valeur masquée affichée avec un nombre de bullets
    /// proportionnel à la taille d'origine. Permet de garder une largeur cohérente
    /// pour ne pas faire sauter le layout (un montant masqué ressemble à un montant
    /// "moyen" de l'app — pas un short ni un trop long).
    var maskedPlaceholder: String = "•• ••• €"

    /// Style de présentation `.narrow` par défaut (cohérent avec le reste de l'app
    /// qui utilise `.currency(code:).presentation(.narrow)`).
    var presentation: Decimal.FormatStyle.Currency.Configuration.Presentation = .narrow

    var body: some View {
        Group {
            if appState.amountsHidden {
                Text(maskedPlaceholder)
                    .monospacedDigit()  // évite le sautillement entre les chiffres et les bullets
            } else {
                Text(amount, format: .currency(code: currency).presentation(presentation))
            }
        }
        .font(font)
        .foregroundStyle(color)
        // Transition douce quand on toggle. `.opacity` plutôt qu'un slide
        // pour ne pas perturber la lecture des autres infos autour.
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: appState.amountsHidden)
    }
}
