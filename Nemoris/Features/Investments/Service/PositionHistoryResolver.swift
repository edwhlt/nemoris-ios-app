import Foundation

/// ROBUST resolution of a position's price history, shared with the widget
/// (`WidgetDataStore`) so the logic is never duplicated — same doctrine as
/// `PortfolioEvolutionBuilder`: one computation, never two diverging
/// implementations.
///
/// `@MainActor` because `PriceHistoryCache` is (shared JSON disk cache).
@MainActor
enum PositionHistoryResolver {

    /// History to aggregate for a position over a given range.
    /// Adaptive granularity: the 1D view uses the 30-min INTRADAY series (the
    /// daily series has a single point over a rolling 24 h). If intraday is
    /// missing for this position, it falls back to its DAILY series (unfiltered):
    /// the builder will hold it flat at its last real price — never at the
    /// average cost.
    static func seriesHistory(for position: InvestmentPosition,
                              range: InvestmentTimeRange) -> [InvestmentPricePoint] {
        if range == .oneDay {
            let intraday = intradaySeries(for: position)
            if !intraday.isEmpty { return intraday }
            return resolveHistory(for: position, cutoff: nil, resolution: .daily)
        }
        return resolveHistory(for: position, cutoff: range.startDate, resolution: .daily)
    }

    /// A position's intraday series, bounded to the last 24 TRADED hours.
    ///
    /// No `cutoff: range.startDate`: a window anchored on `Date()` is EMPTY as
    /// soon as it's viewed outside trading hours (on Saturday, Friday's last
    /// quote is more than 24 h old). The whole series is read (96 h retention),
    /// then the last 24 h anchored on the last real point are kept.
    static func intradaySeries(for position: InvestmentPosition) -> [InvestmentPricePoint] {
        resolveHistory(for: position, cutoff: nil, resolution: .intraday30m)
            .lastQuotedWindow()
    }

    /// Tries in order: ISIN → ticker → symbols kept by the last successful sync
    /// (e.g. an ISIN resolved to "PUST.PA" via OpenFIGI is stored under that
    /// symbol). The single source used by EVERY chart level (global, account,
    /// position, widget) — otherwise one level could stay empty while another
    /// shows data.
    static func resolveHistory(for position: InvestmentPosition, cutoff: Date?,
                               resolution: PriceResolution = .daily) -> [InvestmentPricePoint] {
        func load(_ identifier: String) -> [InvestmentPricePoint] {
            PriceHistoryCache.shared.fetch(identifier: identifier, resolution: resolution)
                .sorted { $0.date < $1.date }
                .filter { point in
                    guard let cutoff else { return true }
                    return point.date >= cutoff
                }
        }

        let candidates = [position.isin, position.ticker].filter { !$0.isEmpty }
        for candidate in candidates {
            let history = load(candidate)
            if !history.isEmpty { return history }
        }
        if let trace = InvestmentSyncTraceStore.fetchBest(identifiers: candidates),
           trace.status == .success {
            for symbol in trace.symbolsTried {
                let history = load(symbol)
                if !history.isEmpty { return history }
            }
        }
        return []
    }
}
