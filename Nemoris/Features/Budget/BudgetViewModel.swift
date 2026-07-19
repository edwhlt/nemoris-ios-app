import Foundation
import Observation

@Observable
@MainActor
final class BudgetViewModel {

    // MARK: - State

    var patterns: [RecurringPattern] = []
    var envelopes: [BudgetEnvelope] = []
    var previsions: [BudgetPrevision] = []
    var categories: [Category] = []
    var isLoading = false
    var detectionResults: [DetectionCandidate] = []
    var showDetectionSheet = false

    /// Mois affiche dans le calendrier et la comparaison (ex: "2025-01")
    var displayedMonth: Date = {
        let cal = Calendar.current
        let now = Date()
        return cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
    }()

    // MARK: - Private

    private let repo = BudgetRepository.shared
    private let txRepo = TransactionRepository()

    // MARK: - Lifecycle

    func onAppear() {
        Task { await loadAll() }
    }

    func refresh() {
        Task { await loadAll() }
    }

    // MARK: - Loading

    private func loadAll() async {
        isLoading = true
        defer { isLoading = false }

        let patternsResult = await Task.detached(priority: .userInitiated) {
            BudgetRepository.shared.fetchPatterns()
        }.value
        let envelopesResult = await Task.detached(priority: .userInitiated) {
            BudgetRepository.shared.fetchEnvelopes()
        }.value
        let (start, end) = monthRange(displayedMonth)
        let prevResult = await Task.detached(priority: .userInitiated) {
            BudgetRepository.shared.fetchPrevisions(from: start, to: end)
        }.value
        let catResult = await Task.detached(priority: .userInitiated) {
            TransactionRepository().fetchCategories()
        }.value

        self.patterns = patternsResult
        self.envelopes = envelopesResult
        self.previsions = prevResult
        self.categories = catResult
    }

    // MARK: - Month Navigation

    func previousMonth() {
        displayedMonth = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
        Task { await reloadPrevisions() }
    }

    func nextMonth() {
        displayedMonth = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
        Task { await reloadPrevisions() }
    }

    func goToCurrentMonth() {
        let cal = Calendar.current
        let now = Date()
        displayedMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        Task { await reloadPrevisions() }
    }

    private func reloadPrevisions() async {
        let (start, end) = monthRange(displayedMonth)
        let result = await Task.detached(priority: .userInitiated) {
            BudgetRepository.shared.fetchPrevisions(from: start, to: end)
        }.value
        self.previsions = result
    }

    // MARK: - Auto-Detection

    /// Analyse l'historique de l'utilisateur et propose des motifs recurrents a valider.
    /// Analyse TOUS les comptes pour ne rater aucun abonnement.
    func runAutoDetection() {
        isLoading = true
        Task {
            defer { isLoading = false }
            // Charger 24 mois de transactions sur tous les comptes
            let end = Date()
            let start = Calendar.current.date(byAdding: .month, value: -24, to: end) ?? end
            let txs = await Task.detached(priority: .userInitiated) {
                TransactionRepository().fetchAllAccountsTransactions(from: start, to: end)
            }.value

            let candidates = RecurringDetector.detect(from: txs)
            // Filtrer ceux deja connus
            let knownPayeeIds = Set(patterns.compactMap { $0.payeeId })
            let knownNames = Set(patterns.map { $0.name.lowercased() })
            self.detectionResults = candidates.filter { c in
                if let pid = c.payeeId, knownPayeeIds.contains(pid) { return false }
                return !knownNames.contains(c.name.lowercased())
            }
            self.showDetectionSheet = !self.detectionResults.isEmpty
        }
    }

