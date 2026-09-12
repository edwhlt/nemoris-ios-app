import Foundation

// MARK: - RecurringDetector
//
// Analyzes transaction history to automatically detect recurring
// expenses and income (subscriptions, rent, salary, etc.)
//
// A recurrence is only kept if ALL 4 of the following criteria are
// met (strict gates, not a score that lets a strong criterion
// compensate for a weak one):
//  1. Same payee            -> grouping is done by payee_id (or a
//                                normalized name otherwise), so it's structural.
//  2. Regular frequency     -> ALL consecutive gaps (not just
//                                the median) must fall within the
//                                window of a canonical frequency (weekly,
//                                biweekly, monthly, quarterly,
//                                semiannual, yearly).
//  3. Near-identical amount -> a relative standard deviation under a tight
//                                threshold (AMOUNT_TOLERANCE), not the old
//                                lax 50%.
//  4. Stable due date       -> the day of the month (or the day of the
//                                week) of each occurrence must stay close
//                                to the anchor (DATE_TOLERANCE_DAYS).
//
// If even one of these criteria fails, the whole group is rejected
// (returns nil): confidence is no longer "degraded", the candidate is refused
// outright. Remaining confidence only ranks valid candidates against each other.

struct DetectionCandidate: Identifiable {
    let name: String
    let payeeId: Int?
    let categoryId: Int?
    let amountAvg: Double
    let amountStdDev: Double
    let frequency: RecurrenceFrequency
    let anchorDay: Int?
    let occurrences: [Date]
    /// Amounts of the transactions behind the detection, same order and
    /// same index as `occurrences` — so each occurrence's detail can be
    /// shown (not just the aggregated average).
    let occurrenceAmounts: [Double]
    /// Confidence score 0…1 (ranking only, every returned candidate has
    /// already passed the strict gates above)
    let confidence: Double

    var id: String { name }

    /// A draft pattern pre-filled with the detected values, to let the
    /// user adjust it (amount, day, category…) before
    /// confirming — rather than only being able to accept it "as is".
    func asDraftPattern() -> RecurringPattern {
        RecurringPattern(
            id: 0, name: name, amountAvg: amountAvg, amountTolerance: 0.15,
            categoryId: categoryId, payeeId: payeeId, frequency: frequency,
            anchorDay: anchorDay, isActive: true, isManual: false,
            createdAt: Date(), lastDetectedAt: occurrences.last,
            startDate: occurrences.first ?? Date(), endDate: nil
        )
    }

    /// The existing pattern (active OR inactive) that already matches this
    /// candidate — the same identity rule as detection grouping
    /// (payee first, name otherwise). SINGLE source for this decision: used
    /// both to sort/gray out "Already tracked" in the panel and to
    /// keep a "Confirm" from creating a duplicate there.
    func existingMatch(in patterns: [RecurringPattern]) -> RecurringPattern? {
        if let pid = payeeId, let match = patterns.first(where: { $0.payeeId == pid }) {
            return match
        }
        return patterns.first { $0.name.lowercased() == name.lowercased() }
    }

    /// true if what was just detected (amount, frequency, anchor day)
    /// noticeably differs from the already-tracked pattern — signals a price
    /// that changed (a subscription, a membership fee) or a due date that
    /// drifted, which the existing pattern never caught up with (it's only
    /// re-evaluated at creation, never automatically afterward).
    func differsFrom(_ existing: RecurringPattern) -> Bool {
        let existingAmount = abs(existing.amountAvg)
        let detectedAmount = abs(amountAvg)
        let relativeDiff = existingAmount > 0 ? abs(detectedAmount - existingAmount) / existingAmount : 0
        if relativeDiff > 0.01 { return true }
        if frequency != existing.frequency { return true }
        if let a = anchorDay, let b = existing.anchorDay, a != b { return true }
        return false
    }

