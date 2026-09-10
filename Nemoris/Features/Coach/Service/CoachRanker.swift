import Foundation

// MARK: - CoachRanker — arbitrating between recommendations
//
// PURE engine (`import Foundation` only): no database, network, AI or
// SwiftUI access. Same doctrine as `PortfolioEvolutionBuilder` /
// `EnvelopeSpendingCalculator` — the priority rule must be testable without a
// model or a device, and above all IDENTICAL everywhere the app ranks
// recommendations (Dashboard top 3, a domain's list, future consumers).
//
// The arbitration is DETERMINISTIC, not a third call to the model. Asking an
// AI to rank what an AI just produced would cost one more round trip,
// wouldn't be reproducible from one display to the next, and above all
// couldn't be tested. The model supplies the SIGNALS (impact, effort,
// confidence); the weighting stays here.

enum CoachRanker {

    // MARK: - Score

    /// Annual amount at which impact saturates to 1.0. Beyond it, effort
    /// and confidence break the tie: between "€4,000/yr" and "€12,000/yr",
    /// both are already "huge", and letting the amount grow unbounded would
    /// crush the rest of the ranking.
    static let impactCeiling: Double = 3_000

    /// Score given to a NON-QUANTIFIABLE recommendation (impact 0).
    ///
    /// Cannot be 0. `Insight.compositeScore` multiplied the three
    /// dimensions, so any insight with zero impact mechanically fell to zero
    /// and NEVER surfaced — even though "you're at 70% on a single holding"
    /// is exactly the kind of structural advice a consultant leads with. A
    /// median value lets it compete on its confidence and feasibility.
    static let unquantifiedImpactScore: Double = 0.35

    /// Impact normalized 0-1, on a LOGARITHMIC scale: the useful gap
    /// between €20/yr and €200/yr is far larger than the one between €2,000
    /// and €2,180, which a linear scale doesn't convey.
    static func impactScore(_ annualImpact: Double) -> Double {
        guard annualImpact > 0 else { return unquantifiedImpactScore }
        let ratio = log10(1 + annualImpact) / log10(1 + impactCeiling)
        return min(1, max(0, ratio))
    }

    /// A recommendation's 0-1 priority, all dimensions combined.
    ///
    /// Weighting: impact 50%, confidence 30%, feasibility 20%. Confidence
    /// weighs more than feasibility because a recommendation the model only
    /// half believes in must not rise just because it's easy to apply.
    static func score(_ reco: CoachRecommendation) -> Double {
        let impact = impactScore(reco.annualImpact)
        let effort = Double(min(5, max(1, reco.effort))) / 5.0
        let confidence = min(1, max(0, reco.confidence))
        return impact * 0.5 + confidence * 0.3 + effort * 0.2
    }

    // MARK: - Ranking

    /// Sorts by decreasing priority. STABLE tie-breaking on equality
    /// (impact then `ref`): without it, two successive displays of the same
    /// list could swap two cards, which makes the screen look like it
    /// "moves on its own".
    static func ranked(_ recos: [CoachRecommendation]) -> [CoachRecommendation] {
        recos.sorted { a, b in
            let sa = score(a), sb = score(b)
            if abs(sa - sb) > 0.0001 { return sa > sb }
            if abs(a.annualImpact - b.annualImpact) > 0.01 { return a.annualImpact > b.annualImpact }
            return a.ref < b.ref
        }
    }

    /// The `limit` most important recommendations ACROSS ALL DOMAINS —
    /// what the Dashboard displays.
    ///
    /// Dismissed or completed recommendations are filtered out HERE, not in
    /// the view: the Dashboard and a domain's list must filter identically,
    /// otherwise a "done" card reappears on one screen and not the other.
    static func topAcrossDomains(_ recos: [CoachRecommendation], limit: Int = 3) -> [CoachRecommendation] {
        guard limit > 0 else { return [] }
        return Array(ranked(recos.filter { $0.status.isVisible }).prefix(limit))
    }

    /// A domain's visible recommendations, ranked.
    static func visible(_ recos: [CoachRecommendation], domain: CoachDomain) -> [CoachRecommendation] {
        ranked(recos.filter { $0.domain == domain && $0.status.isVisible })
    }

    // MARK: - Clamping the values returned by the model

    /// Brings the model's three self-assessed signals back within bounds.
    ///
    /// Indispensable: a model happily returns `effort: 12`, a confidence of
    /// `95` (instead of 0.95) or a negative impact. Without normalization,
    /// those values contaminate the ranking directly.
    static func normalize(annualImpact: Double, effort: Int, confidence: Double)
        -> (annualImpact: Double, effort: Int, confidence: Double) {
        let impact = annualImpact.isFinite && annualImpact > 0 ? annualImpact : 0
        let boundedEffort = min(5, max(1, effort))
        // A model answering "85" means "85%": recover it rather than
        // clamping everything to 1.0, which would make the dimension
        // useless.
        var conf = confidence.isFinite ? confidence : 0.5
        if conf > 1 { conf = conf / 100 }
        return (impact, boundedEffort, min(1, max(0, conf)))
    }
}
