import Foundation

// MARK: - TransactionMatcher
//
// Moteur de correspondance entre une transaction réelle et une prévision budgétaire.
//
// Stratégie de scoring (somme pondérée, résultat 0…1) :
//   • Payee ID exact           — 40 % (signal le plus fiable)
//   • Similarité du libellé    — 30 % (tokens normalisés, intersection Jaccard)
//   • Proximité de date        — 20 % (fenêtre ±7 jours, décroissance linéaire)
//   • Proximité du montant     — 10 % (tolérance paramétrée par le pattern)
//
// Seuil d'acceptation automatique : 0.60
// Seuil de suggestion manuelle    : 0.35

struct MatchCandidate {
    let prevision: BudgetPrevision
    /// Score de confiance 0…1
    let confidence: Double
    /// Explication lisible du match (debug / UI)
    let reason: String
}

enum TransactionMatcher {

    // MARK: - Public API

    static let autoAcceptThreshold: Double = 0.60
    static let suggestThreshold: Double    = 0.35

    /// Cherche la meilleure prevision correspondant a une transaction.
    /// - Parameters:
    ///   - tx: Transaction reelle a matcher.
    ///   - previsions: Previsions candidates (status == .pending).
    ///   - patterns: Patterns pour acceder a payeeId, amountTolerance, name.
    /// - Returns: Meilleur candidat si son score >= suggestThreshold, nil sinon.
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

    /// Tente de matcher automatiquement toutes les transactions contre les previsions PENDING.
    /// Retourne les paires (previsionId, transactionId) qui depassent autoAcceptThreshold.
    static func autoMatch(
        transactions: [FinanceTransaction],
        previsions: [BudgetPrevision],
        patterns: [RecurringPattern]
    ) -> [(previsionId: Int, transactionId: Int, confidence: Double)] {
        var results: [(previsionId: Int, transactionId: Int, confidence: Double)] = []
        var unmatchedPrevisions = previsions.filter { $0.status == .pending }

        // Trier les transactions par date pour un matching deterministe
        let sortedTxs = transactions.sorted { $0.date < $1.date }

        for tx in sortedTxs {
            guard let best = findBestMatch(for: tx, in: unmatchedPrevisions, patterns: patterns),
                  best.confidence >= autoAcceptThreshold else { continue }
            results.append((best.prevision.id, tx.id, best.confidence))
            // Retirer la prevision matchee pour eviter les doublons
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
        // Le montant doit etre dans le meme sens (depense/revenu)
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

        // 2. Similarite du libelle (30%)
        let txLabel   = normalizeLabel(bestLabel(tx))
        let patLabel  = normalizeLabel(pattern.name)
        let labelScore = labelSimilarity(txLabel, patLabel)
        if labelScore > 0.3 { reasons.append("libelle similaire (\(Int(labelScore * 100))%)") }

        // 3. Proximite de date (20%) — fenetre ±7 jours, lineaire
        let daysDiff = abs(Calendar.current.dateComponents([.day], from: tx.date, to: prevision.expectedDate).day ?? 999)
        let dateScore: Double = daysDiff <= 7 ? 1.0 - Double(daysDiff) / 7.0 : 0.0
        if dateScore > 0 { reasons.append("\(daysDiff)j d'ecart") }

        // 4. Proximite du montant (10%)
        let tolerance = max(pattern.amountTolerance, 0.05)
        let txAmt = abs(tx.amount)
        let prevAmt = abs(prevision.amount)
        let amtDiff = prevAmt > 0 ? abs(txAmt - prevAmt) / prevAmt : 1.0
        let amountScore: Double = amtDiff <= tolerance ? 1.0 - amtDiff / tolerance : 0.0
        if amountScore > 0 { reasons.append("montant \(String(format: "%.0f%%", (1 - amtDiff) * 100)) proche") }

        let total = payeeScore * 0.40 + labelScore * 0.30 + dateScore * 0.20 + amountScore * 0.10

        // Un match sans aucun signal fort (ni payee, ni libelle, ni date proche) n'est pas fiable
        guard payeeScore > 0 || labelScore > 0.4 || dateScore > 0.5 else { return nil }

        return MatchCandidate(
            prevision: prevision,
            confidence: min(total, 1.0),
            reason: reasons.joined(separator: ", ")
        )
    }

    // MARK: - Label Normalization

    /// Retourne le meilleur libelle disponible pour une transaction.
    static func bestLabel(_ tx: FinanceTransaction) -> String {
        if !tx.tiersName.isEmpty { return tx.tiersName }
        if let raw = tx.libelleBrut, !raw.isEmpty { return raw }
        return tx.information
    }

    /// Normalise un libelle pour la comparaison :
    ///  - minuscules
    ///  - supprime les mots bancaires parasites (SEPA, VIR, CB, PRLV, etc.)
    ///  - supprime les tokens purement numeriques
    ///  - garde les 5 premiers tokens significatifs
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
            .filter { !$0.allSatisfy(\.isNumber) }      // pas que des chiffres
            .filter { !banking.contains($0) }            // pas un mot bancaire
            .filter { $0.count >= 2 }                    // au moins 2 caracteres

        return tokens.prefix(5).joined(separator: " ")
    }

    // MARK: - Label Similarity (Jaccard sur tokens)

    /// Similarite de Jaccard entre deux libelles normalises (0…1).
    static func labelSimilarity(_ a: String, _ b: String) -> Double {
        let tokA = Set(a.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        let tokB = Set(b.components(separatedBy: .whitespaces).filter { !$0.isEmpty })
        guard !tokA.isEmpty, !tokB.isEmpty else { return 0 }

        // Jaccard exact
        let intersection = tokA.intersection(tokB)
        let union = tokA.union(tokB)
        let jaccardExact = Double(intersection.count) / Double(union.count)

        // Bonus : sous-chaine (ex: "netflix" dans "netflixcom")
        let substringBonus: Double = tokA.contains(where: { a in tokB.contains { b in
            a.contains(b) || b.contains(a)
        }}) ? 0.2 : 0.0

        return min(jaccardExact + substringBonus, 1.0)
    }
}