    /// Valide et enregistre un candidat detecte comme motif recurrent.
    func acceptCandidate(_ candidate: DetectionCandidate) {
        let firstOccurrence = candidate.occurrences.first ?? Date()
        let pattern = RecurringPattern(
            id: 0,
            name: candidate.name,
            amountAvg: candidate.amountAvg,
            amountTolerance: 0.15,
            categoryId: candidate.categoryId,
            payeeId: candidate.payeeId,
            frequency: candidate.frequency,
            anchorDay: candidate.anchorDay,
            isActive: true,
            isManual: false,
            createdAt: Date(),
            lastDetectedAt: candidate.occurrences.last,
            startDate: firstOccurrence,
            endDate: nil
        )
        if let newId = repo.insertPattern(pattern) {
            let withId = RecurringPattern(
                id: newId, name: pattern.name, amountAvg: pattern.amountAvg,
                amountTolerance: pattern.amountTolerance, categoryId: pattern.categoryId,
                payeeId: pattern.payeeId, frequency: pattern.frequency, anchorDay: pattern.anchorDay,
                isActive: true, isManual: false, createdAt: pattern.createdAt,
                lastDetectedAt: pattern.lastDetectedAt,
                startDate: pattern.startDate, endDate: nil
            )
            repo.regeneratePrevisions(for: withId)
        }
        refresh()
    }

    // MARK: - Pattern CRUD

    func addManualPattern(_ pattern: RecurringPattern) {
        if let newId = repo.insertPattern(pattern) {
            let withId = RecurringPattern(
                id: newId, name: pattern.name, amountAvg: pattern.amountAvg,
                amountTolerance: pattern.amountTolerance, categoryId: pattern.categoryId,
                payeeId: pattern.payeeId, frequency: pattern.frequency, anchorDay: pattern.anchorDay,
                isActive: pattern.isActive, isManual: true, createdAt: pattern.createdAt,
                lastDetectedAt: nil, startDate: pattern.startDate, endDate: pattern.endDate
            )
            repo.regeneratePrevisions(for: withId)
            scheduleNotificationsForPattern(withId)
        }
        refresh()
    }

    func updatePattern(_ pattern: RecurringPattern) {
        repo.updatePattern(pattern)
        repo.regeneratePrevisions(for: pattern)
        scheduleNotificationsForPattern(pattern)
        refresh()
    }

    func deletePattern(id: Int) {
        // Cancel les notifs avant de supprimer (les previsions seront cascade-deleted)
        let toCancel = repo.fetchPrevisions(forPatternId: id)
        BudgetNotificationService.cancelAll(forPatternId: id, previsions: toCancel)
        repo.deletePattern(id: id)
        refresh()
    }

    func togglePattern(_ pattern: RecurringPattern) {
        let updated = RecurringPattern(
            id: pattern.id, name: pattern.name, amountAvg: pattern.amountAvg,
            amountTolerance: pattern.amountTolerance, categoryId: pattern.categoryId,
            payeeId: pattern.payeeId, frequency: pattern.frequency, anchorDay: pattern.anchorDay,
            isActive: !pattern.isActive, isManual: pattern.isManual,
            createdAt: pattern.createdAt, lastDetectedAt: pattern.lastDetectedAt,
            startDate: pattern.startDate, endDate: pattern.endDate
        )
        repo.updatePattern(updated)
        if updated.isActive {
            repo.regeneratePrevisions(for: updated)
            scheduleNotificationsForPattern(updated)
        } else {
            // Pattern désactivé → cancel toutes ses notifs
            let toCancel = repo.fetchPrevisions(forPatternId: updated.id)
            BudgetNotificationService.cancelAll(forPatternId: updated.id, previsions: toCancel)
        }
        refresh()
    }

    /// Helper : re-schedule j-3 notifications pour toutes les prévisions PENDING d'un pattern.
    /// Appelé après regeneratePrevisions pour rafraîchir les notifs sans dupliquer.
    private func scheduleNotificationsForPattern(_ pattern: RecurringPattern) {
        guard pattern.isActive else { return }
        let previsions = repo.fetchPrevisions(forPatternId: pattern.id)
        Task {
            await BudgetNotificationService.rescheduleForPattern(
                patternId: pattern.id,
                patternName: pattern.name,
                previsions: previsions
            )
        }
    }

    // MARK: - Envelope CRUD

    func addEnvelope(_ envelope: BudgetEnvelope) {
        repo.insertEnvelope(envelope)
        refresh()
    }

    func updateEnvelope(_ envelope: BudgetEnvelope) {
        repo.updateEnvelope(envelope)
        refresh()
    }

    func deleteEnvelope(id: Int) {
        repo.deleteEnvelope(id: id)
        refresh()
    }

