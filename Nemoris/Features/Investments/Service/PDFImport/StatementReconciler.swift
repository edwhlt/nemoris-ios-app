import Foundation

// MARK: - Merging the two extractions of a statement
//
// PURE engine (no network, disk, AI or SwiftUI access) — same doctrine as
// `InvestmentStatementExtractor` and `PortfolioEvolutionBuilder`: testable
// outside Xcode via `run_statement_extractor_tests.sh`.
//
// ─── What the merge must get right ─────────────────────────────────────────
//
// The naive rule — "the deterministic extraction is authoritative on the ISINs
// it recognized, the AI fills in the rest" — fails in three ways:
//
//   1. **Quantity stuck at 1 everywhere.** On a TABLE statement, the
//      "Quantity" label appears ONCE, in the column header — not on each
//      data row. ISIN anchoring, which looks for a number AFTER a label,
//      cannot read it, and `valuation(...)` falls back to "unknown quantity ⇒
//      1 × amount". The deterministic pass LOWERS its own confidence (0.60)
//      to flag it… but keeping authority anyway discards the AI's correct
//      reading of the column.
//   2. **An inflated count**: an operation seen by the AI without an ISIN —
//      or with a miscopied ISIN — gets added WITHOUT ANY duplicate check,
//      since `knownISINs` can by construction never contain the empty string.
//   3. **"No AI used" shown to the user**: every returned row comes from the
//      deterministic pass, note included, even though the model ran and
//      produced better numbers.
//
// Hence the rule: the deterministic pass stays the backbone (it never gets an
// ISIN or a date wrong), but **it yields its numbers as soon as it admits
// doubt itself**, and a row is added only if it matches no already-known
// operation.

/// Minimal view of an operation, independent of the model carrying it.
///
/// A protocol, not the concrete type: the merge must apply both to
/// `ExtractedStatementOrder` (pure engine, date as a string) and to
/// `PDFExtractedOrder` (UI model, date as `Date`, identity and selection).
/// Writing the rule twice, once per model, is exactly how two
/// implementations of the same computation end up diverging.
protocol StatementOrderFields {
    var orderType: String { get }
    var assetName: String { get }
    var isin: String { get }
    var ticker: String { get set }
    var quantity: Double { get set }
    var unitPrice: Double { get set }
    var fees: Double { get set }
    var confidence: Double { get set }
    var notes: String? { get set }
    /// Execution date normalized as yyyy-MM-dd.
    var isoDay: String { get }
}

extension ExtractedStatementOrder: StatementOrderFields {
    var isoDay: String { executedAt }
}

enum StatementReconciler {

    /// Below this confidence, a deterministic operation DEDUCED at least one of
    /// its numbers instead of reading it (`InvestmentStatementExtractor.
    /// parseBlock`: -0.15 when the quantity is missing, -0.1 when the valuation
    /// is deduced). Chosen so a perfectly read operation (0.85) is never
    /// rewritten, and a doubtful one always is.
    static let uncertainConfidence = 0.75

    /// Marker carried by an operation whose numbers come from the model. Visible
    /// on the order sheet after import — without it, nothing tells a reinforced
    /// reading from a first-pass one afterwards.
    static let textTag = "Quantité/prix relus par l'IA"
    static let imageTag = "Quantité/prix relus sur l'image (tableau)"

    // MARK: - Full merge

    /// Deterministic backbone reinforced by the AI, PLUS the operations only the
    /// AI saw (prose formats, rows without an ISIN — which anchoring cannot see
    /// by construction).
    static func reconcile<T: StatementOrderFields>(ai: [T], deterministic: [T],
                                                   tag: String = textTag) -> [T] {
        let candidates = dedupe(ai)
        guard !deterministic.isEmpty else { return candidates }

        var consumed = Set<Int>()
        var result = deterministic
        for index in result.indices {
            guard let match = matchIndex(for: result[index], in: candidates, excluding: consumed)
            else { continue }
            consumed.insert(match)
            result[index] = merging(result[index], with: candidates[match], tag: tag)
        }
        // An AI operation is added only if it matches NO operation already kept:
        // otherwise a row without an ISIN always slips through, inflating the count,
        // and differently on each analysis since the model doesn't miss the same
        // rows every time.
        for (index, candidate) in candidates.enumerated() where !consumed.contains(index) {
            result.append(candidate)
        }
        return result
    }

    // MARK: - Merging a pair

    /// Applies a candidate operation onto a base operation.
    ///
    /// The ticker is ALWAYS taken when missing (the deterministic pass doesn't
    /// look for it: it has no normalized form). The NUMBERS are taken only if the
    /// base admits doubt — date, name, type and ISIN stay with the base, which
    /// never gets them wrong.
    private static func merging<T: StatementOrderFields>(_ base: T, with candidate: T,
                                                          tag: String) -> T {
        var merged = base
        if merged.ticker.isEmpty { merged.ticker = candidate.ticker }
        guard base.confidence < uncertainConfidence, candidate.quantity > 0 else { return merged }

        // The AMOUNT read by the deterministic pass wins over the price returned by
        // the model when the two contradict each other. An amount is extracted by a
        // pattern that requires cents or an attached currency (see `signedAmount`):
        // it's a number really present in the document. A model readily copies the
        // TOTAL into the "unit price" field — without this guard, a €982.40
        // operation would become 4 × 982.40 = €3,929.60.
        let gross = abs(base.quantity * base.unitPrice)
        var price: Double? = candidate.unitPrice > 0 ? candidate.unitPrice : nil
        if gross > 0, let proposed = price,
           abs(proposed * candidate.quantity - gross) > max(0.05, gross * 0.05) {
            price = nil   // the price will be re-derived from the amount actually read
        }

        let valued = InvestmentStatementExtractor.valuation(
            orderType: base.orderType, quantity: candidate.quantity,
            unitPrice: price, gross: gross > 0 ? gross : nil)

        merged.quantity = valued.quantity
        merged.unitPrice = valued.unitPrice

        // A model sometimes confuses "Commission" with "Gross amount" in a footer
        // with several adjacent money columns (Gross amount | Commission | Fees |
        // Net amount) — returned fees equal to EXACTLY the gross amount double the
        // displayed total (`totalCost = quantity × price + fees`). A plausible
        // commission stays a SMALL fraction of the operation's amount; beyond that,
        // another column was probably read. Same doctrine as the `price` guard above.
        let trueGross = abs(valued.quantity * valued.unitPrice)
        let feesArePlausible = trueGross == 0 || candidate.fees < trueGross * 0.5
        if merged.fees == 0, candidate.fees > 0, feesArePlausible {
            merged.fees = candidate.fees
        }
        merged.confidence = max(base.confidence, uncertainConfidence)
        merged.notes = appending(tag, to: base.notes)
        return merged
    }

