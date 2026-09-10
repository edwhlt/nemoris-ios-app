import Foundation
import Observation

@Observable
@MainActor
final class BudgetViewModel {

    // MARK: - State

    // `didSet` : les trois sources de `enrichedPrevisions` la reconstruisent
    // quand elles changent — le cache ne peut donc pas devenir obsolète, quel
    // que soit le chemin de mutation (chargement, refresh, skip, match…).
    var patterns: [RecurringPattern] = [] { didSet { rebuildEnrichedPrevisions() } }
    var envelopes: [BudgetEnvelope] = []
    var previsions: [BudgetPrevision] = [] { didSet { rebuildEnrichedPrevisions() } }
    var categories: [Category] = [] { didSet { rebuildEnrichedPrevisions() } }
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

    private let repo: BudgetRepository
    private let txRepo: TransactionRepository

    /// La valeur par défaut vise la base de l'application : aucun site d'appel
    /// ne change. Les tests injectent une base temporaire.
    init(store: SQLiteStore = SQLiteStore()) {
        repo = BudgetRepository(store: store)
        txRepo = TransactionRepository(store: store)
    }

    /// Cache des prévisions par mois (clé "yyyy-MM"). Permet à `navigateMonth(by:)`
    /// de basculer `previsions` de façon SYNCHRONE quand le mois cible a déjà été
    /// pré-chargé — miroir du `txCache` que `BudgetView` tient pour les transactions.
    /// Sans ce cache, chaque swipe attendait un aller-retour SQL avant que les points
    /// "Prévu" du calendrier et la bulle de résumé n'affichent les bonnes valeurs.
    private var previsionsCache: [String: [BudgetPrevision]] = [:]

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
            self.repo.fetchPatterns()
        }.value
        let envelopesResult = await Task.detached(priority: .userInitiated) {
            self.repo.fetchEnvelopes()
        }.value
        let (start, end) = monthRange(displayedMonth)
        let prevResult = await Task.detached(priority: .userInitiated) {
            self.repo.fetchPrevisions(from: start, to: end)
        }.value
        let catResult = await Task.detached(priority: .userInitiated) {
            self.txRepo.fetchCategories()
        }.value

        self.patterns = patternsResult
        self.envelopes = envelopesResult
        self.previsions = prevResult
        self.categories = catResult
        previsionsCache[monthKey(displayedMonth)] = prevResult

        await prefetchAdjacentPrevisions()
    }

    // MARK: - Month Navigation

    func previousMonth() {
        navigateMonth(by: -1)
    }

    func nextMonth() {
        navigateMonth(by: 1)
    }

    func goToCurrentMonth() {
        let cal = Calendar.current
        let now = Date()
        displayedMonth = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
        applyCachedOrReloadPrevisions()
    }

    /// Saut direct à un mois arbitraire (pas forcément ±1) — sélecteur
    /// mois/année, scrubber. `month` peut être n'importe quel jour DU mois
    /// visé, normalisé au 1er.
    func setDisplayedMonth(_ month: Date) {
        let cal = Calendar.current
        displayedMonth = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        applyCachedOrReloadPrevisions()
    }

    /// Change le mois affiché de `delta` mois. Si les prévisions du mois cible sont
    /// déjà en cache (pré-chargées pendant qu'on regardait le mois précédent),
    /// `previsions` est réaffecté de façon SYNCHRONE — aucun aller-retour SQL entre
    /// le swipe et l'affichage des points "Prévu"/de la bulle de résumé.
    private func navigateMonth(by delta: Int) {
        displayedMonth = Calendar.current.date(byAdding: .month, value: delta, to: displayedMonth) ?? displayedMonth
        applyCachedOrReloadPrevisions()
    }

    private func applyCachedOrReloadPrevisions() {
        let key = monthKey(displayedMonth)
        if let cached = previsionsCache[key] {
            previsions = cached
        } else {
            // Mois jamais visité ni pré-chargé (ex: swipes rapides enchaînés) —
            // fallback sur l'ancien comportement (fetch async).
            Task { await reloadPrevisions() }
        }
        Task { await prefetchAdjacentPrevisions() }
    }

    private func reloadPrevisions() async {
        let (start, end) = monthRange(displayedMonth)
        let result = await Task.detached(priority: .userInitiated) {
            self.repo.fetchPrevisions(from: start, to: end)
        }.value
        previsionsCache[monthKey(displayedMonth)] = result
        self.previsions = result
    }

    /// Pré-charge les prévisions de M-1/M+1 pendant que l'utilisateur regarde le
    /// mois affiché, pour que le PROCHAIN swipe (dans un sens ou l'autre) trouve
    /// déjà tout en cache. Priorité `.utility` (pas `.background`) : un swipe
    /// rapproché doit avoir de bonnes chances de trouver le fetch déjà résolu.
    private func prefetchAdjacentPrevisions() async {
        let cal = Calendar.current
        for delta in [-1, 1] {
            let adjMonth = cal.date(byAdding: .month, value: delta, to: displayedMonth) ?? displayedMonth
            let key = monthKey(adjMonth)
            guard previsionsCache[key] == nil else { continue }
            let (s, e) = monthRange(adjMonth)
            let result = await Task.detached(priority: .utility) {
                self.repo.fetchPrevisions(from: s, to: e)
            }.value
            previsionsCache[key] = result
        }
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
                self.txRepo.fetchAllAccountsTransactions(from: start, to: end)
            }.value

            let candidates = RecurringDetector.detect(from: txs)
            // On garde TOUS les candidats, y compris ceux qui correspondent a
            // un motif deja existant (actif ou non) : les exclure en
            // silence les faisait disparaitre sans explication — un retour
            // terrain a lu ca comme "la detection ne marche pas". Le
            // panneau les affiche grises, avec un lien vers le motif
            // existant, plutot que de les escamoter. Tri stable : nouveaux
            // d'abord (dans l'ordre de confiance de RecurringDetector),
            // deja-suivis ensuite.
            self.detectionResults = candidates.sorted { a, b in
                let aKnown = a.existingMatch(in: patterns) != nil
                let bKnown = b.existingMatch(in: patterns) != nil
                return (aKnown ? 1 : 0) < (bKnown ? 1 : 0)
            }
            // Toujours ouvrir le panneau, même sans résultat : sinon un clic sur
            // "Détecter les récurrents" qui ne trouve rien ne fait RIEN de
            // visible, ce qui se lit comme "le bouton ne marche plus" plutôt
            // que "aucun récurrent ne remplit les 4 critères". Le panneau
            // affiche alors un état vide explicite (DetectionResultsSheet).
            self.showDetectionSheet = true
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
        if let newId = self.repo.insertPattern(pattern) {
            let withId = RecurringPattern(
                id: newId, name: pattern.name, amountAvg: pattern.amountAvg,
                amountTolerance: pattern.amountTolerance, categoryId: pattern.categoryId,
                payeeId: pattern.payeeId, frequency: pattern.frequency, anchorDay: pattern.anchorDay,
                isActive: true, isManual: false, createdAt: pattern.createdAt,
                lastDetectedAt: pattern.lastDetectedAt,
                startDate: pattern.startDate, endDate: nil
            )
            self.repo.regeneratePrevisions(for: withId)
        }
        refresh()
    }

    // MARK: - Pattern CRUD

    func addManualPattern(_ pattern: RecurringPattern) {
        if let newId = self.repo.insertPattern(pattern) {
            let withId = RecurringPattern(
                id: newId, name: pattern.name, amountAvg: pattern.amountAvg,
                amountTolerance: pattern.amountTolerance, categoryId: pattern.categoryId,
                payeeId: pattern.payeeId, frequency: pattern.frequency, anchorDay: pattern.anchorDay,
                isActive: pattern.isActive, isManual: true, createdAt: pattern.createdAt,
                lastDetectedAt: nil, startDate: pattern.startDate, endDate: pattern.endDate
            )
            self.repo.regeneratePrevisions(for: withId)
            scheduleNotificationsForPattern(withId)
        }
        refresh()
    }

    func updatePattern(_ pattern: RecurringPattern) {
        self.repo.updatePattern(pattern)
        self.repo.regeneratePrevisions(for: pattern)
        scheduleNotificationsForPattern(pattern)
        refresh()
    }

    func deletePattern(id: Int) {
        // Cancel les notifs avant de supprimer (les previsions seront cascade-deleted)
        let toCancel = self.repo.fetchPrevisions(forPatternId: id)
        BudgetNotificationService.cancelAll(forPatternId: id, previsions: toCancel)
        self.repo.deletePattern(id: id)
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
        self.repo.updatePattern(updated)
        if updated.isActive {
            self.repo.regeneratePrevisions(for: updated)
            scheduleNotificationsForPattern(updated)
        } else {
            // Pattern désactivé → cancel toutes ses notifs
            let toCancel = self.repo.fetchPrevisions(forPatternId: updated.id)
            BudgetNotificationService.cancelAll(forPatternId: updated.id, previsions: toCancel)
        }
        refresh()
    }

    /// Helper : re-schedule j-3 notifications pour toutes les prévisions PENDING d'un pattern.
    /// Appelé après regeneratePrevisions pour rafraîchir les notifs sans dupliquer.
    private func scheduleNotificationsForPattern(_ pattern: RecurringPattern) {
        guard pattern.isActive else { return }
        let previsions = self.repo.fetchPrevisions(forPatternId: pattern.id)
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
        self.repo.insertEnvelope(envelope)
        refresh()
    }

    func updateEnvelope(_ envelope: BudgetEnvelope) {
        self.repo.updateEnvelope(envelope)
        refresh()
    }

    func deleteEnvelope(id: Int) {
        self.repo.deleteEnvelope(id: id)
        refresh()
    }

    // MARK: - Prevision Actions

    func skipPrevision(_ prevision: BudgetPrevision) {
        self.repo.updatePrevisionStatus(id: prevision.id, status: .skipped, transactionId: nil)
        // Skip → cancel la notif j-3 (sinon on rappelle une échéance que l'utilisateur a ignorée)
        BudgetNotificationService.cancel(forPrevisionId: prevision.id)
        refresh()
    }

    /// Arrête un récurrent à partir de cette échéance : pose `endDate` la veille
    /// du jour attendu, régénère les prévisions (celle-ci et toutes celles après
    /// disparaissent, aucune nouvelle ne sera générée) et réconcilie les notifs.
    /// Contrairement à `skipPrevision` (ignore UNE occurrence, le récurrent
    /// continue), c'est l'équivalent de modifier la date de fin du motif.
    func stopPatternAfter(_ prevision: BudgetPrevision) {
        guard let patternId = prevision.recurringPatternId,
              let pattern = patterns.first(where: { $0.id == patternId }) else { return }
        let cal = Calendar.current
        let newEnd = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: prevision.expectedDate))
            ?? prevision.expectedDate
        let updated = RecurringPattern(
            id: pattern.id, name: pattern.name, amountAvg: pattern.amountAvg,
            amountTolerance: pattern.amountTolerance, categoryId: pattern.categoryId,
            payeeId: pattern.payeeId, frequency: pattern.frequency, anchorDay: pattern.anchorDay,
            isActive: pattern.isActive, isManual: pattern.isManual,
            createdAt: pattern.createdAt, lastDetectedAt: pattern.lastDetectedAt,
            startDate: pattern.startDate, endDate: newEnd
        )
        // updatePattern() persiste, régénère les previsions dans la nouvelle
        // plage (donc plus rien après newEnd) et reschedule les notifs.
        updatePattern(updated)
    }

    func matchPrevision(_ prevision: BudgetPrevision, to transactionId: Int) {
        self.repo.updatePrevisionStatus(id: prevision.id, status: .matched, transactionId: transactionId)
        // Matched → cancel la notif (échéance honorée, rappel inutile)
        BudgetNotificationService.cancel(forPrevisionId: prevision.id)
        refresh()
    }

    // MARK: - Computed Views

    /// Previsions enrichies pour le mois affiche
    /// Liste enrichie MISE EN CACHE (et non recalculée à chaque lecture).
    ///
    /// ⚠️ C'était une propriété calculée : chaque lecture reconstruisait les
    /// ~1300 prévisions puis les triait. Les vues la lisent plusieurs fois par
    /// rendu — et parfois à l'intérieur d'une boucle — ce qui rendait le module
    /// inutilisable. Elle est désormais recalculée UNIQUEMENT quand ses sources
    /// changent (cf. les `didSet` de `previsions`/`patterns`/`categories`), et
    /// l'association prévision → récurrent passe par un dictionnaire au lieu
    /// d'une recherche linéaire.
    private(set) var enrichedPrevisions: [EnrichedPrevision] = []

    private func rebuildEnrichedPrevisions() {
        let patternsById = Dictionary(patterns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let categoryNameById = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        enrichedPrevisions = previsions.compactMap { prev in
            let pattern = prev.recurringPatternId.flatMap { patternsById[$0] }
            let catName = pattern?.categoryId.flatMap { categoryNameById[$0] }
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
            self.txRepo.fetchAllAccountsTransactions(from: start, to: end)
        }.value
        return monthlySummary(transactions: txs)
    }

    /// Variante synchrone : calcule le résumé à partir de transactions déjà en
    /// mémoire (cache tenu par `BudgetView`), sans repasser par SQLite. Utilisée au
    /// swipe de mois pour un affichage instantané de la bulle de résumé — le fetch
    /// réseau/DB est le principal facteur du délai qu'on cherche à éliminer.
    func monthlySummary(transactions txs: [FinanceTransaction]) -> MonthlyBudgetSummary {
        let monthPrevisions = previsions.filter { $0.status != .skipped }
        // Part FIXE du prévu = somme des prévisions négatives (récurrents identifiés).
        let recurringForecast = monthPrevisions.filter { $0.amount < 0 }.reduce(0) { $0 + abs($1.amount) }
        // Part VARIABLE du prévu = somme des enveloppes actives du mois MOINS
        // ce qui est déjà couvert par les récurrents de la même catégorie (pour
        // éviter le double comptage : si "Loyer & Charges" a un récurrent de
        // 950 € ET une enveloppe de 1100 €, on n'ajoute que le delta 150 €).
        // Catégorie de chaque récurrent, indexée UNE fois : la version d'origine
        // refaisait un `patterns.first(where:)` pour chaque prévision de chaque
        // enveloppe (≈ 2,4 M comparaisons sur une base réelle) — l'un des deux
        // points chauds qui gelaient le module.
        let patternCategoryById = Dictionary(
            patterns.compactMap { p in p.categoryId.map { (p.id, $0) } },
            uniquingKeysWith: { a, _ in a }
        )
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
                              let patternCat = patternCategoryById[patternId]
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

        // Moteur partagé — même calcul que le Dashboard, les alertes et le widget.
        // Voir `EnvelopeSpendingCalculator` pour l'historique des 4 versions divergentes.
        let envelopeProgress = EnvelopeSpendingCalculator.progresses(
            envelopes: envelopes.filter { $0.isActive },
            transactions: txs,
            categories: categories,
            previsions: previsions,
            patterns: patterns
        )

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
    /// ⚠️ Trois corrections de perf par rapport à la version d'origine, qui
    /// gelait la fenêtre plusieurs secondes :
    /// 1. `enrichedPrevisions` est lu UNE fois (il était relu à chaque jour du
    ///    mois, soit ~31 recalculs complets de la liste enrichie) ;
    /// 2. indexation par jour via `Dictionary(grouping:)` — O(n) — au lieu d'un
    ///    `filter` complet par jour, O(n × 31) ;
    /// 3. clé = `startOfDay` (une `Date`) au lieu d'une chaîne formatée : chaque
    ///    appel à `isoDate` construisait un `DateFormatter` neuf, ce qui est
    ///    coûteux, et il y en avait des dizaines de milliers.
    func calendarDays(transactions: [FinanceTransaction]) -> [CalendarDay] {
        calendarDays(for: displayedMonth, transactions: transactions, previsions: enrichedPrevisions)
    }

    /// Variante pure adressée à un mois EXPLICITE — ne lit ni `displayedMonth`
    /// ni `previsions`/`enrichedPrevisions`, contrairement à la surcharge
    /// ci-dessus. Nécessaire pour le carrousel de pages du calendrier
    /// (`BudgetView`) : les pages voisines (M-1/M+1) doivent pouvoir être
    /// pré-rendues à partir du cache SANS que ça dépende du mois
    /// actuellement affiché — sinon elles montreraient soit la plage de
    /// jours du mauvais mois, soit les prévisions du mois affiché appliquées
    /// aux transactions d'un autre mois.
    func calendarDays(for month: Date, transactions: [FinanceTransaction], previsions: [EnrichedPrevision]) -> [CalendarDay] {
        let cal = Calendar.current
        guard let range = cal.dateInterval(of: .month, for: month) else { return [] }
        let totalDays = cal.dateComponents([.day], from: range.start, to: range.end).day ?? 30
        let prevByDay = Dictionary(grouping: previsions) { cal.startOfDay(for: $0.expectedDate) }
        let txByDay = Dictionary(grouping: transactions) { cal.startOfDay(for: $0.date) }

        return (0..<totalDays).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: offset, to: range.start) else { return nil }
            let key = cal.startOfDay(for: day)
            return CalendarDay(date: day,
                               previsions: prevByDay[key] ?? [],
                               transactions: txByDay[key] ?? [])
        }
    }

    /// Enrichit une liste de prévisions BRUTES (ex : `previsionsCache[key]`)
    /// avec le nom du récurrent/de la catégorie — même logique que
    /// `rebuildEnrichedPrevisions()`, mais pure (ne mute pas `self.enrichedPrevisions`,
    /// ne dépend pas de `self.previsions`). Utilisée pour enrichir les
    /// prévisions déjà pré-chargées d'un mois voisin sans y attacher celles
    /// du mois affiché.
    func enrichPrevisions(_ raw: [BudgetPrevision]) -> [EnrichedPrevision] {
        let patternsById = Dictionary(patterns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let categoryNameById = Dictionary(categories.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return raw.compactMap { prev in
            let pattern = prev.recurringPatternId.flatMap { patternsById[$0] }
            let catName = pattern?.categoryId.flatMap { categoryNameById[$0] }
            return EnrichedPrevision(
                prevision: prev,
                patternName: pattern?.name ?? "Manuel",
                categoryName: catName,
                frequency: pattern?.frequency ?? .monthly
            )
        }
        .sorted { $0.expectedDate < $1.expectedDate }
    }

    /// Prévisions brutes déjà en cache pour `month` (`previsionsCache`, rempli
    /// par `prefetchAdjacentPrevisions`) — `nil` si pas encore pré-chargées.
    func cachedPrevisions(for month: Date) -> [BudgetPrevision]? {
        previsionsCache[monthKey(month)]
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
            self.repo.updatePrevisionStatus(id: m.previsionId, status: .matched, transactionId: m.transactionId)
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

    /// Formateur RÉUTILISÉ : en construire un à chaque appel coûte cher, et cette
    /// fonction est appelée en boucle. Locale POSIX pour un format stable.
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func isoDate(_ date: Date) -> String {
        Self.isoFormatter.string(from: date)
    }

    /// Retourne l'id de la categorie + tous ses enfants (pour les enveloppes hierarchiques)
    private func allCategoryIds(for categoryId: Int?) -> [Int] {
        guard let id = categoryId else { return [] }
        let children = categories.filter { $0.parentId == id }.map { $0.id }
        return [id] + children
    }
}


