import Foundation

// MARK: - RecurringDetector
//
// Analyse l'historique des transactions pour detecter automatiquement
// les depenses et revenus recurrents (abonnements, loyer, salaire, etc.)
//
// Algorithme :
//  1. Grouper les transactions par payee_id (ou nom normalise si pas de payee)
//  2. Pour chaque groupe de >= 2 transactions, calculer l'ecart median entre occurrences
//  3. Classifier la frequence (daily / weekly / monthly / yearly) selon cet ecart
//  4. Verifier la coherence des montants (ecart-type / moyenne < tolerance)
//  5. Retourner les candidats tries par confiance decroissante

struct DetectionCandidate {
    let name: String
    let payeeId: Int?
    let categoryId: Int?
    let amountAvg: Double
    let amountStdDev: Double
    let frequency: RecurrenceFrequency
    let anchorDay: Int?
    let occurrences: [Date]
    /// Score de confiance 0…1
    let confidence: Double
}

enum RecurringDetector {

    // MARK: - Public API

    /// Detecte les motifs recurrents dans un tableau de transactions.
    /// - Parameter transactions: Toutes les transactions disponibles (tri non requis).
    /// - Returns: Candidats tries par confiance decroissante.
    static func detect(from transactions: [FinanceTransaction]) -> [DetectionCandidate] {
        // Grouper par payee_id puis par nom normalise
        let groups = groupTransactions(transactions)

        var candidates: [DetectionCandidate] = []
        for (_, txs) in groups {
            guard txs.count >= 2 else { continue }

            // Sous-grouper par montant similaire (meme tiers, montants proches = probablement le meme abonnement)
            let subGroups = subGroupByAmount(txs)
            for subGroup in subGroups {
                guard subGroup.count >= 2 else { continue }
                if let candidate = analyzeGroup(subGroup) {
                    candidates.append(candidate)
                }
            }
        }

        // Trier par confiance decroissante, puis par montant absolu
        return candidates
            .filter { $0.confidence >= 0.30 }   // Seuil abaisse : 0.30 au lieu de 0.50
            .sorted {
                if abs($0.confidence - $1.confidence) > 0.05 {
                    return $0.confidence > $1.confidence
                }
                return abs($0.amountAvg) > abs($1.amountAvg)
            }
    }

    // MARK: - Sub-grouping by amount cluster
    //
    // Regroupe les transactions d'un meme tiers par montant similaire (tolerance ±15%).
    // Exemple : un tiers qui facture 9,99 € et 14,99 € donne deux sous-groupes distincts.

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
                if diff < 0.15 {
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

        // Calculer les ecarts entre occurrences consecutives (en jours)
        let gaps = zip(dates, dates.dropFirst()).map { earlier, later in
            Calendar.current.dateComponents([.day], from: earlier, to: later).day ?? 0
        }
        guard !gaps.isEmpty else { return nil }

        let medianGap = median(gaps.map(Double.init))

        // Classifier la frequence
        guard let frequency = classifyFrequency(medianGap) else { return nil }

        // Verifier la coherence des montants
        let avgAmount = amounts.reduce(0, +) / Double(amounts.count)
        let stdDev = standardDeviation(amounts)
        let relativeStdDev = abs(avgAmount) > 0 ? stdDev / abs(avgAmount) : 1.0

        // Tolerance elargie : jusqu'a 50% de variation (factures variables, prix qui evoluent)
        guard relativeStdDev < 0.50 else { return nil }

        // Calcul de la confiance
        let freqConfidence = frequencyConfidence(medianGap: medianGap, frequency: frequency)

        // Bonus montant fixe : si tous les montants sont identiques (abonnement), confiance maximale
        let isFixedAmount = relativeStdDev < 0.02
        let amountConfidence: Double = isFixedAmount ? 1.0 : max(0, 1.0 - relativeStdDev / 0.50)

        // Bonus occurrences : +5% par occurrence supplementaire (au-dela de 2), cap a 25%
        let countBonus = min(Double(sorted.count - 2) * 0.05, 0.25)

        // Poids : frequence 45%, montant 40%, occurrences 15%
        let confidence = freqConfidence * 0.45 + amountConfidence * 0.40 + countBonus

        // Calculer le jour d'ancrage
        let anchorDay = computeAnchorDay(dates: dates, frequency: frequency)

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
            confidence: min(confidence, 1.0)
        )
    }

    // MARK: - Frequency Classification

    private static func classifyFrequency(_ medianGap: Double) -> RecurrenceFrequency? {
        switch medianGap {
        case 0..<3:       return .daily
        case 3..<14:      return .weekly
        case 14..<50:     return .monthly        // mensuel
        case 50..<100:    return .monthly        // bimestriel → traite comme mensuel avec gap
        case 100..<200:   return .monthly        // trimestriel → traite comme mensuel avec gap
        case 200..<400:   return .yearly
        default:          return nil
        }
    }

    private static func frequencyConfidence(medianGap: Double, frequency: RecurrenceFrequency) -> Double {
        let target = Double(frequency.approximateDays)
        let deviation = abs(medianGap - target) / target
        return max(0, 1.0 - deviation * 2)
    }

    // MARK: - Anchor Day

    private static func computeAnchorDay(dates: [Date], frequency: RecurrenceFrequency) -> Int? {
        switch frequency {
        case .monthly:
            // Jour du mois le plus frequent
            let days = dates.compactMap { Calendar.current.dateComponents([.day], from: $0).day }
            return mostFrequent(days)
        case .weekly:
            // Jour de la semaine ISO le plus frequent
            let weekdays = dates.compactMap { Calendar.current.dateComponents([.weekday], from: $0).weekday }
            // Convertir de Sunday=1 a ISO Monday=1
            let isoWeekdays = weekdays.map { ($0 + 5) % 7 + 1 }
            return mostFrequent(isoWeekdays)
        case .yearly:
            // Mois de l'annee le plus frequent
            let months = dates.compactMap { Calendar.current.dateComponents([.month], from: $0).month }
            return mostFrequent(months)
        case .daily:
            return nil
        }
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

        case .weekly:
            if let anchor = pattern.anchorDay {
                // Trouver le prochain jour ISO de semaine specifie
                var next = cal.date(byAdding: .day, value: 1, to: date)!
                for _ in 0..<8 {
                    let weekday = cal.dateComponents([.weekday], from: next).weekday ?? 1
                    let iso = (weekday + 5) % 7 + 1
                    if iso == anchor { return next }
                    next = cal.date(byAdding: .day, value: 1, to: next)!
                }
                return cal.date(byAdding: .day, value: 7, to: date)
            }
            return cal.date(byAdding: .day, value: 7, to: date)

        case .monthly:
            let day = pattern.anchorDay ?? 1
            var comps = cal.dateComponents([.year, .month], from: date)
            comps.month = (comps.month ?? 1) + 1
            comps.day = day
            // Gerer les mois courts (ex: 31 -> 28 en fevrier)
            if let candidate = cal.date(from: comps) {
                return candidate
            }
            // Fallback: dernier jour du mois suivant
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

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

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
