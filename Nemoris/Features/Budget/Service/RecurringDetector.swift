import Foundation

// MARK: - RecurringDetector
//
// Analyse l'historique des transactions pour detecter automatiquement
// les depenses et revenus recurrents (abonnements, loyer, salaire, etc.)
//
// Une recurrence n'est retenue QUE si les 4 criteres suivants sont TOUS
// verifies (portes strictes, pas un score qui compense un critere faible
// par un autre) :
//  1. Tiers identique         -> le regroupement se fait par payee_id (ou
//                                 nom normalise a defaut), donc structurel.
//  2. Frequence reguliere     -> TOUS les ecarts consecutifs (pas seulement
//                                 la mediane) doivent tomber dans la fenetre
//                                 d'une frequence canonique (hebdomadaire,
//                                 bimensuel, mensuel, trimestriel,
//                                 semestriel, annuel).
//  3. Montant quasi identique -> ecart-type relatif sous un seuil serre
//                                 (AMOUNT_TOLERANCE), pas les 50% laxistes
//                                 d'avant.
//  4. Date d'echeance stable  -> le jour du mois (ou le jour de semaine)
//                                 de chaque occurrence doit rester proche
//                                 de l'ancrage (DATE_TOLERANCE_DAYS).
//
// Si un seul de ces criteres echoue, le groupe est rejete entierement
// (retourne nil) : on ne "degrade" plus la confiance, on refuse le candidat.
// La confiance restante ne sert qu'a trier les candidats valides entre eux.

struct DetectionCandidate: Identifiable {
    let name: String
    let payeeId: Int?
    let categoryId: Int?
    let amountAvg: Double
    let amountStdDev: Double
    let frequency: RecurrenceFrequency
    let anchorDay: Int?
    let occurrences: [Date]
    /// Montants des transactions a l'origine de la detection, meme ordre et
    /// meme index que `occurrences` — pour pouvoir afficher le detail de
    /// chaque occurrence (pas seulement la moyenne agregee).
    let occurrenceAmounts: [Double]
    /// Score de confiance 0…1 (classement uniquement, tous les candidats
    /// retournes ont deja passe les portes strictes ci-dessus)
    let confidence: Double

    var id: String { name }

    /// Brouillon de motif pre-rempli avec les valeurs detectees, pour
    /// permettre a l'utilisateur d'ajuster (montant, jour, categorie…) avant
    /// de confirmer — plutot que de n'avoir que le choix "tel quel".
    func asDraftPattern() -> RecurringPattern {
        RecurringPattern(
            id: 0, name: name, amountAvg: amountAvg, amountTolerance: 0.15,
            categoryId: categoryId, payeeId: payeeId, frequency: frequency,
            anchorDay: anchorDay, isActive: true, isManual: false,
            createdAt: Date(), lastDetectedAt: occurrences.last,
            startDate: occurrences.first ?? Date(), endDate: nil
        )
    }

    /// Le motif existant (actif OU inactif) qui correspond déjà à ce
    /// candidat — même règle d'identité que le regroupement de détection
    /// (payee d'abord, nom sinon). Source UNIQUE de cette décision : utilisée
    /// à la fois pour trier/griser "Déjà suivi" dans le panneau et pour
    /// éviter qu'un "Confirmer" y crée un doublon.
    func existingMatch(in patterns: [RecurringPattern]) -> RecurringPattern? {
        if let pid = payeeId, let match = patterns.first(where: { $0.payeeId == pid }) {
            return match
        }
        return patterns.first { $0.name.lowercased() == name.lowercased() }
    }

    /// true si ce qui vient d'être détecté (montant, fréquence, jour
    /// d'ancrage) s'écarte sensiblement du motif déjà suivi — signale un prix
    /// qui a changé (abonnement, cotisation) ou une échéance qui a glissé,
    /// que le motif existant n'a jamais rattrapé (il n'est ré-évalué qu'à la
    /// création, jamais automatiquement par la suite).
    func differsFrom(_ existing: RecurringPattern) -> Bool {
        let existingAmount = abs(existing.amountAvg)
        let detectedAmount = abs(amountAvg)
        let relativeDiff = existingAmount > 0 ? abs(detectedAmount - existingAmount) / existingAmount : 0
        if relativeDiff > 0.01 { return true }
        if frequency != existing.frequency { return true }
        if let a = anchorDay, let b = existing.anchorDay, a != b { return true }
        return false
    }

