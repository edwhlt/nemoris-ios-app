import Foundation

// MARK: - Robust construction of aggregated evolution curves
//
// Shared by the global level AND the account level, so the two can never
// diverge. PURE engine (no database/cache/network access), therefore
// deterministic and testable.
//
// ─── Three traps an aggregation must avoid ─────────────────────────────────
//
// 1. A GRID MADE OF THE UNION OF RAW TIMESTAMPS.
//    Two positions synced from different sources don't share the same hours
//    (09:05Z vs 17:35Z). Their union produces an irregular grid where, at
//    each instant, only one of the series "really" has a point.
//
// 2. FALLING BACK TO THE AVERAGE COST (`averageBuyPrice`) when no price is
//    known. The average cost is an ACQUISITION COST, not a price. It can sit
//    on a completely different scale from the market price (average cost
//    €250 for a security trading at €40). Each fallback makes the total jump
//    by thousands of euros → a sawtooth curve whose peaks equal exactly the
//    amount invested.
//
// 3. FORWARD-FILL ONLY, no back-fill: before a position's first point, the
//    value would fall back to the average cost (see 2) instead of its first
//    known price.
//
// ─── Guarantees ────────────────────────────────────────────────────────────
//
// • REGULAR grid (no empty bucket, no alternation) → one point per time step,
//   a prerequisite for clean Swift Charts rendering.
// • The average cost NEVER enters a valuation curve. A position with no price
//   at all is EXCLUDED from the curve and reported to the caller (diagnostic),
//   rather than poisoning the aggregate with a value on another scale.
// • Back-fill + forward-fill with the position's own prices (first known price
//   before its history, last known price after).
// • BOUNDED number of points (~150 max): charts stay smooth and axis labels
//   readable whatever the range.

/// A position ready to be aggregated: its quantity and its price history,
/// ALREADY resolved (ISIN → ticker → sync symbol) and sorted.
struct PortfolioSeriesInput {
    let positionId: Int
    let quantity: Double
    let history: [InvestmentPricePoint]
}

enum PortfolioEvolutionBuilder {

    /// Target number of points for a curve. Upper bound: beyond it, axis labels
    /// overlap and rendering degrades with no information gained.
    private static let targetPointCount = 150

    struct Result {
        /// Aggregated curve, one point per grid step, sorted.
        let points: [PortfolioEvolutionPoint]
        /// Positions actually valued with a real price.
        let pricedPositionIds: Set<Int>
        /// Positions WITHOUT any price over the range → excluded from the curve.
        /// The UI must report them ("X positions without history").
        let unpricedPositionIds: Set<Int>
    }

    /// Builds the aggregated curve over a regular time grid.
    ///
    /// - Parameters:
    ///   - inputs: positions + resolved histories.
    ///   - range: selected range (sets the grid's start and step).
    ///   - now: injectable for tests.
    static func build(inputs: [PortfolioSeriesInput],
                      range: InvestmentTimeRange,
                      now: Date = Date()) -> Result {

        // 1. Separate positions that can be valued from those without any price.
        //    A position without a price is EXCLUDED (never replaced by its average cost).
        var priced: [PortfolioSeriesInput] = []
        var unpriced: Set<Int> = []
        for input in inputs {
            let usable = input.history.filter { $0.close.isFinite && $0.close > 0 }
            if usable.isEmpty {
                unpriced.insert(input.positionId)
            } else {
                priced.append(PortfolioSeriesInput(
                    positionId: input.positionId,
                    quantity: input.quantity,
                    history: usable.sorted { $0.date < $1.date }
                ))
            }
        }
        guard !priced.isEmpty else {
            return Result(points: [], pricedPositionIds: [], unpricedPositionIds: unpriced)
        }

        // 2. Grid bounds.
        //    End = now (the present is the reference; a series that stops yesterday
        //    gives a flat step up to now, which is honest and avoids a chart that
        //    "stops" for no visible reason).
        //    Start = start of the range, or the oldest known price for "Max".
        let earliest = priced.compactMap { $0.history.first?.date }.min() ?? now
        let latest = priced.compactMap { $0.history.last?.date }.max() ?? now

        // Special case of the 1D range: the grid is anchored on the last quote,
        // not on `now`. Outside trading hours (evening, weekend, before the open)
        // the whole last session is more than 24 h old, so a [now-24h, now] grid
        // would contain NO real point and the curve would flatten onto a single
        // back-filled value. Show the last 24 TRADED hours instead — same rule as
        // the position chart (see `lastQuotedWindow`).
        let oneDayWindow: TimeInterval = 86_400
        let start: Date
        let end: Date
        if range == .oneDay, latest < now.addingTimeInterval(-oneDayWindow) {
            end = latest
            start = max(latest.addingTimeInterval(-oneDayWindow), earliest)
        } else {
            start = max(range.startDate ?? earliest, earliest)
            end = max(now, latest)
        }
        guard end > start else {
            // Degenerate range (a single date): a single point, no grid.
            let total = priced.reduce(0.0) { acc, input in
                acc + input.quantity * (input.history.last?.close ?? 0)
            }
            return Result(
                points: [PortfolioEvolutionPoint(date: end, value: total)],
                pricedPositionIds: Set(priced.map(\.positionId)),
                unpricedPositionIds: unpriced
            )
        }

        // 3. Grid step. Floor = the data's real granularity (30 min for intraday on
        //    1D, otherwise 1 day) — going finer would only duplicate values.
        //    Ceiling = span / targetPointCount.
        let span = end.timeIntervalSince(start)
        let minimumBucket: TimeInterval = (range == .oneDay) ? 1800 : 86_400
        let bucket = max(minimumBucket, span / Double(targetPointCount))

        // 4. Normalize each series onto the grid: for each bucket, the LAST price
        //    observed in that bucket (the step's close).
        //    Then back-fill (before the 1st price) and forward-fill (after).
        let bucketCount = max(1, Int((span / bucket).rounded(.up)))
        var totals = [Double](repeating: 0, count: bucketCount + 1)

        for input in priced {
            var bucketPrice = [Double?](repeating: nil, count: bucketCount + 1)
            for point in input.history {
                let offset = point.date.timeIntervalSince(start)
                // Points before the grid's start serve as the initial value (index 0):
                // that's what makes a correct back-fill possible.
                let index = offset <= 0 ? 0 : min(bucketCount, Int(offset / bucket))
                bucketPrice[index] = point.close   // last one wins (sorted series)
            }

            // Back-fill: before the first known price, use THAT price (never the
            // average cost) → no artificial step at the start of the curve.
            let firstKnown = bucketPrice.compactMap { $0 }.first ?? 0
            var carried = firstKnown
            for index in 0...bucketCount {
                if let price = bucketPrice[index] {
                    carried = price          // newly observed price
                }
                // carried = forward-fill of the last known price
                totals[index] += input.quantity * carried
            }
        }

        // 5. Emit the curve.
        var points: [PortfolioEvolutionPoint] = []
        points.reserveCapacity(bucketCount + 1)
        for index in 0...bucketCount {
            let date = start.addingTimeInterval(Double(index) * bucket)
            points.append(PortfolioEvolutionPoint(date: min(date, end), value: totals[index]))
        }

        // A single point per date (the last bucket may be clamped to `end`).
        var seen = Set<Date>()
        let deduped = points.filter { seen.insert($0.date).inserted }

        return Result(
            points: deduped,
            pricedPositionIds: Set(priced.map(\.positionId)),
            unpricedPositionIds: unpriced
        )
    }
}
