import SwiftUI
import Charts

// MARK: - Investment chart components
//
// Reusable at the 3 depth levels: Global (dashboard), Account, Security.
// Strictly follow the Nemoris design language (AppTheme.Colors / AppTheme.Typography).
//
// Exported components:
//   - InvestmentTimeRange (enum)
//   - TimeRangeChips (horizontal chip picker)
//   - PortfolioEvolutionPoint (data model)
//   - InvestmentHeroCard (large valuation + variation %)
//   - EvolutionChart (smooth line + area gradient + drag-to-inspect)
//   - AllocationDonutChart (SectorMark donut + legend)
//   - InvestmentSparkline (mini line chart for account cards)

// MARK: - Time Range

/// X-axis configuration: stride unit (spacing between ticks) + date format for
/// the labels. Computed from the time range so labels stay readable without
/// overlapping.
struct InvestmentChartXAxisConfig {
    let strideUnit: Calendar.Component
    let strideCount: Int
    /// Label display format (e.g. "Jun 25", "2024", "12/05").
    let labelFormat: Date.FormatStyle

    static func config(for range: InvestmentTimeRange?, span: TimeInterval) -> InvestmentChartXAxisConfig {
        // span in seconds — used for `.all`, which has no startDate.
        let oneDay: TimeInterval = 86_400
        let oneMonth: TimeInterval = 30 * oneDay
        let oneYear: TimeInterval = 365 * oneDay

        // Determines the "real" displayed duration. For .all, the real span computed
        // from the chart's points is used.
        let effective: TimeInterval = {
            guard let range else { return span }
            switch range {
            case .oneDay:     return oneDay
            case .oneWeek:    return 7 * oneDay
            case .oneMonth:   return oneMonth
            case .threeMonth: return 3 * oneMonth
            case .sixMonth:   return 6 * oneMonth
            case .oneYear:    return oneYear
            case .fiveYear:   return 5 * oneYear
            case .tenYear:    return 10 * oneYear
            case .all:        return span
            }
        }()

        if effective <= 2 * oneDay {
            // 1 day: hourly ticks
            return .init(
                strideUnit: .hour, strideCount: 6,
                labelFormat: .dateTime.hour()
            )
        } else if effective <= 14 * oneDay {
            // 1-2 weeks: a tick every 2 days, "DD MMM" format
            return .init(
                strideUnit: .day, strideCount: 2,
                labelFormat: .dateTime.day().month(.abbreviated)
            )
        } else if effective <= 3 * oneMonth {
            // 1-3 mois : ticks hebdomadaires, format "JJ MMM"
            return .init(
                strideUnit: .weekOfYear, strideCount: 1,
                labelFormat: .dateTime.day().month(.abbreviated)
            )
        } else if effective <= oneYear {
            // 6m-1a : ticks mensuels, format "MMM"
            return .init(
                strideUnit: .month, strideCount: 1,
                labelFormat: .dateTime.month(.abbreviated)
            )
        } else if effective <= 3 * oneYear {
            // 1-3 years: a tick every 3 months, "MMM yy" format
            return .init(
                strideUnit: .month, strideCount: 3,
                labelFormat: .dateTime.month(.abbreviated).year(.twoDigits)
            )
        } else if effective <= 6 * oneYear {
            // 3-6 ans : ticks semestriels, format "MMM yy"
            return .init(
                strideUnit: .month, strideCount: 6,
                labelFormat: .dateTime.month(.abbreviated).year(.twoDigits)
            )
        } else {
            // > 6 ans (10A, Max) : ticks annuels, format "yyyy"
            return .init(
                strideUnit: .year, strideCount: 1,
                labelFormat: .dateTime.year()
            )
        }
    }
}

enum InvestmentTimeRange: String, CaseIterable, Identifiable {
    case oneDay     = "1J"
    case oneWeek    = "1S"
    case oneMonth   = "1M"
    case threeMonth = "3M"
    case sixMonth   = "6M"
    case oneYear    = "1A"
    case fiveYear   = "5A"
    case tenYear    = "10A"
    case all        = "Max"

    var id: String { rawValue }