    // MARK: - Prevision Actions

    func skipPrevision(_ prevision: BudgetPrevision) {
        repo.updatePrevisionStatus(id: prevision.id, status: .skipped, transactionId: nil)
        // Skip → cancel la notif j-3 (sinon on rappelle une échéance que l'user a ignorée)
        BudgetNotificationService.cancel(forPrevisionId: prevision.id)
        refresh()
    }

    func matchPrevision(_ prevision: BudgetPrevision, to transactionId: Int) {
        repo.updatePrevisionStatus(id: prevision.id, status: .matched, transactionId: transactionId)
        // Matched → cancel la notif (échéance honorée, rappel inutile)
        BudgetNotificationService.cancel(forPrevisionId: prevision.id)
        refresh()
    }

    // MARK: - Computed Views

    /// Previsions enrichies pour le mois affiche
    var enrichedPrevisions: [EnrichedPrevision] {
        previsions.compactMap { prev in
            let pattern = patterns.first { $0.id == prev.recurringPatternId }
            let catName = categoryName(for: pattern?.categoryId)
            return EnrichedPrevision(
                prevision: prev,
                patternName: pattern?.name ?? "Manuel",
                categoryName: catName,
                frequency: pattern?.frequency ?? .monthly
            )
        }
        .sorted { $0.expectedDate < $1.expectedDate }
    }

    var pendingPrevisions: [EnrichedPrevision] {
        enrichedPrevisions.filter { $0.status == .pending }
    }

    var upcomingPrevisions: [EnrichedPrevision] {
        let next7 = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
        return pendingPrevisions.filter { $0.expectedDate <= next7 && $0.expectedDate >= Date() }
    }

