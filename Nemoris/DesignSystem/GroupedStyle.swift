import SwiftUI

// MARK: - Standard grouped-container style
//
// macOS has no native equivalent of iOS's `.insetGrouped` for `List` — this
// produces "raw" screens (edge-to-edge rows, flat sections) on desktop while
// the app uses rounded cards on iOS. Two tools bridge that gap:
//
// 1. `nemorisFormStyle()` — for any `Form`: native macOS rounded boxes
//    (`.formStyle(.grouped)`, System Settings look) painted with the app's
//    palette via the existing `.listRowBackground` calls. No-op on iOS
//    (Form there is already rendered insetGrouped).
// 2. `macGroupedRow(first:last:background:)` — for dynamic `List`s that
//    cannot become Forms (rowActions, pagination, refreshable…): draws the
//    per-row card via `.listRowBackground` (rounded corners on the group's
//    first/last row, internal divider like insetGrouped).
//    The List must be `.listStyle(.plain)` on macOS (neutral base).
//
// ⚠️ Conventions:
// - Every new `Form` must receive `.nemorisFormStyle()`.
// - Never combine `ZStack { Color.ignoresSafeArea(); Form }` (infinite
//   height on macOS) — use `Form { … }.background(…)`.

extension View {
    /// Standard `Form` style: native macOS grouped look (rounded boxes),
    /// fills the detail pane (otherwise the macOS Form takes its narrow
    /// intrinsic width), AND applies the app's background.
    ///
    /// ⚠️ The BACKGROUND IS INCLUDED HERE, deliberately.
    ///
    /// Leaving it to each view (`.scrollContentBackground(.hidden)` +
    /// `.background(…)`, three lines to duplicate) means screens that
    /// remembered it showed the palette's deep black while others fell back
    /// to the system's default gray — producing different flat backgrounds
    /// from one screen to the next, most visible between a module and the
    /// side pane.
    ///
    /// Baking it into the style makes the rule self-applying: any `Form`
    /// that receives `nemorisFormStyle()` is consistent, without anyone
    /// having to remember. Adding an extra `.background` on the view has no
    /// adverse effect (the last one wins, and it's the same color).
    ///
    /// ⚠️ Never replace with `ZStack { Color.ignoresSafeArea(); Form }`:
    /// produces infinite height on macOS.
    func nemorisFormStyle() -> some View {
        #if os(macOS)
        return self
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(AppTheme.Colors.background.ignoresSafeArea())
        #else
        return self
            .scrollContentBackground(.hidden)
            .background(AppTheme.Colors.background.ignoresSafeArea())
        #endif
    }

    /// Rounded per-row card for `List`s that stay `List`s.
    /// On iOS: simply applies `.listRowBackground(background)` (the native
    /// `.insetGrouped` draws the cards). On macOS: rounded first/last
    /// corners + horizontal inset + internal divider + spacing between
    /// groups.
    ///
    /// ⚠️ macOS implementation: the card is the background OF THE CONTENT
    /// (`.background` on the row), NOT a `.listRowBackground`. The row
    /// background's placement relative to `listRowInsets` is not reliable on
    /// macOS (asymmetric bottom padding observed) — attaching the background
    /// to the content instead makes the geometry deterministic: the card
    /// exactly wraps content + paddings.
    func macGroupedRow<Bg: View>(
        first: Bool = true,
        last: Bool = true,
        @ViewBuilder background: () -> Bg
    ) -> some View {
        #if os(macOS)
        return self
            .frame(maxWidth: .infinity, alignment: .leading)
            // Card's internal padding (top/bottom symmetric by construction).
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.top, first ? AppTheme.Spacing.sm : AppTheme.Spacing.xs)
            .padding(.bottom, last ? AppTheme.Spacing.sm : AppTheme.Spacing.xs)
            .background(
                background()
                    .clipShape(UnevenRoundedRectangle(
                        topLeadingRadius: first ? AppTheme.Radius.lg : 0,
                        bottomLeadingRadius: last ? AppTheme.Radius.lg : 0,
                        bottomTrailingRadius: last ? AppTheme.Radius.lg : 0,
                        topTrailingRadius: first ? AppTheme.Radius.lg : 0
                    ))
            )
            .overlay(alignment: .bottom) {
                if !last {
                    Divider()
                        .padding(.horizontal, AppTheme.Spacing.lg)
                }
            }
            // Margins OUTSIDE the card use REAL PADDING (always applied),
            // never `listRowInsets` — whether macOS `.plain` honors those is
            // unreliable, which left cards "stuck to the edges" despite the
            // inset value. Horizontal inset + spacing after the last row.
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.bottom, last ? AppTheme.Spacing.md : 0)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        #else
        return self.listRowBackground(background())
        #endif
    }

    /// Variant with the standard `surface` background.
    func macGroupedRow(first: Bool = true, last: Bool = true) -> some View {
        macGroupedRow(first: first, last: last) { AppTheme.Colors.surface }
    }

    /// Aligns a section header with the left edge of `macGroupedRow` cards.
    /// No-op on iOS.
    func macGroupedSectionHeader() -> some View {
        #if os(macOS)
        // Aligned with the left edge of the cards (same lateral margin as
        // the outside-the-card padding of `macGroupedRow`).
        return self.padding(.leading, AppTheme.Spacing.xl)
        #else
        return self
        #endif
    }
}
