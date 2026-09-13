import Foundation

// MARK: - DashboardGridPlanner
//
// Splits cards into rows. **A pure function**, so testable with no UI.
//
// **Why not a `LazyVGrid`**: it can't span — `gridCellColumns()`
// only exists on `Grid`, which isn't lazy (all content would be mounted at
// once). And `GridItem(.adaptive(minimum:))` can't force a card to
// occupy the whole width. So rows are planned by hand and rendered
// in a `LazyVStack` of `HStack`s.

enum DashboardGridPlanner {

    /// Splits cards into rows, respecting the user's order.
    ///
    /// - A `.wide` card occupies its own row, alone.
    /// - `.compact` cards accumulate up to `columns`, and the current row
    ///   closes as soon as a `.wide` one is met or the row is full.
    ///
    /// Order is **always** preserved: a gap is never filled with a card
    /// further down, otherwise reordering in the customization screen would give
    /// an unpredictable result.
    static func rows(
        _ cards: [DashboardCardPreference],
        columns: Int
    ) -> [[DashboardCardPreference]] {
        let columns = max(1, columns)
        var rows: [[DashboardCardPreference]] = []
        var current: [DashboardCardPreference] = []

        func flush() {
            if !current.isEmpty {
                rows.append(current)
                current = []
            }
        }

        for card in cards {
            // A compact card on a 1-column grid takes up the full width:
            // no point distinguishing it from a wide one.
            if card.size == .wide || columns == 1 {
                flush()
                rows.append([card])
                continue
            }
            current.append(card)
            if current.count == columns { flush() }
        }
        flush()
        return rows
    }
}

// MARK: - DashboardLayoutMetrics

enum DashboardLayoutMetrics {

    /// Number of columns depending on the available width.
    ///
    /// ⚠️ Measured by a classic `GeometryReader`, not `onGeometryChange`:
    /// the latter needs macOS 15+, while the project targets macOS 14.0.
    static func columnCount(for width: CGFloat) -> Int {
        if width >= 900 { return 4 }   // Mac (default 1100×760 window), iPad landscape
        if width >= 500 { return 3 }   // iPad portrait, a narrow Mac window
        return 2                       // iPhone
    }

    /// A tile's floor height. Cards on the same row are then equalized
    /// on the tallest one (`maxHeight: .infinity` in the tile + `.top` alignment).
    static func minHeight(for size: DashboardCardSize) -> CGFloat {
        switch size {
        case .compact: return 132
        case .wide:    return 180
        }
    }
}