    /// Abbreviation shown on the chip — independent of `rawValue` (internal
    /// identity only), so it can vary by language without touching comparisons or
    /// persistence that rely on the rawValue. `rawValue` always stays French
    /// (1J/1S/1M…) — `label` follows `AppLocalization.locale` for display.
    var label: String {
        let isEnglish = AppLocalization.locale.language.languageCode?.identifier == "en"
        guard isEnglish else { return rawValue }
        switch self {
        case .oneDay:     return "1D"
        case .oneWeek:    return "1W"
        case .oneMonth:   return "1M"
        case .threeMonth: return "3M"
        case .sixMonth:   return "6M"
        case .oneYear:    return "1Y"
        case .fiveYear:   return "5Y"
        case .tenYear:    return "10Y"
        case .all:        return "Max"
        }
    }

    /// Ranges that make sense given the oldest available date (account or
    /// portfolio creation). E.g. an account opened 3 months ago → 5Y/10Y removed
    /// (no data to show), 6M kept (equivalent to Max over that span). Avoids chips
    /// that open empty, hence misleading, charts.
    static func availableRanges(since earliestDate: Date) -> [InvestmentTimeRange] {
        let interval = Date().timeIntervalSince(earliestDate)
        let day: TimeInterval = 86_400
        return InvestmentTimeRange.allCases.filter { range in
            switch range {
            case .all:        return true
            case .oneDay:     return interval >= day
            case .oneWeek:    return interval >= 7 * day
            case .oneMonth:   return interval >= 25 * day  // tolerance: 1M from 25 days of history
            case .threeMonth: return interval >= 80 * day
            case .sixMonth:   return interval >= 150 * day
            case .oneYear:    return interval >= 300 * day
            case .fiveYear:   return interval >= 4 * 365 * day
            case .tenYear:    return interval >= 8 * 365 * day
            }
        }
    }

    /// Start date for the filter. `nil` = the whole history.
    var startDate: Date? {
        let cal = Calendar.current
        let now = Date()
        switch self {
        case .oneDay:     return cal.date(byAdding: .day,   value: -1,  to: now)
        case .oneWeek:    return cal.date(byAdding: .day,   value: -7,  to: now)
        case .oneMonth:   return cal.date(byAdding: .month, value: -1,  to: now)
        case .threeMonth: return cal.date(byAdding: .month, value: -3,  to: now)
        case .sixMonth:   return cal.date(byAdding: .month, value: -6,  to: now)
        case .oneYear:    return cal.date(byAdding: .year,  value: -1,  to: now)
        case .fiveYear:   return cal.date(byAdding: .year,  value: -5,  to: now)
        case .tenYear:    return cal.date(byAdding: .year,  value: -10, to: now)
        case .all:        return nil
        }
    }
}

// MARK: - Time Range Chips

