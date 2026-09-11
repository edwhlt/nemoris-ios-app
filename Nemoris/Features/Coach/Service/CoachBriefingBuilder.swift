import Foundation

// MARK: - CoachBriefingBuilder — the "spending" briefing
//
// PURE engine (`import Foundation` only): no database, no network, no AI, no
// SwiftUI. Same doctrine as `PortfolioEvolutionBuilder`.
//
// ─── Why a briefing rather than the raw transactions ───────────────────────
//
// Six months of history is commonly 1,000 to 5,000 transactions. Sending
// them as-is is 100,000+ tokens: impossible on Foundation Models (~4,000 of
// context), slow and costly elsewhere. A coach that "interprets every
// transaction" therefore cannot READ them all.
//
// What it gets instead is a BRIEFING: the same facts, aggregated and
// ordered, in ~3,000 characters. It's the work a human consultant would do
// before giving an opinion — they don't read the 5,000 lines, they look at
// averages, trends, concentrations and anomalies.
//
// The briefing is BOUNDED (`maxCharacters`). Without a ceiling, a user with
// 200 categories or 900 merchants would blow the context and the model would
// truncate SILENTLY — losing precisely the end of the briefing, which is
// where the user's own goals sit.
//
// The briefing text itself stays in French: it is the content handed to a
// model asked to answer the user in their own language.

enum CoachBriefingBuilder {

    // MARK: - Input

    struct Input {
        var transactions: [FinanceTransaction]
        var categories: [Category]
        var tiers: [Tiers]
        var patterns: [RecurringPattern]
        var envelopes: [BudgetEnvelope]
        /// Signals already spotted by statistical detection
        /// (`InsightEngine`), one line each. They don't replace the model's
        /// analysis: they spare it re-deriving what a deterministic
        /// computation already knows, and give it entry points.
        var signals: [String]
        var objectives: String
        var now: Date

        init(transactions: [FinanceTransaction], categories: [Category], tiers: [Tiers],
             patterns: [RecurringPattern], envelopes: [BudgetEnvelope],
             signals: [String], objectives: String, now: Date = Date()) {
            self.transactions = transactions
            self.categories = categories
            self.tiers = tiers
            self.patterns = patterns
            self.envelopes = envelopes
            self.signals = signals
            self.objectives = objectives
            self.now = now
        }
    }

    // MARK: - Settings

    /// List ceilings. Calibrated to fit within `maxCharacters` without
    /// losing signal: past the 12th spending category or the 15th merchant,
    /// the amounts become anecdotal next to the leading ones.
    static let maxCategories = 12
    static let maxMerchants = 15
    static let maxRecurring = 20
    static let maxSignals = 8
    /// The monthly detail and the envelopes are the two lists that most
    /// easily grow unbounded. On a long history or a finely split budget they
    /// push the briefing past `maxCharacters` — and then TRUNCATION decides
    /// what reaches the model, by cutting the end. An explicit ceiling keeps
    /// control over what gets sacrificed.
    static let maxMonths = 24
    static let maxEnvelopes = 20
    /// Hard bound on the briefing in `.compact` mode: ~6,000 characters ≈
    /// 1,600 tokens.
    ///
    /// This is NOT comfortable headroom on a 4,000-token context model: with
    /// ~700 tokens of instructions, ~1,700 tokens remain for the answer.
    /// That's workable, but it's precisely what can CUT the response
    /// mid-JSON on a maximal briefing — hence the salvage fallback in
    /// `CoachResponseParser`.
    static let maxCharacters = 6_000
    /// Briefing bound in `.generous` mode (local server / cloud): those
    /// backends' context comfortably takes a briefing 3-4× richer — for most
    /// users the briefing doesn't even reach it. The LIST ceilings above do
    /// NOT move with it: past the 12th category or the 24th month, the signal
    /// is anecdotal regardless of which model reads it.
    static let maxCharactersGenerous = 20_000

    // MARK: - Assembly

    /// The briefing split into NAMED blocks.
    ///
    /// Same material as `build`, but addressable: on a narrow context window,
    /// `CoachPassPlanner` spreads these sections across several calls instead
    /// of sending everything at once (and being truncated wherever chance
    /// decides).
    static func sections(_ input: Input) -> [CoachBriefingSection] {
        var out: [CoachBriefingSection] = [
            CoachBriefingSection(id: "profil", title: "Profil et flux mensuels", body: profileBlock(input)),
            CoachBriefingSection(id: "categories", title: "Dépenses par catégorie", body: categoryBlock(input)),
        ]
        if let recurring = recurringBlock(input) {
            out.append(CoachBriefingSection(id: "recurrents", title: "Charges récurrentes", body: recurring))
        }
        if let merchants = merchantBlock(input) {
            out.append(CoachBriefingSection(id: "marchands", title: "Principaux marchands", body: merchants))
        }
        if let envelopes = envelopeBlock(input) {
            out.append(CoachBriefingSection(id: "enveloppes", title: "Enveloppes budgétaires", body: envelopes))
        }
        if let signals = signalBlock(input) {
            out.append(CoachBriefingSection(id: "signaux", title: "Signaux repérés automatiquement", body: signals))
        }
        return out
    }