    /// Merges freshly detected values into an EXISTING pattern —
    /// to fix a recurring item whose price or due date has drifted, without
    /// losing its own configuration (category, payee, active/inactive,
    /// tolerance, period).
    func updating(_ existing: RecurringPattern) -> RecurringPattern {
        RecurringPattern(
            id: existing.id, name: existing.name, amountAvg: amountAvg,
            amountTolerance: existing.amountTolerance, categoryId: existing.categoryId,
            payeeId: existing.payeeId, frequency: frequency, anchorDay: anchorDay,
            isActive: existing.isActive, isManual: existing.isManual,
            createdAt: existing.createdAt, lastDetectedAt: occurrences.last,
            startDate: existing.startDate, endDate: existing.endDate
        )
    }
}

enum RecurringDetector {

    // MARK: - Tuning

    /// Maximum relative standard deviation tolerated between a group's amounts
    /// to consider them "the same price". 8% absorbs a subscription's
    /// rounding/variable VAT without letting through amounts that
    /// really do vary (an energy bill, groceries...).
    /// Not `private`: reused as-is by the detail UI to explain
    /// why a candidate was retained (the single source of the real threshold).
    static let amountTolerance = 0.08

    /// Minimum number of occurrences to claim a periodicity. With 2
    /// points there's only one gap: no way to check that it
    /// repeats. At least 3 are needed (2 consecutive gaps to compare).
    private static let minOccurrences = 3

    /// Tolerance de date, en jours, par famille de frequence — "date
    /// identique, a 1-2 jours pres" (weekend, jour ferie, traitement
    /// bancaire decale). Pas `private` : reutilise par l'UI de detail.
    static func dateTolerance(for frequency: RecurrenceFrequency) -> Int {
        switch frequency {
        case .daily:                          return 1
        case .weekly, .biweekly:              return 1
        case .monthly, .quarterly, .semiannual: return 2
        case .yearly:                         return 3
        }
    }

    /// [min, max] window in days a CONSECUTIVE gap must respect
    /// to belong to this frequency. Every gap in the group must fall
    /// within it — not just the median — otherwise the "frequency" is
    /// just a coincidence between two points. Not `private`: reused
    /// by the detail UI.
    static func gapWindow(for frequency: RecurrenceFrequency) -> ClosedRange<Int> {
        switch frequency {
        case .daily:      return 0...2
        case .weekly:     return 5...9
        case .biweekly:   return 11...17
        case .monthly:    return 25...36
        case .quarterly:  return 80...102
        case .semiannual: return 165...199
        case .yearly:     return 350...380
        }
    }

    /// Detection order: shortest to longest, to retain the
    /// finest frequency that explains ALL the gaps (a group whose
    /// gaps are all ~14 days should stay "biweekly", not drift toward
    /// a broader window that would also fit it).
    private static let candidateFrequencies: [RecurrenceFrequency] =
        [.daily, .weekly, .biweekly, .monthly, .quarterly, .semiannual, .yearly]

    // MARK: - Public API

    /// Detects recurring patterns in an array of transactions.
    /// - Parameter transactions: Every available transaction (no sort order required).
    /// - Returns: Candidates sorted by decreasing confidence.
    static func detect(from transactions: [FinanceTransaction]) -> [DetectionCandidate] {
        // Group by payee_id then by normalized name (the "same payee" criterion)
        let groups = groupTransactions(transactions)

        var candidates: [DetectionCandidate] = []
        for (_, txs) in groups {
            guard txs.count >= minOccurrences else { continue }

            // Sub-group by similar amount (same payee, close amounts = likely the same subscription)
            let subGroups = subGroupByAmount(txs)
            for subGroup in subGroups {
                guard subGroup.count >= minOccurrences else { continue }
                if let candidate = analyzeGroup(subGroup) {
                    candidates.append(candidate)
                }
            }
        }

        return candidates.sorted {
            if abs($0.confidence - $1.confidence) > 0.05 {
                return $0.confidence > $1.confidence
            }
            return abs($0.amountAvg) > abs($1.amountAvg)
        }
    }

    // MARK: - Sub-grouping by amount cluster
    //
    // Groups a payee's transactions by similar amount (the same
    // tolerance as the final criterion: no point clustering more broadly
    // than what the final gate will accept).