/// Horizontal time range picker (Finary/Boursorama style).
/// Minimal chips with an accent on the selection.
struct TimeRangeChips: View {
    @Binding var selection: InvestmentTimeRange
    var ranges: [InvestmentTimeRange] = InvestmentTimeRange.allCases

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ranges) { range in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection = range
                    }
                } label: {
                    Text(LocalizedStringKey(range.label))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selection == range ? AppTheme.Colors.background : AppTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(selection == range ? AppTheme.Colors.accent : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Portfolio Evolution Point

/// Portfolio evolution point (at the global, account or position level).
/// `value` is the total valuation at that date (qty × close for the underlying positions).
struct PortfolioEvolutionPoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let value: Double
}

extension Array where Element == PortfolioEvolutionPoint {
    /// Sanitizes a series before handing it to Swift Charts.
    ///
    /// Prevents a "barcode" rendering: TWO POINTS ON THE SAME DAY draw a vertical
    /// segment in an area/line, and a series holding many of them renders as a
    /// comb of vertical bars. The symptom is intermittent, since duplicates only
    /// appear after a sync introduced a different timestamp for an already-known
    /// day.
    ///
    /// Guaranteed here: finite values, a single point per calendar day (the last
    /// known one wins), a series sorted by ascending date. No outlier rejection
    /// here: on an aggregated portfolio a sharp rise is legitimate (unlike a
    /// single security's price).
    func sanitizedForChart() -> [PortfolioEvolutionPoint] {
        let cal = Calendar.current
        var byDay: [Date: PortfolioEvolutionPoint] = [:]
        for p in self where p.value.isFinite {
            byDay[cal.startOfDay(for: p.date)] = p
        }
        return byDay.values.sorted { $0.date < $1.date }
    }
}

// MARK: - Chart Scrub Readout

/// A marker (value + optional date) shown in a chart's reading band. The date
/// is optional because some markers have no meaningful one (e.g. the average
/// cost, a weighted average over several orders).
struct ChartReadoutPoint: Equatable {
    let date: Date?
    let value: Double

    init(date: Date? = nil, value: Double) {
        self.date = date
        self.value = value
    }
}

/// Reading band shown BELOW the hero and ABOVE the chart.
///
/// It answers "how much is it worth where my finger is" without relying on a
/// floating annotation in the plot: an annotation stuck to the point gets
/// truncated as soon as the point is near the top or an edge of the chart,
/// making the values unreadable while scrubbing.
///
/// The band is ALWAYS rendered (never conditional on `isScrubbing`): no height
/// jump when the finger goes down/up, and the difference stays readable at
/// rest.
///
/// Two modes depending on `referenceLabel`:
///   - **nil** (aggregated global / account charts): a single highlighted
///     value, `reference` ONLY serves as the basis of the variation. Talking
///     about an entry and exit price makes no sense on a portfolio valuation —
///     positions come and go continuously.
///   - **non-nil** (position chart): two columns, typically the open and the
///     close of the pointed candle, which really are prices.
struct ChartScrubReadout: View {
    /// Basis of the variation. Shown as a column only when `referenceLabel` is set.
    let reference: ChartReadoutPoint?
    /// Highlighted value (point under the finger, or last point at rest).
    let current: ChartReadoutPoint?
    var currency: String = "EUR"
    var referenceLabel: LocalizedStringKey? = nil
    var currentLabel: LocalizedStringKey = "Valeur"
    /// Precision shown under the variation, e.g. "since the start of the range".
    var deltaCaption: LocalizedStringKey? = nil
    /// `true` while the user scrubs the curve: the current value is highlighted
    /// (accent) to signal that it's the one moving.
    var isScrubbing: Bool = false
    /// Adds the time to dates (intraday ranges: 1D).
    var showsTime: Bool = false

    private var delta: Double? {
        guard let reference, let current else { return nil }
        return current.value - reference.value
    }

    private var deltaPct: Double? {
        guard let reference, let current, reference.value != 0 else { return nil }
        return (current.value - reference.value) / abs(reference.value) * 100
    }

    private var isPositive: Bool { (delta ?? 0) >= 0 }

    private var deltaColor: Color {
        guard let delta else { return AppTheme.Colors.textSecondary }
        return delta >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.sm) {
            if let referenceLabel, let reference {
                pointColumn(label: referenceLabel, point: reference, emphasized: false)

                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    .padding(.top, 14)
            }

            if let current {
                pointColumn(label: currentLabel, point: current, emphasized: isScrubbing)
            }

            Spacer(minLength: 0)

            if let delta, let deltaPct {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 10, weight: .bold))
                        MoneyText(
                            amount: delta,
                            currency: currency,
                            font: .system(size: 13, weight: .semibold),
                            color: deltaColor,
                            maskedPlaceholder: "••• €"
                        )
                    }
                    .foregroundStyle(deltaColor)

                    Text(String(format: "%@%.2f %%", isPositive ? "+" : "", deltaPct))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(deltaColor)

                    if let deltaCaption {
                        Text(deltaCaption)
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(deltaColor.opacity(0.12))
                )
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isScrubbing)
        // Fixed minimum height: the date column can disappear (a marker without a
        // date, e.g. the average cost) — without this floor the chart would jump up
        // a few points on the first scrub.
        .frame(minHeight: 44, alignment: .top)
    }

    @ViewBuilder
    private func pointColumn(label: LocalizedStringKey, point: ChartReadoutPoint, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(emphasized ? AppTheme.Colors.accent : AppTheme.Colors.textSecondary)
            MoneyText(
                amount: point.value,
                currency: currency,
                font: .system(size: 15, weight: .semibold),
                color: AppTheme.Colors.textPrimary,
                maskedPlaceholder: "••• €"
            )
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if let date = point.date {
                dateLabel(date)
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func dateLabel(_ date: Date) -> Text {
        if showsTime {
            return Text(date, format: .dateTime.day().month(.abbreviated).hour().minute())
        }
        return Text(date, format: .dateTime.day().month(.abbreviated).year(.twoDigits))
    }
}

// MARK: - Investment Hero Card

/// "Hero" card at the top of an investments screen (Global or Account level).
/// Shows the valuation very large + absolute variation + variation % over the selected range.
struct InvestmentHeroCard: View {
    let title: LocalizedStringResource
    let currentValue: Double
    let previousValue: Double?
    let currency: String
    /// When provided, label shown next to the %, e.g. "over 1 month"
    var rangeLabel: LocalizedStringResource? = nil
    /// Value to use AS THE BASIS of the variation computation, distinct from the
    /// display `currentValue`. Required when `currentValue` includes cash (which
    /// would artificially inflate the performance) — pass the positions' value
    /// alone here, so the variation is consistent with `previousValue` (positions
    /// only too). If nil, falls back to `currentValue`.
    var variationBasisValue: Double? = nil

    private var basisForVariation: Double { variationBasisValue ?? currentValue }

    private var variationAbs: Double? {
        guard let prev = previousValue else { return nil }
        return basisForVariation - prev
    }

    private var variationPct: Double? {
        guard let prev = previousValue, prev != 0 else { return nil }
        return (basisForVariation - prev) / prev * 100
    }

    private var isPositive: Bool {
        (variationAbs ?? 0) >= 0
    }

    private var variationColor: Color {
        guard let v = variationAbs else { return AppTheme.Colors.textSecondary }
        return v >= 0 ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Label discret (plus de capitales criardes — style Apple Stocks)
            Text(title)
                .font(AppTheme.Typography.labelMedium)
                .foregroundStyle(AppTheme.Colors.textSecondary)

            // Very large value — goes through MoneyText to honor global masking
            MoneyText(
                amount: currentValue,
                currency: currency,
                font: AppTheme.Typography.moneyLarge,
                color: AppTheme.Colors.textPrimary,
                maskedPlaceholder: "•• ••• €",
                presentation: .standard
            )
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            // Variation: tinted capsule pill (green/red) + range label next to it.
            if let abs = variationAbs, let pct = variationPct {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: isPositive ? "arrow.up.right" : "arrow.down.right")
                            .font(.system(size: 11, weight: .bold))
                        Text(abs, format: .currency(code: currency))
                            .font(.system(size: 14, weight: .semibold))
                        Text(String(format: "%@%.2f %%", isPositive ? "+" : "", pct))
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(variationColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(variationColor.opacity(0.12))
                    )

                    if let rangeLabel {
                        Text(rangeLabel)
                            .font(.system(size: 13))
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Evolution Chart

/// Value evolution chart (portfolio / account / position).
/// Smooth line + area gradient underneath + drag interaction to inspect a precise point.
struct EvolutionChart: View {
    let points: [PortfolioEvolutionPoint]
    var height: CGFloat = 200
    /// When provided, callback notified while the user drags to inspect a point.
    var onSelectPoint: ((PortfolioEvolutionPoint?) -> Void)? = nil
    /// Time range, to adapt the X-axis label granularity.
    /// nil = computed from the points (used for charts without chips).
    var timeRange: InvestmentTimeRange? = nil
    /// Currency of the reading band's amounts.
    var currency: String = "EUR"
    /// Entry/exit + variation band above the chart. Disable it for a purely
    /// decorative chart.
    var showsReadout: Bool = true

    @State private var selectedDate: Date? = nil

    /// Series actually drawn: sanitized (one point per day, finite values,
    /// sorted). Anti-"barcode" guard — see `sanitizedForChart()`. ALL rendering
    /// must go through here, never through raw `points`.
    private var cleanPoints: [PortfolioEvolutionPoint] { points.sanitizedForChart() }

    /// Real time span covered by the points (fallback when timeRange == nil).
    private var pointsSpan: TimeInterval {
        guard let first = cleanPoints.first?.date, let last = cleanPoints.last?.date else { return 0 }
        return max(0, last.timeIntervalSince(first))
    }

    /// X-axis configuration adapted to the time range.
    private var xAxisConfig: InvestmentChartXAxisConfig {
        InvestmentChartXAxisConfig.config(for: timeRange, span: pointsSpan)
    }

    /// Dynamic color: green if the trend over the range is up, red otherwise.
    private var trendColor: Color {
        guard let first = cleanPoints.first?.value, let last = cleanPoints.last?.value else {
            return AppTheme.Colors.accent
        }
        return last >= first ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    private var selectedPoint: PortfolioEvolutionPoint? {
        guard let selectedDate else { return nil }
        return cleanPoints.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    /// Y domain with visual padding so the curve doesn't touch the edges.
    /// Recomputed from the displayed range's points ONLY: changing the range must
    /// rebalance the y-axis, not just the x-axis.
    private var yDomain: ClosedRange<Double> {
        ChartYDomain.compute(values: cleanPoints.map(\.value))
    }

    /// The points' real minimum (not the yDomain minimum, which includes visual
    /// padding). Used as the AreaMark's yStart so the fill stops at the lowest
    /// point instead of reaching down to the x-axis.
    private var minValue: Double {
        cleanPoints.map(\.value).min() ?? 0
    }

    /// Variation basis = first point of the displayed range. Never shown as a
    /// column: an aggregated valuation (portfolio, account) has no "entry price"
    /// — positions come and go continuously. It only quantifies the rise or fall
    /// over the range.
    private var readoutReference: ChartReadoutPoint? {
        cleanPoints.first.map { ChartReadoutPoint(date: $0.date, value: $0.value) }
    }

    /// Highlighted value = the point under the finger while scrubbing, otherwise
    /// the range's last point.
    private var readoutCurrent: ChartReadoutPoint? {
        let point = selectedPoint ?? cleanPoints.last
        return point.map { ChartReadoutPoint(date: $0.date, value: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if showsReadout && !cleanPoints.isEmpty {
                ChartScrubReadout(
                    reference: readoutReference,
                    current: readoutCurrent,
                    currency: currency,
                    currentLabel: selectedDate != nil ? "Valeur pointée" : "Dernière valeur",
                    deltaCaption: "sur la plage",
                    isScrubbing: selectedDate != nil,
                    showsTime: timeRange == .oneDay
                )
            }
            chartBody
        }
    }

    @ViewBuilder
    private var chartBody: some View {
        if cleanPoints.isEmpty {
            // Understated placeholder — not a heavy EmptyStateView
            VStack(spacing: 8) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.4))
                Text("Aucun historique disponible")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: height)
        } else {
            Chart {
                ForEach(cleanPoints) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Valeur", point.value)
                    )
                    .foregroundStyle(trendColor)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))

                    // yStart set to the real lowest point (not yDomain.lowerBound, which includes
                    // the bottom visual padding) → the fill stops at the curve's minimum instead
                    // of touching the x-axis.
                    AreaMark(
                        x: .value("Date", point.date),
                        yStart: .value("Min", minValue),
                        yEnd: .value("Valeur", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [trendColor.opacity(0.25), trendColor.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                }

                // Selection marker: vertical rule + point on the curve.
                // No floating annotation here: stuck to the point, it gets truncated as soon
                // as the point nears the top or an edge of the plot. The figures are read in
                // `ChartScrubReadout`, above the chart.
                if let selectedPoint {
                    RuleMark(x: .value("Sélection", selectedPoint.date))
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    PointMark(
                        x: .value("Date", selectedPoint.date),
                        y: .value("Valeur", selectedPoint.value)
                    )
                    .foregroundStyle(trendColor)
                    .symbolSize(90)
                }
            }
            .chartYScale(domain: yDomain)
            .chartXAxis {
                // Adaptive ticks + label format depending on the time range (1D → hours,
                // 10Y → years) via `InvestmentChartXAxisConfig`. Without it, Swift Charts
                // picks an automatic format without the year, which makes a multi-year "Max"
                // unreadable.
                // Capped at ~5 ticks: `.stride` produces dozens on long ranges (overlapping
                // labels + the chart's intrinsic width blowing up → a horizontally
                // scrollable view).
                AxisMarks(position: .bottom, values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: xAxisConfig.labelFormat)
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                        .font(.system(size: 10))
                }
            }
            // Apple Stocks style: no Y grid, just 2-3 discreet value markers on the
            // right. The chart breathes, the line is the star.
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel()
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                        .font(.system(size: 10))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        // .gesture with minimumDistance > 0 + direction detection → lets the parent
                        // ScrollView handle vertical drags (scrolling) without intercepting them. A
                        // minimumDistance of 0 would capture every touch and move the page while
                        // scrubbing.
                        .gesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { value in
                                    let dx = abs(value.translation.width)
                                    let dy = abs(value.translation.height)
                                    // Vertically dominant drag → it's a scroll, not intercepted
                                    guard dx > dy else {
                                        if selectedDate != nil {
                                            selectedDate = nil
                                            onSelectPoint?(nil)
                                        }
                                        return
                                    }
                                    guard let plotFrame = proxy.plotFrame else { return }
                                    let origin = geo[plotFrame].origin
                                    let locationX = value.location.x - origin.x
                                    if let date: Date = proxy.value(atX: locationX) {
                                        let previous = selectedPoint?.date
                                        selectedDate = date
                                        // Discreet tick on each point change (not on each pixel) — a tactile cue
                                        // while reading the figures above.
                                        if selectedPoint?.date != previous {
                                            HapticService.shared.selection()
                                        }
                                        onSelectPoint?(selectedPoint)
                                    }
                                }
                                .onEnded { _ in
                                    selectedDate = nil
                                    onSelectPoint?(nil)
                                }
                        )
                }
            }
            .frame(height: height)
        }
    }
}