    private static func appending(_ tag: String, to notes: String?) -> String {
        guard let notes, !notes.isEmpty else { return tag }
        guard !notes.contains(tag) else { return notes }
        return notes + " · " + tag
    }

    // MARK: - "Is it the same operation?"

    /// A single notion of identity, shared by reinforcement AND deduplication:
    /// two different answers to this question would correct a row and then add
    /// it again as a duplicate.
    static func isSameOperation<T: StatementOrderFields>(_ a: T, _ b: T) -> Bool {
        let isinA = a.isin.uppercased(), isinB = b.isin.uppercased()
        if !isinA.isEmpty, !isinB.isEmpty {
            // Same ISIN: the day OR the amount is enough to confirm. The "or" matters —
            // some statements date the operation, the model sometimes returns the
            // settlement date.
            guard isinA == isinB else { return false }
            return a.isoDay == b.isoDay || closeAmounts(a, b)
        }
        // Without a comparable ISIN, the day becomes mandatory: it's the only field
        // discriminating enough not to merge two distinct operations on the same
        // security.
        guard a.isoDay == b.isoDay, !a.isoDay.isEmpty else { return false }
        return closeAmounts(a, b) || similarNames(a.assetName, b.assetName)
    }

    private static func closeAmounts<T: StatementOrderFields>(_ a: T, _ b: T) -> Bool {
        let totalA = abs(a.quantity * a.unitPrice)
        let totalB = abs(b.quantity * b.unitPrice)
        guard totalA > 0, totalB > 0 else { return false }
        return abs(totalA - totalB) <= max(0.02, max(totalA, totalB) * 0.01)
    }

    /// "Close enough" names: a statement writes "AM.PEA EM.ES.T.ACC" where a model
    /// returns "Epargne PEA Emerging Markets". So equality isn't required, only
    /// the inclusion of one normalized form in the other.
    private static func similarNames(_ a: String, _ b: String) -> Bool {
        let normalizedA = normalize(a), normalizedB = normalize(b)
        guard normalizedA.count >= 5, normalizedB.count >= 5 else { return false }
        return normalizedA.contains(normalizedB) || normalizedB.contains(normalizedA)
    }

    private static func normalize(_ name: String) -> String {
        String(name.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }

    private static func matchIndex<T: StatementOrderFields>(for order: T, in pool: [T],
                                                            excluding consumed: Set<Int>) -> Int? {
        // ONE-TO-ONE matching: two purchases of the same security on the same day
        // are two real operations, each with its own ISIN anchor on the
        // deterministic side. Without excluding candidates already consumed, both
        // would point at the same AI row — the second would stay uncorrected and
        // the leftover row would come back as a duplicate.
        //
        // Two passes, and the order matters. When several candidates fit (same
        // security, same day, two different amounts), the one whose AMOUNT matches
        // is the right one; settling for the first one found would pair the two
        // operations the wrong way round and swap their quantities.
        if let strong = pool.indices.first(where: {
            !consumed.contains($0) && isSameOperation(order, pool[$0]) && closeAmounts(order, pool[$0])
        }) { return strong }
        return pool.indices.first {
            !consumed.contains($0) && isSameOperation(order, pool[$0])
        }
    }

    // MARK: - Internal deduplication

    /// Removes repetitions within a single source. A model sometimes repeats the
    /// same operation at the end of a long list, and two consecutive text blocks
    /// can overlap.
    ///
    /// STRICT predicate, not `isSameOperation`. The latter is meant to match two
    /// READINGS of the same operation, hence deliberately tolerant (it accepts an
    /// identical day without a comparable amount). Applied within one source, it
    /// would merge two real purchases of the same security made the same day at
    /// different prices.
    static func dedupe<T: StatementOrderFields>(_ orders: [T]) -> [T] {
        var kept: [T] = []
        for order in orders where !kept.contains(where: { isRepetition($0, order) }) {
            kept.append(order)
        }
        return kept
    }

    private static func isRepetition<T: StatementOrderFields>(_ a: T, _ b: T) -> Bool {
        guard a.isoDay == b.isoDay, a.orderType == b.orderType else { return false }
        let sameTitle = (!a.isin.isEmpty && a.isin.uppercased() == b.isin.uppercased())
            || similarNames(a.assetName, b.assetName)
        guard sameTitle else { return false }
        // Two zero amounts on both sides: nothing tells them apart either.
        let totalA = abs(a.quantity * a.unitPrice), totalB = abs(b.quantity * b.unitPrice)
        return closeAmounts(a, b) || (totalA == 0 && totalB == 0)
    }
}
