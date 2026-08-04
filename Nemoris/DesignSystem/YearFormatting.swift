import Foundation

// MARK: - Affichage des millésimes
//
// ⚠️ **Piège SwiftUI** : `Text("Cumul \(year)")` ne fait PAS une interpolation Swift
// ordinaire. La signature prise est `Text(_ key: LocalizedStringKey)`, et
// `LocalizedStringKey` formate les `Int` interpolés selon la locale courante — donc
// avec séparateur de milliers. En français, une année s'affichait « 2 026 ».
//
// Le même piège s'applique à toutes les API qui prennent un `LocalizedStringKey` :
// `navigationTitle`, `Label`, `Section`, `Button`, `Toggle`, `Picker`…
//
// Une année est un **identifiant**, pas une quantité : elle ne se groupe jamais.
// (Une interpolation dans une `String` normale n'a pas le problème — c'est bien la
// conversion en `LocalizedStringKey` qui déclenche le formatage.)
//
// Usage : `Text("Cumul \(period.year.yearLabel)")`

extension Int {
    /// Le millésime en texte brut (« 2026 »), sans séparateur de milliers.
    var yearLabel: String { String(self) }
}
