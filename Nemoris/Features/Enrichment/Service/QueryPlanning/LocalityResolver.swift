import Foundation

// Contract for resolving a locality.
// ⚠️ PURE FILE: `import Foundation` ONLY.
//
// Why the planner receives an ALREADY RESOLVED locality rather than a resolver:
//
// `MerchantQueryPlanner.extract` and `.plan` must stay total pure functions,
// testable with no mock and no protocol stub. If the plan carried a locality a
// resolver later filled in, `attempts` — precisely what the tests need to
// assert — would only exist after a network round trip, and the plan would become a
// two-stage mutable object whose cascade order would only be observable through
// a network stub. That's exactly the untestable shape we're avoiding.
//
// The call order is therefore, on the executor's side: extract → resolve → plan → execute.
// One direction, no cycles.
protocol LocalityResolver: Sendable {
    /// Resolves the first recognizable fragment among `tokens`.
    /// Returns nil if none is a known commune — that is NOT a failure:
    /// the fragment is still used as sort text against candidates' addresses.
    func resolve(_ tokens: [LocalityToken], countryHint: String?) async -> ResolvedLocality?
}