    /// Resume mensuel (pour le dashboard) — tous les comptes
    func monthlySummary() async -> MonthlyBudgetSummary {
        let (start, end) = monthRange(displayedMonth)
        let txs = await Task.detached(priority: .userInitiated) {
            TransactionRepository().fetchAllAccountsTransactions(from: start, to: end)
        }.value

        let monthPrevisions = previsions.filter { $0.status != .skipped }
        // Part FIXE du prévu = somme des prévisions négatives (récurrents identifiés).
        let recurringForecast = monthPrevisions.filter { $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) }
        // Part VARIABLE du prévu = somme des enveloppes actives du mois MOINS
        // ce qui est déjà couvert par les récurrents de la même catégorie (pour
        // éviter le double comptage : si "Loyer & Charges" a un récurrent de
        // 950 € ET une enveloppe de 1100 €, on n'ajoute que le delta 150 €).
        let envelopeForecast = envelopes
            .filter { $0.isActive }
            .reduce(0.0) { acc, env in
                let allocated = env.period == .yearly ? env.amount / 12 : env.amount
                guard let cid = env.categoryId else { return acc + allocated }
                let allIds = allCategoryIds(for: cid)
                // Récurrents déjà budgétés dans cette catégorie (ou sous-cat)
                let alreadyCovered = monthPrevisions
                    .filter { p in
                        guard p.amount < 0 else { return false }
                        guard let patternId = p.recurringPatternId,
                              let patternCat = patterns.first(where: { $0.id == patternId })?.categoryId
                        else { return false }
                        return allIds.contains(patternCat)
                    }
                    .reduce(0.0) { $0 + abs($1.amount) }
                // Si les récurrents dépassent l'enveloppe, l'enveloppe ne rajoute rien.
                return acc + max(0, allocated - alreadyCovered)
            }
        let forecasted = recurringForecast + envelopeForecast
        let actual = txs.filter { $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) }
        let totalIncome = txs.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        let matched = previsions.filter { $0.status == .matched }.count
        let pending = previsions.filter { $0.status == .pending }.count

        // IDs des transactions liées à des prévisions confirmées (charges récurrentes réelles)
        let matchedTxIds = Set(previsions.filter { $0.status == .matched }.compactMap { $0.actualTransactionId })
        let fixedActual = txs
            .filter { matchedTxIds.contains($0.id) && $0.amount < 0 }
            .reduce(0) { $0 + abs($1.amount) }

        let envelopeProgress = envelopes.filter { $0.isActive }.map { env -> EnvelopeProgress in
            let catName = categoryName(for: env.categoryId)
            let catIcon = categoryIcon(for: env.categoryId)
            let allIds = allCategoryIds(for: env.categoryId)
            let envTxs = txs.filter { $0.amount < 0 && allIds.contains($0.categoryId ?? -1) }
            let spent = envTxs.reduce(0) { $0 + abs($1.amount) }
            let recurringSpent = envTxs
                .filter { matchedTxIds.contains($0.id) }
                .reduce(0) { $0 + abs($1.amount) }
            // Prévisions actives du mois pour les patterns liés à cette catégorie
            let envPatternIds = Set(patterns
                .filter { p in p.categoryId.map { allIds.contains($0) } ?? false }
                .map { $0.id })
            let forecasted = previsions
                .filter { p in
                    p.status != .skipped &&
                    p.amount < 0 &&
                    (p.recurringPatternId.map { envPatternIds.contains($0) } ?? false)
                }
                .reduce(0) { $0 + abs($1.amount) }
            let allocated = env.period == .yearly ? env.amount / 12 : env.amount
            return EnvelopeProgress(envelope: env, categoryName: catName ?? env.name,
                                    categoryIcon: catIcon, spent: spent,
                                    allocated: allocated, recurringSpent: recurringSpent,
                                    forecasted: forecasted)
        }

        let monthStr = monthKey(displayedMonth)
        return MonthlyBudgetSummary(
            month: monthStr,
            forecastedExpenses: forecasted,
            actualExpenses: actual,
            matchedCount: matched,
            pendingCount: pending,
            envelopes: envelopeProgress,
            totalIncome: totalIncome,
            fixedActual: fixedActual
        )
    }

    /// Jours du mois affiche pour le calendrier — tous les comptes
    func calendarDays(transactions: [FinanceTransaction]) -> [CalendarDay] {
        let cal = Calendar.current
        let (start, _) = monthRange(displayedMonth)
        guard let range = cal.dateInterval(of: .month, for: displayedMonth) else { return [] }

        let totalDays = cal.dateComponents([.day], from: range.start, to: range.end).day ?? 30
        var days: [CalendarDay] = []

        for offset in 0..<totalDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: start) else { continue }
            let dayKey = isoDate(day)
            let dayPrevisions = enrichedPrevisions.filter { isoDate($0.expectedDate) == dayKey }
            let dayTxs = transactions.filter { isoDate($0.date) == dayKey }
            days.append(CalendarDay(date: day, previsions: dayPrevisions, transactions: dayTxs))
        }
        return days
    }

    // MARK: - Duplicate Matching

    /// Tente de matcher automatiquement les nouvelles transactions aux previsions en attente.
    func autoMatchTransactions(_ transactions: [FinanceTransaction]) {
        let matches = TransactionMatcher.autoMatch(
            transactions: transactions,
            previsions: previsions.filter { $0.status == .pending },
            patterns: patterns
        )
        guard !matches.isEmpty else { return }
        for m in matches {
            repo.updatePrevisionStatus(id: m.previsionId, status: .matched, transactionId: m.transactionId)
            // Auto-match → cancel la notif j-3 (échéance honorée)
            BudgetNotificationService.cancel(forPrevisionId: m.previsionId)
        }
        refresh()
    }

    // MARK: - Helpers

    private func monthRange(_ date: Date) -> (Date, Date) {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
        let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? date
        return (start, end)
    }

    private func monthKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: date)
    }

    private func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func categoryName(for categoryId: Int?) -> String? {
        guard let id = categoryId else { return nil }
        return categories.first { $0.id == id }?.name
    }

    private func categoryIcon(for categoryId: Int?) -> String {
        guard let id = categoryId,
              let cat = categories.first(where: { $0.id == id }) else { return "tag.fill" }
        return cat.displayIcon
    }

    /// Retourne l'id de la categorie + tous ses enfants (pour les enveloppes hierarchiques)
    private func allCategoryIds(for categoryId: Int?) -> [Int] {
        guard let id = categoryId else { return [] }
        let children = categories.filter { $0.parentId == id }.map { $0.id }
        return [id] + children
    }
}