    /// The key figures in a few lines, REPEATED in every pass of a split
    /// analysis.
    ///
    /// Without them, a pass that only sees "the merchants" has no idea of the
    /// income level and advises in a vacuum ("cut back on Grab" without
    /// knowing whether €417 weighs anything). The cost — ~250 characters per
    /// pass — is the price of relevance.
    static func condensedHeader(_ input: Input) -> String {
        let months = monthlyTotals(input)
        guard !months.isEmpty else { return "CHIFFRES CLÉS\nAucune transaction sur la période analysée." }
        let avgIncome = months.map(\.income).reduce(0, +) / Double(months.count)
        let avgExpense = months.map(\.expense).reduce(0, +) / Double(months.count)
        let savings = avgIncome - avgExpense
        let rate = avgIncome > 0 ? savings / avgIncome * 100 : 0
        return """
        CHIFFRES CLÉS (\(months.count) mois : \(months.first?.label ?? "?") → \(months.last?.label ?? "?"))
        Revenus moyens : \(money(avgIncome))/mois · Dépenses moyennes : \(money(avgExpense))/mois
        Épargne moyenne : \(money(savings))/mois, soit \(percent(rate)) du revenu
        """
    }

    static func build(_ input: Input, budget: CoachContextBudget = .compact) -> String {
        var text = sections(input).map(\.body).joined(separator: "\n\n")
        let limit = budget == .compact ? maxCharacters : maxCharactersGenerous
        // Goals are appended AFTER the rest is truncated: they are what the
        // user wrote themselves, and must never be the part sacrificed when
        // the briefing runs long.
        if text.count > limit {
            text = String(text.prefix(limit)) + "\n[…dossier tronqué]"
        }
        if let objectives = objectivesBlock(input) {
            text += "\n\n" + objectives
        }
        return text
    }

    // MARK: - Profile