// MARK: - Allocation Donut Chart

/// Allocation item for the donut chart (name + value + stable color).
struct AllocationSlice: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let value: Double
}

/// Allocation donut chart (by asset type or by account) + legend.
/// Colors derived from the accent palette + variants.
struct AllocationDonutChart: View {
    let slices: [AllocationSlice]
    var currency: String = "EUR"
    var size: CGFloat = 180

    /// Stable palette: primary green accent + variations + brown accentSecondary.
    /// Cycles through for > 6 categories.
    private static let palette: [Color] = [
        AppTheme.Colors.accent,
        AppTheme.Colors.accentSecondary,
        AppTheme.Colors.success,
        AppTheme.Colors.warning,
        Color(hex: "6B9D85"),  // vert plus clair
        Color(hex: "8E5A3B"),  // brun plus clair
        Color(hex: "9A8866"),  // beige
    ]

    private var total: Double { slices.reduce(0) { $0 + $1.value } }

    private func color(for index: Int) -> Color {
        Self.palette[index % Self.palette.count]
    }

    private func percentage(of value: Double) -> Double {
        guard total > 0 else { return 0 }
        return value / total * 100
    }

    var body: some View {
        HStack(spacing: 20) {
            // Donut chart
            Chart {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    SectorMark(
                        angle: .value("Valeur", slice.value),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5
                    )
                    .cornerRadius(2)
                    .foregroundStyle(color(for: index))
                }
            }
            .frame(width: size, height: size)
            .overlay {
                // Total at the center of the donut
                VStack(spacing: 2) {
                    Text("TOTAL")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .tracking(0.5)
                    Text(total, format: .currency(code: currency))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 8)
            }

            // Vertical legend
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: index))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(slice.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                                .lineLimit(1)
                            Text(String(format: "%.1f %%", percentage(of: slice.value)))
                                .font(.system(size: 11))
                                .foregroundStyle(AppTheme.Colors.textSecondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Investment Sparkline

/// Mini line chart for account cards or a position row.
/// No label, no axes — just a line with a trend color.
struct InvestmentSparkline: View {
    let points: [PortfolioEvolutionPoint]
    var height: CGFloat = 32
    var width: CGFloat = 80

    /// Same guard as `EvolutionChart`: sanitized series (one point per day).
    private var cleanPoints: [PortfolioEvolutionPoint] { points.sanitizedForChart() }

    private var trendColor: Color {
        guard let first = cleanPoints.first?.value, let last = cleanPoints.last?.value else {
            return AppTheme.Colors.textSecondary
        }
        return last >= first ? AppTheme.Colors.success : AppTheme.Colors.danger
    }

    var body: some View {
        if cleanPoints.count < 2 {
            // Not enough data → discreet placeholder
            RoundedRectangle(cornerRadius: 2)
                .fill(AppTheme.Colors.textSecondary.opacity(0.1))
                .frame(width: width, height: height)
        } else {
            Chart {
                ForEach(cleanPoints) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Valeur", point.value)
                    )
                    .foregroundStyle(trendColor)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in
                plot.background(.clear)
            }
            .frame(width: width, height: height)
        }
    }
}
