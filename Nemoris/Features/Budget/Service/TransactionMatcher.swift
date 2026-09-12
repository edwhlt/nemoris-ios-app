import Foundation

// MARK: - TransactionMatcher
//
// Engine that matches a real transaction against a budget prevision.
//
// Scoring strategy (a weighted sum, result 0…1):
//   • Exact payee ID           — 40% (the most reliable signal)
//   • Label similarity         — 30% (normalized tokens, Jaccard intersection)
//   • Date proximity           — 20% (±7-day window, linear decay)
//   • Amount proximity         — 10% (tolerance set by the pattern)
//
// Automatic acceptance threshold: 0.60
// Manual suggestion threshold:    0.35

struct MatchCandidate {
    let prevision: BudgetPrevision
    /// Score de confiance 0…1
    let confidence: Double
    /// A readable explanation of the match (debug / UI)
    let reason: String
}

enum TransactionMatcher {

    // MARK: - Public API

    static let autoAcceptThreshold: Double = 0.60
    static let suggestThreshold: Double    = 0.35

    /// Looks for the best prevision matching a transaction.
    /// - Parameters:
    ///   - tx: The real transaction to match.
    ///   - previsions: Candidate previsions (status == .pending).
    ///   - patterns: Patterns, to access payeeId, amountTolerance, name.
    /// - Returns: The best candidate if its score >= suggestThreshold, nil otherwise.
    static func findBestMatch(
        for tx: FinanceTransaction,
        in previsions: [BudgetPrevision],
        patterns: [RecurringPattern]
    ) -> MatchCandidate? {
        let candidates = previsions.compactMap { prev -> MatchCandidate? in
            guard let pattern = patterns.first(where: { $0.id == prev.recurringPatternId }) else {
                return nil
            }
            return score(tx: tx, prevision: prev, pattern: pattern)
        }
        return candidates
            .filter { $0.confidence >= suggestThreshold }
            .max(by: { $0.confidence < $1.confidence })
    }

    /// Tries to automatically match every transaction against PENDING previsions.
    /// Returns the (previsionId, transactionId) pairs exceeding autoAcceptThreshold.
    static func autoMatch(
        transactions: [FinanceTransaction],
        previsions: [BudgetPrevision],
        patterns: [RecurringPattern]
    ) -> [(previsionId: Int, transactionId: Int, confidence: Double)] {
        var results: [(previsionId: Int, transactionId: Int, confidence: Double)] = []
        var unmatchedPrevisions = previsions.filter { $0.status == .pending }

        // Sort transactions by date for deterministic matching
        let sortedTxs = transactions.sorted { $0.date < $1.date }

        for tx in sortedTxs {
            guard let best = findBestMatch(for: tx, in: unmatchedPrevisions, patterns: patterns),
                  best.confidence >= autoAcceptThreshold else { continue }
            results.append((best.prevision.id, tx.id, best.confidence))
            // Remove the matched prevision to avoid duplicates
            unmatchedPrevisions.removeAll { $0.id == best.prevision.id }
        }
        return results
    }

    // MARK: - Scoring

    static func score(
        tx: FinanceTransaction,
        prevision: BudgetPrevision,
        pattern: RecurringPattern
    ) -> MatchCandidate? {
        // The amount must be in the same direction (expense/income)
        guard tx.amount.sign == prevision.amount.sign else { return nil }

        var reasons: [String] = []

        // 1. Payee ID exact (40%)
        let payeeScore: Double
        if let txPayee = tx.tiersId, let patPayee = pattern.payeeId, txPayee == patPayee {
            payeeScore = 1.0
            reasons.append("tiers exact")
        } else {
            payeeScore = 0.0
        }

        // 2. Label similarity (30%)
        let txLabel   = normalizeLabel(bestLabel(tx))
        let patLabel  = normalizeLabel(pattern.name)
        let labelScore = labelSimilarity(txLabel, patLabel)
        if labelScore > 0.3 { reasons.append("libelle similaire (\(Int(labelScore * 100))%)") }

        // 3. Proximite de date (20%) — fenetre ±7 jours, lineaire
        let daysDiff = abs(Calendar.current.dateComponents([.day], from: tx.date, to: prevision.expectedDate).day ?? 999)
        let dateScore: Double = daysDiff <= 7 ? 1.0 - Double(daysDiff) / 7.0 : 0.0
        if dateScore > 0 { reasons.append("\(daysDiff)j d'ecart") }

        // 4. Amount proximity (10%)
        let tolerance = max(pattern.amountTolerance, 0.05)
        let txAmt = abs(tx.amount)
        let prevAmt = abs(prevision.amount)
        let amtDiff = prevAmt > 0 ? abs(txAmt - prevAmt) / prevAmt : 1.0
        let amountScore: Double = amtDiff <= tolerance ? 1.0 - amtDiff / tolerance : 0.0
        if amountScore > 0 { reasons.append("montant \(String(format: "%.0f%%", (1 - amtDiff) * 100)) proche") }

        let total = payeeScore * 0.40 + labelScore * 0.30 + dateScore * 0.20 + amountScore * 0.10

        // A match with no strong signal at all (no payee, no label, no close date) isn't reliable
        guard payeeScore > 0 || labelScore > 0.4 || dateScore > 0.5 else { return nil }

        return MatchCandidate(
            prevision: prevision,
            confidence: min(total, 1.0),
            reason: reasons.joined(separator: ", ")
        )
    }

    // MARK: - Label Normalization

    /// Returns the best available label for a transaction.
    static func bestLabel(_ tx: FinanceTransaction) -> String {
        if !tx.tiersName.isEmpty { return tx.tiersName }
        if let raw = tx.libelleBrut, !raw.isEmpty { return raw }
        return tx.information
    }

    /// Normalizes a label for comparison:
    ///  - lowercase
    ///  - removes stray bank words (SEPA, VIR, CB, PRLV, etc.)
    ///  - removes purely numeric tokens
    ///  - keeps the first 5 significant tokens
    static func normalizeLabel(_ s: String) -> String {
        let banking: Set<String> = [
            "sepa", "vir", "virement", "prlv", "prelevement", "cb", "carte",
            "paiement", "payment", "facture", "invoice", "debit", "credit",
            "eur", "euro", "fra", "fr", "www", "com", "net", "org"
        ]
        let cleaned = s.lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "*", with: " ")
            .replacingOccurrences(of: "/", with: " ")

        let tokens = cleaned
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .filter { !$0.allSatisfy(\.isNumber) }      // not just digits
            .filter { !banking.contains($0) }            // pas un mot bancaire
            .filter { $0.count >= 2 }                    // at least 2 characters

        return tokens.prefix(5).joined(separator: " ")
    }

    // MARK: - Label Similarity (Jaccard over tokens)

    /// Jaccard similarity between two normalized labels (0…1).
    static func labelSimilarity(_ a: String, _ b: String) -> Double {
        let tokA = Set(a.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        let tokB = Set(b.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        guard !tokA.isEmpty, !tokB.isEmpty else { return 0 }

        // Jaccard exact
        let intersection = tokA.intersection(tokB)
        let union = tokA.union(tokB)
        let jaccardExact = Double(intersection.count) / Double(union.count)

        // Bonus: substring (e.g. "netflix" inside "netflixcom")
        let substringBonus: Double = tokA.contains(where: { a in tokB.contains { b in
            a.contains(b) || b.contains(a)
        }}) ? 0.2 : 0.0

        return min(jaccardExact + substringBonus, 1.0)
    }
}