    /// Fusionne les valeurs fraîchement détectées dans un motif EXISTANT —
    /// pour corriger un récurrent dont le prix ou l'échéance a dérivé, sans
    /// perdre sa configuration propre (catégorie, tier, actif/inactif,
    /// tolérance, période).
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

    /// Ecart-type relatif maximal tolere entre les montants d'un groupe pour
    /// le considerer comme "prix identique". 8% absorbe l'arrondi/la TVA
    /// variable d'un abonnement sans laisser passer des montants qui varient
    /// vraiment (facture d'energie, courses...).
    /// Pas `private` : reutilise tel quel par l'UI de detail pour expliquer
    /// pourquoi un candidat a ete retenu (source unique du seuil reel).
    static let amountTolerance = 0.08

    /// Nombre minimal d'occurrences pour affirmer une periodicite. Avec 2
    /// points on n'a qu'un seul ecart : impossible de verifier qu'il se
    /// repete. Il en faut au moins 3 (2 ecarts consecutifs a comparer).
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

    /// Fenetre [min, max] en jours qu'un ecart CONSECUTIF doit respecter
    /// pour appartenir a cette frequence. Chaque ecart du groupe doit y
    /// tomber — pas seulement la mediane — sinon la "frequence" n'est
    /// qu'une coincidence entre deux points. Pas `private` : reutilise
    /// par l'UI de detail.
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

    /// Ordre de detection : du plus court au plus long, pour retenir la
    /// frequence la plus fine qui explique TOUS les ecarts (un groupe dont
    /// les ecarts sont tous ~14j doit rester "bimensuel", pas glisser vers
    /// une fenetre plus large qui l'engloberait aussi).
    private static let candidateFrequencies: [RecurrenceFrequency] =
        [.daily, .weekly, .biweekly, .monthly, .quarterly, .semiannual, .yearly]

    // MARK: - Public API

    /// Detecte les motifs recurrents dans un tableau de transactions.
    /// - Parameter transactions: Toutes les transactions disponibles (tri non requis).
    /// - Returns: Candidats tries par confiance decroissante.
    static func detect(from transactions: [FinanceTransaction]) -> [DetectionCandidate] {
        // Grouper par payee_id puis par nom normalise (critere "tiers identique")
        let groups = groupTransactions(transactions)

        var candidates: [DetectionCandidate] = []
        for (_, txs) in groups {
            guard txs.count >= minOccurrences else { continue }

            // Sous-grouper par montant similaire (meme tiers, montants proches = probablement le meme abonnement)
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
    // Regroupe les transactions d'un meme tiers par montant similaire (meme
    // tolerance que le critere final : pas la peine de clusterer plus large
    // que ce que le gate final acceptera).

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

        // --- Critere "frequence reguliere" : TOUS les ecarts consecutifs ---
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
        // Score de classement uniquement (tous les criteres durs sont deja
        // valides a ce stade) : recompense la regularite fine des ecarts,
        // la precision du montant et le nombre d'occurrences observees.
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

    /// Trouve la frequence canonique la plus fine dont la fenetre de tolerance
    /// contient TOUS les ecarts consecutifs du groupe. Contrairement a
    /// l'ancienne version (mediane seule), un groupe dont un seul ecart
    /// s'ecarte de la fenetre est rejete : ce n'est pas une "frequence
    /// approximative avec du bruit", c'est un motif qui n'est pas regulier.
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
            // Jour du mois le plus frequent. Les jours de fin de mois
            // (28-31) sont regroupes : "le 31" et "le 28 (fevrier)" sont la
            // meme echeance "fin de mois" pour un abonnement mensualise.
            let days = dates.map { normalizedMonthDay(for: $0, calendar: cal) }
            return mostFrequent(days)
        }
        if frequency.usesWeekdayAnchor {
            // Jour de la semaine ISO le plus frequent (1=lundi)
            let weekdays = dates.compactMap { cal.dateComponents([.weekday], from: $0).weekday }
            let isoWeekdays = weekdays.map { ($0 + 5) % 7 + 1 }
            return mostFrequent(isoWeekdays)
        }
        if frequency == .yearly {
            // Jour de l'annee (1-366) le plus proche, pour verifier la
            // stabilite mois+jour d'une echeance annuelle.
            let doys = dates.compactMap { cal.ordinality(of: .day, in: .year, for: $0) }
            return mostFrequent(doys)
        }
        return nil // .daily : pas d'ancrage pertinent
    }