    private static func subGroupByAmount(_ txs: [FinanceTransaction]) -> [[FinanceTransaction]] {
        // Trier par montant absolu croissant
        let sorted = txs.sorted { abs($0.amount) < abs($1.amount) }
        var clusters: [[FinanceTransaction]] = []
        var current: [FinanceTransaction] = []

        for tx in sorted {
            if current.isEmpty {
                current.append(tx)
            } else {
                let clusterAvg = current.map { abs($0.amount) }.reduce(0, +) / Double(current.count)
                let diff = clusterAvg > 0 ? abs(abs(tx.amount) - clusterAvg) / clusterAvg : 1.0
                if diff < amountTolerance {
                    current.append(tx)
                } else {
                    clusters.append(current)
                    current = [tx]
                }
            }
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    // MARK: - Grouping

    private static func groupTransactions(_ transactions: [FinanceTransaction])
        -> [String: [FinanceTransaction]]
    {
        var result: [String: [FinanceTransaction]] = [:]
        for tx in transactions {
            let key: String
            if let pid = tx.tiersId {
                key = "payee_\(pid)"
            } else {
                key = "name_\(normalizedName(tx.tiersName))"
            }
            result[key, default: []].append(tx)
        }
        return result
    }

    // MARK: - Analysis

    private static func analyzeGroup(_ txs: [FinanceTransaction]) -> DetectionCandidate? {
        let sorted = txs.sorted { $0.date < $1.date }
        let dates = sorted.map(\.date)
        let amounts = sorted.map(\.amount)

        // --- Critere "prix identique" : porte stricte, pas de degrade ---
        let avgAmount = amounts.reduce(0, +) / Double(amounts.count)
        let stdDev = standardDeviation(amounts)
        let relativeStdDev = abs(avgAmount) > 0 ? stdDev / abs(avgAmount) : 1.0
        guard relativeStdDev <= amountTolerance else { return nil }

        // --- "Regular frequency" criterion: ALL consecutive gaps ---
        let gaps = zip(dates, dates.dropFirst()).map { earlier, later in
            Calendar.current.dateComponents([.day], from: earlier, to: later).day ?? 0
        }
        guard !gaps.isEmpty else { return nil }
        guard let frequency = matchingFrequency(forGaps: gaps) else { return nil }

        // --- Critere "date identique (+/- quelques jours)" ---
        guard let anchorDay = computeAnchorDay(dates: dates, frequency: frequency) else {
            // .daily n'a pas d'ancrage a verifier
            return finalizeCandidate(
                sorted: sorted, dates: dates, avgAmount: avgAmount, stdDev: stdDev,
                relativeStdDev: relativeStdDev, frequency: frequency, anchorDay: nil, gaps: gaps
            )
        }
        guard isDateConsistent(dates: dates, frequency: frequency, anchorDay: anchorDay) else { return nil }

        return finalizeCandidate(
            sorted: sorted, dates: dates, avgAmount: avgAmount, stdDev: stdDev,
            relativeStdDev: relativeStdDev, frequency: frequency, anchorDay: anchorDay, gaps: gaps
        )
    }

    private static func finalizeCandidate(
        sorted: [FinanceTransaction], dates: [Date], avgAmount: Double, stdDev: Double,
        relativeStdDev: Double, frequency: RecurrenceFrequency, anchorDay: Int?, gaps: [Int]
    ) -> DetectionCandidate {
        // Ranking score only (every hard criterion is already
        // validated at this point): rewards fine-grained regularity of the
        // gaps, amount precision, and the number of occurrences observed.
        let target = Double(frequency.approximateDays)
        let gapDeviation = gaps.map { abs(Double($0) - target) / target }.reduce(0, +) / Double(gaps.count)
        let freqScore = max(0, 1.0 - gapDeviation * 2)

        let amountScore = max(0, 1.0 - relativeStdDev / amountTolerance)

        let countBonus = min(Double(sorted.count - minOccurrences) * 0.04, 0.20)

        let confidence = min(freqScore * 0.40 + amountScore * 0.40 + countBonus + 0.10, 1.0)

        let first = sorted.first!
        return DetectionCandidate(
            name: first.tiersName.isEmpty ? "Inconnu" : first.tiersName,
            payeeId: first.tiersId,
            categoryId: first.categoryId,
            amountAvg: avgAmount,
            amountStdDev: stdDev,
            frequency: frequency,
            anchorDay: anchorDay,
            occurrences: dates,
            occurrenceAmounts: sorted.map(\.amount),
            confidence: confidence
        )
    }

    // MARK: - Frequency Matching

    /// Finds the finest canonical frequency whose tolerance window
    /// contains ALL of the group's consecutive gaps. Unlike
    /// the old version (median only), a group with even one gap
    /// outside the window is rejected: it isn't an "approximate
    /// frequency with noise", it's a pattern that isn't regular.
    private static func matchingFrequency(forGaps gaps: [Int]) -> RecurrenceFrequency? {
        for frequency in candidateFrequencies {
            let window = gapWindow(for: frequency)
            if gaps.allSatisfy({ window.contains($0) }) {
                return frequency
            }
        }
        return nil
    }

    // MARK: - Anchor Day

    private static func computeAnchorDay(dates: [Date], frequency: RecurrenceFrequency) -> Int? {
        let cal = Calendar.current
        if frequency.usesDayOfMonthAnchor {
            // Most frequent day of the month. End-of-month days
            // (28-31) are grouped together: "the 31st" and "the 28th (February)" are the
            // same "end of month" due date for a monthly-billed subscription.
            let days = dates.map { normalizedMonthDay(for: $0, calendar: cal) }
            return mostFrequent(days)
        }
        if frequency.usesWeekdayAnchor {
            // Most frequent ISO day of the week (1=Monday)
            let weekdays = dates.compactMap { cal.dateComponents([.weekday], from: $0).weekday }
            let isoWeekdays = weekdays.map { ($0 + 5) % 7 + 1 }
            return mostFrequent(isoWeekdays)
        }
        if frequency == .yearly {
            // Closest day of the year (1-366), to check the
            // month+day stability of a yearly due date.
            let doys = dates.compactMap { cal.ordinality(of: .day, in: .year, for: $0) }
            return mostFrequent(doys)
        }
        return nil // .daily : pas d'ancrage pertinent
    }

    /// Normalized day of the month: a day >= 28 is rounded to the last day of
    /// the month in question (28/29/30/31 depending on the month), so that "end
    /// of month" is a single category rather than 4 distinct values.
    private static func normalizedMonthDay(for date: Date, calendar: Calendar) -> Int {
        let day = calendar.component(.day, from: date)
        guard day >= 28, let range = calendar.range(of: .day, in: .month, for: date) else { return day }
        let lastDay = range.upperBound - 1
        return day >= lastDay - 2 ? 31 : day // "31" is used as a conventional code for "end of month"
    }

    // MARK: - Date Consistency ("date identique, a quelques jours pres")

    private static func isDateConsistent(dates: [Date], frequency: RecurrenceFrequency, anchorDay: Int) -> Bool {
        let cal = Calendar.current
        let tolerance = dateTolerance(for: frequency)

        if frequency.usesDayOfMonthAnchor {
            return dates.allSatisfy { date in
                let day = normalizedMonthDay(for: date, calendar: cal)
                // Simplified circular distance: the "end of month"
                // normalization (value 31) already makes a direct comparison reliable.
                return abs(day - anchorDay) <= tolerance
            }
        }
        if frequency.usesWeekdayAnchor {
            return dates.allSatisfy { date in
                let weekday = cal.dateComponents([.weekday], from: date).weekday ?? 1
                let iso = (weekday + 5) % 7 + 1
                let diff = abs(iso - anchorDay)
                let circular = min(diff, 7 - diff)
                return circular <= tolerance
            }
        }
        if frequency == .yearly {
            return dates.allSatisfy { date in
                guard let doy = cal.ordinality(of: .day, in: .year, for: date) else { return false }
                let diff = abs(doy - anchorDay)
                let circular = min(diff, 366 - diff) // jonction decembre -> janvier
                return circular <= tolerance
            }
        }
        return true // .daily
    }

    // MARK: - Prevision Generation

    /// Generates due dates between two dates for a recurring pattern.
    /// - Parameters:
    ///   - pattern: The pattern to project
    ///   - startDate: Start date (included)
    ///   - endDate: End date (included)
    /// - Returns: Every due date within the range
    static func generateOccurrences(
        for pattern: RecurringPattern,
        from startDate: Date,
        to endDate: Date
    ) -> [Date] {
        guard pattern.isActive, startDate <= endDate else { return [] }
        // Start one period before to catch occurrences right at startDate
        let beforeStart = Calendar.current.date(byAdding: .day, value: -1, to: startDate) ?? startDate
        var dates: [Date] = []
        var cursor = nextOccurrence(after: beforeStart, pattern: pattern)
        while let date = cursor, date <= endDate {
            if date >= startDate { dates.append(date) }
            cursor = nextOccurrence(after: date, pattern: pattern)
        }
        return dates
    }

    /// Generates future due dates from a recurring pattern.
    /// - Parameters:
    ///   - pattern: The pattern to project
    ///   - from: Start date of the projection
    ///   - months: Number of months to project forward
    /// - Returns: Dates of the upcoming due dates
    static func generateNextOccurrences(
        for pattern: RecurringPattern,
        from startDate: Date = Date(),
        months: Int = 3
    ) -> [Date] {
        guard pattern.isActive else { return [] }
        let end = Calendar.current.date(byAdding: .month, value: months, to: startDate) ?? startDate
        return generateOccurrences(for: pattern, from: startDate, to: end)
    }

    static func nextOccurrence(after date: Date, pattern: RecurringPattern) -> Date? {
        let cal = Calendar.current
        switch pattern.frequency {
        case .daily:
            return cal.date(byAdding: .day, value: 1, to: date)

        case .weekly, .biweekly:
            let step = pattern.frequency == .weekly ? 7 : 14
            if let anchor = pattern.anchorDay {
                // Find the next specified ISO day of the week
                var next = cal.date(byAdding: .day, value: 1, to: date)!
                for _ in 0..<8 {
                    let weekday = cal.dateComponents([.weekday], from: next).weekday ?? 1
                    let iso = (weekday + 5) % 7 + 1
                    if iso == anchor { return next }
                    next = cal.date(byAdding: .day, value: 1, to: next)!
                }
                return cal.date(byAdding: .day, value: step, to: date)
            }
            return cal.date(byAdding: .day, value: step, to: date)

        case .monthly, .quarterly, .semiannual:
            let day = pattern.anchorDay ?? 1
            let step = pattern.frequency.monthStep ?? 1
            var comps = cal.dateComponents([.year, .month], from: date)
            comps.month = (comps.month ?? 1) + step
            // "31" is the conventional "end of month" code (see normalizedMonthDay)
            comps.day = day >= 29 ? 31 : day
            // Handle short months (e.g. 31 -> 28 in February)
            if let candidate = cal.date(from: comps) {
                return candidate
            }
            // Fallback: last day of the target month
            comps.day = 1
            if let firstOfNext = cal.date(from: comps) {
                return cal.date(byAdding: .day, value: -1, to: firstOfNext)
            }
            return nil

        case .yearly:
            return cal.date(byAdding: .year, value: 1, to: date)
        }
    }

    // MARK: - Duplicate Matching

    /// Checks whether a real transaction matches a prevision.
    /// Uses a +/-3-day date window and the pattern's amount tolerance.
    static func matchTransaction(
        _ tx: FinanceTransaction,
        toPrevision prevision: BudgetPrevision,
        pattern: RecurringPattern
    ) -> Bool {
        // Amount check
        let txAmt = tx.amount
        let expectedAmt = prevision.amount
        let tolerance = abs(expectedAmt) * pattern.amountTolerance
        guard abs(txAmt - expectedAmt) <= tolerance else { return false }

        // Date check (+/-3 days)
        let daysDiff = abs(Calendar.current.dateComponents([.day], from: tx.date, to: prevision.expectedDate).day ?? 999)
        return daysDiff <= 3
    }

    // MARK: - Stats Helpers

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count - 1)
        return sqrt(variance)
    }

    private static func mostFrequent(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private static func normalizedName(_ name: String) -> String {
        // Remove purely numeric tokens (dates, references) and stray characters
        let cleaned = name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "*", with: " ")
            .replacingOccurrences(of: "/", with: " ")

        let tokens = cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .filter { token in
                // Exclude purely numeric tokens (e.g. "20251201", "75001")
                !token.allSatisfy({ $0.isNumber })
            }

        return tokens.prefix(4).joined(separator: "_")
    }
}
