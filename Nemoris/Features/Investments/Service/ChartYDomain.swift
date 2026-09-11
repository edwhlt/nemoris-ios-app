import Foundation

/// Vertical domain of a price or valuation chart.
///
/// Single rule: **the scale comes from the series actually drawn over the
/// selected range**, never from a value that lives outside it. Without it,
/// changing the range only moves the x-axis — the y-axis stays stretched by
/// an out-of-view marker, and the curve squashes into a few pixels and reads
/// as a straight line even though it moves.
///
/// Two concrete traps:
///
/// 1. **An out-of-range marker dictates the scale.** The average cost of a
///    security bought at €250 that trades at €40 forces a 0–270 domain on
///    EVERY range; the month's real movement (39 → 41 €) becomes invisible.
///    Hence `references`: these values may widen the domain only if they fall
///    within reach of the series (`referenceTolerance`); otherwise they are
///    ignored — it's up to the drawing code to hide the now out-of-view
///    marker (`domain.contains(marker)`).
///
/// 2. **Padding proportional to the VALUE instead of the RANGE.** A
///    `lo * 0.92 ... hi * 1.08` on a 39–41 € series gives 35.9–44.3: the
///    padding is four times the real range and flattens the curve on its own,
///    average cost or not. Here the padding is a fraction of the range.
enum ChartYDomain {

    /// Fallback domain when there is strictly nothing to plot.
    static let fallback: ClosedRange<Double> = 0...1

    /// - Parameters:
    ///   - values: the series DRAWN over the displayed range. It alone sets the
    ///     scale.
    ///   - references: secondary markers (average cost, an order's price) that
    ///     must not dictate the scale. They widen the domain only if they fall
    ///     within reach of the series.
    ///   - padding: top and bottom breathing room, as a fraction of the range.
    ///   - referenceTolerance: maximum distance, as a fraction of the range, at
    ///     which a marker may still widen the domain.
    ///   - clampToZero: lower bound at 0 — for a price or a valuation, which
    ///     never go below zero.
    static func compute(values: [Double],
                        references: [Double] = [],
                        padding: Double = 0.12,
                        referenceTolerance: Double = 0.6,
                        clampToZero: Bool = false) -> ClosedRange<Double> {
        let série = values.filter(\.isFinite)
        let repères = references.filter(\.isFinite)

        guard let bas = série.min(), let haut = série.max() else {
            // No series: the markers become the only information available, and as
            // such regain the right to set the scale.
            guard let basRepère = repères.min(), let hautRepère = repères.max() else {
                return fallback
            }
            return padded(basRepère, hautRepère, padding: padding, clampToZero: clampToZero)
        }

        // Minimum range: a flat series must yield neither a degenerate domain nor a
        // zero tolerance that would exclude even a marker sitting on the curve.
        let amplitude = floorSpan(bas, haut)
        let marge = amplitude * max(0, referenceTolerance)

        var bornBas = bas
        var bornHaut = haut
        for repère in repères {
            if repère < bornBas, repère >= bas - marge {
                bornBas = repère
            } else if repère > bornHaut, repère <= haut + marge {
                bornHaut = repère
            }
        }

        return padded(bornBas, bornHaut, padding: padding, clampToZero: clampToZero)
    }

    /// Range used for the computation: never zero, and at least 2% of the
    /// displayed value, so a perfectly flat series keeps a readable band rather
    /// than a line in the middle of a microscopic domain.
    private static func floorSpan(_ bas: Double, _ haut: Double) -> Double {
        max(haut - bas, abs(haut) * 0.02, 0.0001)
    }

    private static func padded(_ bas: Double, _ haut: Double,
                               padding: Double, clampToZero: Bool) -> ClosedRange<Double> {
        let marge = floorSpan(bas, haut) * max(0, padding)
        let bornBas = clampToZero ? max(0, bas - marge) : bas - marge
        let bornHaut = haut + marge
        // `ClosedRange` requires lower <= upper: clamping to zero on a series that
        // is itself at zero could otherwise produce an inverted range.
        return bornBas...max(bornHaut, bornBas + 0.0001)
    }
}