    /// Jour du mois normalise : un jour >= 28 est ramene au dernier jour du
    /// mois considere (28/29/30/31 selon le mois), pour que "fin de mois"
    /// soit une seule categorie plutot que 4 valeurs distinctes.
    private static func normalizedMonthDay(for date: Date, calendar: Calendar) -> Int {
        let day = calendar.component(.day, from: date)
        guard day >= 28, let range = calendar.range(of: .day, in: .month, for: date) else { return day }
        let lastDay = range.upperBound - 1
        return day >= lastDay - 2 ? 31 : day // "31" sert de code conventionnel pour "fin de mois"
    }

    // MARK: - Date Consistency ("date identique, a quelques jours pres")

    private static func isDateConsistent(dates: [Date], frequency: RecurrenceFrequency, anchorDay: Int) -> Bool {
        let cal = Calendar.current
        let tolerance = dateTolerance(for: frequency)

        if frequency.usesDayOfMonthAnchor {
            return dates.allSatisfy { date in
                let day = normalizedMonthDay(for: date, calendar: cal)
                // Distance circulaire simplifiee : la normalisation "fin de
                // mois" (valeur 31) rend deja la comparaison directe fiable.
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

    /// Genere les echeances entre deux dates pour un motif recurrent.
    /// - Parameters:
    ///   - pattern: Motif a projeter
    ///   - startDate: Date de debut (incluse)
    ///   - endDate: Date de fin (incluse)
    /// - Returns: Toutes les dates d'echeances dans la plage
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

    /// Genere les echeances futures a partir d'un motif recurrent.
    /// - Parameters:
    ///   - pattern: Motif a projeter
    ///   - from: Date de debut de la projection
    ///   - months: Nombre de mois a projeter en avant
    /// - Returns: Dates des prochaines echeances
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
                // Trouver le prochain jour ISO de semaine specifie
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
            // "31" est le code conventionnel "fin de mois" (cf. normalizedMonthDay)
            comps.day = day >= 29 ? 31 : day
            // Gerer les mois courts (ex: 31 -> 28 en fevrier)
            if let candidate = cal.date(from: comps) {
                return candidate
            }
            // Fallback: dernier jour du mois vise
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

    /// Verifie si une transaction reelle correspond a une prevision.
    /// Utilise la fenetres de date +/-3 jours et la tolerance de montant du pattern.
    static func matchTransaction(
        _ tx: FinanceTransaction,
        toPrevision prevision: BudgetPrevision,
        pattern: RecurringPattern
    ) -> Bool {
        // Verification du montant
        let txAmt = tx.amount
        let expectedAmt = prevision.amount
        let tolerance = abs(expectedAmt) * pattern.amountTolerance
        guard abs(txAmt - expectedAmt) <= tolerance else { return false }

        // Verification de la date (+/-3 jours)
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
        // Supprimer les tokens purement numeriques (dates, references) et les caracteres parasites
        let cleaned = name
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "*", with: " ")
            .replacingOccurrences(of: "/", with: " ")

        let tokens = cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .filter { token in
                // Exclure les tokens purement numeriques (ex: "20251201", "75001")
                !token.allSatisfy({ $0.isNumber })
            }

        return tokens.prefix(4).joined(separator: "_")
    }
}
