import Foundation

// MARK: - Year display
//
// ⚠️ **SwiftUI trap**: `Text("Cumul \(year)")` does not perform a plain Swift
// interpolation. It resolves to `Text(_ key: LocalizedStringKey)`, and
// `LocalizedStringKey` formats interpolated `Int` values according to the
// current locale — including a thousands separator. In French, a year would
// render as "2 026".
//
// The same trap applies to every API that takes a `LocalizedStringKey`:
// `navigationTitle`, `Label`, `Section`, `Button`, `Toggle`, `Picker`…
//
// A year is an **identifier**, not a quantity: it should never be grouped.
// (Interpolating into a plain `String` doesn't have this problem — it's the
// conversion to `LocalizedStringKey` that triggers the formatting.)
//
// Usage: `Text("Cumul \(period.year.yearLabel)")`

extension Int {
    /// The year as plain text ("2026"), with no thousands separator.
    var yearLabel: String { String(self) }
}
