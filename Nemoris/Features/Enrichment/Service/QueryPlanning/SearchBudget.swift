import Foundation

// Budget for a merchant search.
// ⚠️ PURE FILE: `import Foundation` ONLY.
//
// The budget is DATA, not a policy scattered through the executor. Useful
// consequence: `plan.attempts.count <= budget.maxAttempts` is a pure test
// assertion — a search's cost is auditable with no execution at all, no network involved.

struct SearchBudget: Hashable, Sendable {
    /// Hard cap on network calls. The executor decrements it and stops.
    var maxRequests: Int
    /// Cap on planned attempts (`plan.attempts.count`).
    var maxAttempts: Int
    /// Global wall-clock delay, in seconds.
    var deadline: TimeInterval
    /// Allows a call to the language model to refine the plan.
    var allowLLM: Bool
    /// Allows map searches.
    var allowPlaces: Bool
    /// Allows the final replay including closed companies.
    var includeCeased: Bool
    /// `limite_matching_etablissements` of registry requests.
    var matchingLimit: Int

    /// Bulk import: each label pays its cost N times. No AI (2 to 5s per
    /// label would make it unusable on 300 rows), no map search, a single
    /// registry request after commune resolution (itself almost always cached).
    static let batch = SearchBudget(
        maxRequests: 2, maxAttempts: 2, deadline: 2.0,
        allowLLM: false, allowPlaces: false, includeCeased: false, matchingLimit: 10
    )

    /// The user is watching the screen and waiting: we can spend more.
    static let interactive = SearchBudget(
        maxRequests: 6, maxAttempts: 6, deadline: 6.0,
        allowLLM: true, allowPlaces: true, includeCeased: true, matchingLimit: 20
    )

    /// "Deep search", triggered explicitly on a specific row.
    static let deep = SearchBudget(
        maxRequests: 10, maxAttempts: 8, deadline: 15.0,
        allowLLM: true, allowPlaces: true, includeCeased: true, matchingLimit: 100
    )

    /// Observed usage, surfaced to the UI ("18 requests · 42 labels · 3.4s").
    /// Perf you can see is perf you can trust.
    struct Usage: Hashable, Sendable {
        var requests: Int = 0
        var cacheHits: Int = 0
        var elapsed: TimeInterval = 0

        var totalLookups: Int { requests + cacheHits }
    }
}