    private static func profileBlock(_ input: Input) -> String {
        let months = monthlyTotals(input)
        guard !months.isEmpty else {
            return "PROFIL\nAucune transaction sur la période analysée."
        }
        let incomes = months.map(\.income)
        let expenses = months.map(\.expense)
        let avgIncome = incomes.reduce(0, +) / Double(months.count)
        let avgExpense = expenses.reduce(0, +) / Double(months.count)
        let savings = avgIncome - avgExpense
        let rate = avgIncome > 0 ? savings / avgIncome * 100 : 0

        // The savings rate month by month: an average of 12% can hide
        // "+30% then -6%", which calls for entirely different advice.
        let monthlyRates = months.map { $0.income > 0 ? ($0.income - $0.expense) / $0.income * 100 : 0 }
        let minRate = monthlyRates.min() ?? 0
        let maxRate = monthlyRates.max() ?? 0

        var lines = ["PROFIL"]
        lines.append("Période analysée : \(months.count) mois (\(months.first?.label ?? "?") → \(months.last?.label ?? "?"))")
        lines.append("Transactions : \(input.transactions.count)")
        lines.append("Revenus moyens : \(money(avgIncome))/mois")
        lines.append("Dépenses moyennes : \(money(avgExpense))/mois")
        lines.append("Épargne moyenne : \(money(savings))/mois, soit \(percent(rate)) du revenu")
        lines.append("Taux d'épargne mensuel — le plus bas \(percent(minRate)), le plus haut \(percent(maxRate))")
        lines.append("")
        lines.append("Détail mensuel (revenus / dépenses / solde) :")
        // The most RECENT months: it's the current situation that calls for
        // advice, not the one from three years ago.
        for m in months.suffix(maxMonths) {
            lines.append("  \(m.label) : \(money(m.income)) / \(money(m.expense)) / \(money(m.income - m.expense))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Categories

    private static func categoryBlock(_ input: Input) -> String {
        let cal = calendar
        guard let midpoint = cal.date(byAdding: .month, value: -3, to: input.now) else {
            return "DÉPENSES PAR CATÉGORIE\n(indisponible)"
        }
        let parentOf = parentIndex(input.categories)
        let nameOf = Dictionary(uniqueKeysWithValues: input.categories.map { ($0.id, $0.name) })

        var total: [Int: Double] = [:]      // over the whole period
        var recent: [Int: Double] = [:]     // last 3 months
        var previous: [Int: Double] = [:]   // the 3 before those
        var uncategorized: Double = 0

        for tx in input.transactions where tx.amount < 0 {
            let amount = abs(tx.amount)
            guard let cid = tx.categoryId else { uncategorized += amount; continue }
            let root = rootCategory(cid, parentOf: parentOf)
            total[root, default: 0] += amount
            if tx.date >= midpoint { recent[root, default: 0] += amount }
            else { previous[root, default: 0] += amount }
        }

        let grandTotal = total.values.reduce(0, +) + uncategorized
        guard grandTotal > 0 else { return "DÉPENSES PAR CATÉGORIE\nAucune dépense sur la période." }

        let monthCount = max(1, monthlyTotals(input).count)
        var lines = ["DÉPENSES PAR CATÉGORIE (moyenne mensuelle · part du total · tendance 3 derniers mois vs 3 précédents)"]
        for (cid, amount) in total.sorted(by: { $0.value > $1.value }).prefix(maxCategories) {
            let name = nameOf[cid] ?? "Catégorie \(cid)"
            let monthly = amount / Double(monthCount)
            let share = amount / grandTotal * 100
            lines.append("  \(name) : \(money(monthly))/mois · \(percent(share)) · \(trendLabel(recent: recent[cid] ?? 0, previous: previous[cid] ?? 0))")
        }
        if uncategorized > 0 {
            let share = uncategorized / grandTotal * 100
            lines.append("  NON CATÉGORISÉ : \(money(uncategorized / Double(monthCount)))/mois · \(percent(share))")
        }
        return lines.joined(separator: "\n")
    }

    /// Trend in plain words rather than a raw percentage: "+18%" on a €4
    /// base means nothing, and the model can't know that without the base.
    /// So only what is significant in amount gets qualified.
    private static func trendLabel(recent: Double, previous: Double) -> String {
        guard previous > 30 || recent > 30 else { return "volume faible" }
        guard previous > 0 else { return "nouveau poste" }
        let delta = (recent - previous) / previous * 100
        if delta > 15 { return "en hausse de \(percent(delta))" }
        if delta < -15 { return "en baisse de \(percent(abs(delta)))" }
        return "stable"
    }

    // MARK: - Recurring charges

    private static func recurringBlock(_ input: Input) -> String? {
        let expenses = input.patterns.filter { $0.isActive && $0.isExpense }
        guard !expenses.isEmpty else { return nil }
        let monthlyTotal = expenses.reduce(0.0) { $0 + monthlyEquivalent($1) }
        var lines = ["CHARGES RÉCURRENTES SUIVIES (\(expenses.count), soit \(money(monthlyTotal))/mois au total)"]
        for p in expenses.sorted(by: { monthlyEquivalent($0) > monthlyEquivalent($1) }).prefix(maxRecurring) {
            lines.append("  \(p.name) : \(money(p.displayAmount)) \(p.frequency.label.lowercased()) (\(money(monthlyEquivalent(p)))/mois)")
        }
        return lines.joined(separator: "\n")
    }

    private static func monthlyEquivalent(_ p: RecurringPattern) -> Double {
        let amount = abs(p.amountAvg)
        switch p.frequency {
        case .daily:      return amount * 30.42
        case .weekly:     return amount * 4.33
        case .biweekly:   return amount * 2.17
        case .monthly:    return amount
        case .quarterly:  return amount / 3
        case .semiannual: return amount / 6
        case .yearly:     return amount / 12
        }
    }

    // MARK: - Merchants

    private static func merchantBlock(_ input: Input) -> String? {
        var byTier: [Int: (count: Int, total: Double)] = [:]
        for tx in input.transactions where tx.amount < 0 {
            guard let tid = tx.tiersId else { continue }
            var entry = byTier[tid] ?? (0, 0)
            entry.count += 1
            entry.total += abs(tx.amount)
            byTier[tid] = entry
        }
        guard !byTier.isEmpty else { return nil }
        let nameOf = Dictionary(uniqueKeysWithValues: input.tiers.map { ($0.id, $0.name) })
        var lines = ["PRINCIPAUX MARCHANDS SUR LA PÉRIODE (nombre d'achats · total · panier moyen)"]
        for (tid, entry) in byTier.sorted(by: { $0.value.total > $1.value.total }).prefix(maxMerchants) {
            let name = nameOf[tid] ?? "Tiers \(tid)"
            let avg = entry.total / Double(max(1, entry.count))
            lines.append("  \(name) : \(entry.count) achats · \(money(entry.total)) · \(money(avg)) en moyenne")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Envelopes

    private static func envelopeBlock(_ input: Input) -> String? {
        let active = input.envelopes.filter { $0.isActive }
        guard !active.isEmpty else { return nil }
        let progresses = EnvelopeSpendingCalculator.progresses(
            envelopes: active,
            transactions: currentMonthTransactions(input),
            categories: input.categories
        )
        guard !progresses.isEmpty else { return nil }
        var lines = ["ENVELOPPES BUDGÉTAIRES DU MOIS EN COURS (alloué · dépensé · état)"]
        // Sorted by decreasing pressure, so the ceiling cuts the most
        // comfortable envelopes — precisely the ones with nothing to say
        // about them.
        for p in progresses.sorted(by: { $0.rawRatio > $1.rawRatio }).prefix(maxEnvelopes) {
            let state: String
            switch p.healthState {
            case .exceeded: state = "DÉPASSÉE"
            case .warning:  state = "proche de la limite"
            case .healthy:  state = "dans le budget"
            }
            lines.append("  \(p.envelope.name) : \(money(p.allocated)) · \(money(p.spent)) · \(state)")
        }
        return lines.joined(separator: "\n")
    }

    private static func currentMonthTransactions(_ input: Input) -> [FinanceTransaction] {
        let cal = calendar
        let comps = cal.dateComponents([.year, .month], from: input.now)
        guard let start = cal.date(from: comps) else { return [] }
        return input.transactions.filter { $0.date >= start && $0.date <= input.now }
    }

    // MARK: - Signals & goals

    private static func signalBlock(_ input: Input) -> String? {
        let signals = input.signals.filter { !$0.isEmpty }
        guard !signals.isEmpty else { return nil }
        var lines = ["SIGNAUX REPÉRÉS AUTOMATIQUEMENT (détection statistique — à confirmer ou nuancer)"]
        for s in signals.prefix(maxSignals) { lines.append("  - \(s)") }
        return lines.joined(separator: "\n")
    }

    /// Internal (not private): pass splitting repeats it in EVERY pass —
    /// goals are the coach's top priority, and a pass that couldn't see them
    /// would advise beside the point.
    static func objectivesBlock(_ input: Input) -> String? {
        let trimmed = input.objectives.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Bounded too: a user can paste three pages.
        let capped = trimmed.count > 1_500 ? String(trimmed.prefix(1_500)) + "…" : trimmed
        return "OBJECTIFS ÉCRITS PAR L'UTILISATEUR (à prendre comme la priorité n°1)\n\(capped)"
    }

    // MARK: - Monthly aggregation

    struct MonthTotals {
        let label: String
        let income: Double
        let expense: Double
    }

    /// Totals per calendar month, in chronological order.
    static func monthlyTotals(_ input: Input) -> [MonthTotals] {
        let cal = calendar
        var buckets: [DateComponents: (income: Double, expense: Double)] = [:]
        for tx in input.transactions {
            let comps = cal.dateComponents([.year, .month], from: tx.date)
            var entry = buckets[comps] ?? (0, 0)
            if tx.amount >= 0 { entry.income += tx.amount } else { entry.expense += abs(tx.amount) }
            buckets[comps] = entry
        }
        return buckets
            .sorted { ($0.key.year ?? 0, $0.key.month ?? 0) < ($1.key.year ?? 0, $1.key.month ?? 0) }
            .map { key, value in
                MonthTotals(label: String(format: "%04d-%02d", key.year ?? 0, key.month ?? 0),
                            income: value.income, expense: value.expense)
            }
    }

    // MARK: - Helpers

    /// Explicit Gregorian calendar: a pure engine must not depend on the
    /// device's regional settings to split months.
    private static var calendar: Calendar { Calendar(identifier: .gregorian) }

    /// Walks up the parent chain to the root category. Aggregating at root
    /// level avoids a briefing saturated with €4 subcategories that would
    /// drown the real ones.
    private static func rootCategory(_ id: Int, parentOf: [Int: Int]) -> Int {
        var current = id
        // Safety bound: a corrupted hierarchy (a cycle) must not spin the
        // engine forever.
        for _ in 0..<10 {
            guard let parent = parentOf[current] else { return current }
            current = parent
        }
        return current
    }

    private static func parentIndex(_ categories: [Category]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for c in categories { if let p = c.parentId { result[c.id] = p } }
        return result
    }

    /// Forced locale: pure engine, with no access to the SwiftUI
    /// environment. Same convention as `InsightEngine` / `AlertEngine`.
    private static func money(_ value: Double) -> String {
        value.formatted(.currency(code: "EUR").presentation(.narrow).locale(Locale(identifier: "fr_FR")))
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f %%", value)
    }
}
