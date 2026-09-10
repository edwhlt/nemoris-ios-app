import Foundation
import Observation

// MARK: - CoachStore
//
// The coach's observable state: what the views read, and the only place that
// triggers an analysis.
//
// Inject it ONCE into the environment (`NemorisApp`), never as a view's
// `@State` — same reason as `DashboardSnapshotStore`: the Dashboard is
// instantiated twice (iOS TabView and macOS detail column), and two `@State`
// copies would mean two analyses launched in parallel on the same domain.
//
// ─── The non-blocking contract ─────────────────────────────────────────────
//
// An analysis takes from a few seconds to a minute (reading 10,000
// transactions plus a model round trip). A view must NEVER wait on it:
//   • `refreshIfStale` and `refresh` are NOT `async` — they start a task and
//     return immediately;
//   • the `running` state is published straight away, so the UI can show
//     that something is happening;
//   • already-persisted recommendations stay on screen DURING the
//     recomputation, never replaced by an empty screen.

@MainActor
@Observable
final class CoachStore {

    /// Persisted recommendations, across all domains.
    private(set) var recommendations: [CoachRecommendation] = []
    /// Last known analysis per domain.
    private(set) var analyses: [CoachDomain: CoachAnalysis] = [:]
    /// Domains with an analysis in flight — what the UI observes to show
    /// its indicator.
    private(set) var running: Set<CoachDomain> = []
    /// The user's goals, PER DOMAIN (mirror of `coach_profile`).
    ///
    /// A single shared text made every analysis carry a goal it couldn't
    /// serve: "diversify better" has no grip on a spending briefing, and
    /// "spend less" none on a portfolio.
    private(set) var profiles: [CoachDomain: CoachProfile] = [:]

    private var hasLoaded = false

    // MARK: - Reading

    func analysis(for domain: CoachDomain) -> CoachAnalysis {
        analyses[domain] ?? .empty(domain)
    }

    func profile(for domain: CoachDomain) -> CoachProfile {
        profiles[domain] ?? .empty
    }

    func isRunning(_ domain: CoachDomain) -> Bool { running.contains(domain) }

    /// A domain's visible recommendations, ranked by priority.
    func visibleRecommendations(for domain: CoachDomain) -> [CoachRecommendation] {
        CoachRanker.visible(recommendations, domain: domain)
    }

    /// The 3 most important recommendations ACROSS ALL DOMAINS — what the
    /// Dashboard displays. The arbitration lives in `CoachRanker` (a pure
    /// engine), not here.
    func topRecommendations(limit: Int = 3) -> [CoachRecommendation] {
        CoachRanker.topAcrossDomains(recommendations, limit: limit)
    }

    // MARK: - Loading

    /// Reloads from the database. Fast (no AI), callable from every `.task`.
    func load() async {
        let loaded = await Task.detached(priority: .userInitiated) {
            (recos: CoachRepository.shared.fetchRecommendations(),
             transactions: CoachRepository.shared.fetchAnalysis(domain: .transactions),
             investments: CoachRepository.shared.fetchAnalysis(domain: .investments),
             profiles: CoachRepository.shared.fetchProfiles())
        }.value
        recommendations = loaded.recos
        analyses = [.transactions: loaded.transactions, .investments: loaded.investments]
        profiles = loaded.profiles
        hasLoaded = true
    }

    // MARK: - Analysis

    /// Re-runs IF the analysis is stale (> 7 days) and an AI is available.
    /// Non-blocking, silent when there's nothing to do.
    ///
    /// Never re-runs after an ERROR: otherwise a misconfigured backend would
    /// retry an analysis every time the screen opens, in a loop, without the
    /// user asking. After a failure it's up to them to re-run explicitly.
    func refreshIfStale(_ domain: CoachDomain, now: Date = Date()) {
        guard hasLoaded, !running.contains(domain) else { return }
        let current = analysis(for: domain)
        guard !current.isError, current.isStale(now: now) else { return }
        guard AIEnrichmentBackend.isAvailable(for: domain.aiFeature) else { return }
        start(domain, now: now)
    }

    /// On-demand re-run, whatever the state. Non-blocking.
    func refresh(_ domain: CoachDomain, now: Date = Date()) {
        guard !running.contains(domain) else { return }
        start(domain, now: now)
    }

    private func start(_ domain: CoachDomain, now: Date) {
        running.insert(domain)
        Task {
            let analysis = await CoachService.analyze(domain: domain, now: now)
            // The service rewrote the recommendations in the database:
            // re-read rather than guess the resulting state (the statuses
            // preserved from one analysis to the next are known only to the
            // database).
            let fresh = await Task.detached(priority: .userInitiated) {
                CoachRepository.shared.fetchRecommendations()
            }.value
            recommendations = fresh
            analyses[domain] = analysis
            running.remove(domain)
        }
    }

    // MARK: - Actions on a recommendation

    func setStatus(_ status: CoachRecommendationStatus, for reco: CoachRecommendation) {
        // Optimistic update: the user sees the card disappear immediately,
        // the write follows.
        if let index = recommendations.firstIndex(where: { $0.id == reco.id }) {
            recommendations[index].status = status
        }
        let id = reco.id
        Task.detached(priority: .utility) {
            CoachRepository.shared.updateStatus(id: id, status: status)
        }
    }

    // MARK: - Goals

    func saveObjectives(_ text: String, for domain: CoachDomain) {
        profiles[domain] = CoachProfile(objectives: text, updatedAt: Date())
        Task.detached(priority: .utility) {
            CoachRepository.shared.saveObjectives(text, domain: domain)
        }
    }
}
