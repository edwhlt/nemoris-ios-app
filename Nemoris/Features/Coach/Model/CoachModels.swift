import Foundation

// MARK: - Coach models
//
// The coach is a CONSULTANT, not a threshold detector: it receives a dense
// briefing on the user's situation (see `CoachBriefingBuilder` /
// `InvestmentBriefingBuilder`) plus the goals they wrote, and returns a
// diagnosis and an UNCAPPED number of recommendations.
//
// What it supersedes: `InsightEngine`, 5 fixed-threshold detectors whose
// text was entirely hard-coded. It isn't removed for all that — it becomes
// (1) a provider of SIGNALS injected into the briefing and (2) the fallback
// when no AI is available, like every AI feature in this app.

/// The context budget allotted to the briefing and the instructions, based
/// on the backend ACTUALLY resolved for the feature — never the user's raw
/// preference: what matters is what the model will really receive.
///
/// Apple Intelligence (`LanguageModelSession`) exposes NO context-size
/// parameter: the window is FIXED (on the order of 4,000 tokens, input and
/// output combined) and a response that exceeds it fails rather than being
/// cleanly truncated — `.compact` is calibrated for that ceiling, with no
/// room to negotiate from the app side (see `CoachBriefingBuilder`,
/// `CoachPrompt`).
///
/// A local server or a cloud provider has a much wider context (often
/// 8k-128k+, and `AIFeature.maxOutputTokens` already grants them 8,192
/// OUTPUT tokens). Holding them to Apple Intelligence's ceilings wastes that
/// headroom: the briefing gets truncated earlier than it needs to, and the
/// profile is cut to 2 sentences even when the model has ample room to
/// elaborate.
enum CoachContextBudget: Sendable, Equatable {
    /// Apple Intelligence — fixed window, not configurable.
    case compact
    /// Local server or cloud provider — much wider context.
    case generous

    /// Should the analysis be replayed in short passes?
    ///
    /// The trigger is NOT "it failed" but "the server just showed its real
    /// limit": a reasoning model that returns truncated deliberation and
    /// zero answer says exactly one thing — the input it was given leaves it
    /// no room to conclude. This can't be predicted in advance, since the
    /// same model succeeds comfortably on another machine; it's learned on
    /// the first call, and the analysis is replayed split up.
    ///
    /// One retry only: if the short passes fail too, input size is no longer
    /// the problem, and looping would just make the user wait.
    static func shouldRetryInPasses(budget: CoachContextBudget,
                                    sawReasoningOnly: Bool,
                                    producedRecommendations: Bool,
                                    alreadyRetried: Bool) -> Bool {
        budget == .generous && sawReasoningOnly && !producedRecommendations && !alreadyRetried
    }

    /// From the RESOLVED backend (never `.automatic`, which is only a raw
    /// preference). `nil`/`.automatic`/`.off` fall back to `.compact` as a
    /// cautious default, but those cases should never reach a real model
    /// call — `AIBackendResolver.resolve` never returns them as-is.
    static func resolved(from backend: AIBackendChoice?) -> CoachContextBudget {
        switch backend {
        case .localServer, .cloud: return .generous
        // The embedded model runs with the `LlamaConfig.maxTokenCount` set by
        // `EmbeddedModelManager` (4,096, same as Apple Intelligence) — same
        // cautious budget, for the same reason: small GGUF, limited context.
        case .foundationModels, .embeddedModel, .automatic, .off, nil: return .compact
        }
    }
}

/// One named block of the briefing — the unit that pass splitting hands out
/// across several calls when the model can't read everything at once (see
/// `CoachPassPlanner`).
struct CoachBriefingSection: Sendable, Equatable {
    /// Stable identifier, for tests and diagnostics.
    let id: String
    /// Readable name, announced to the model ("you are looking at: …").
    let title: String
    /// The block as it goes to the model, header included.
    let body: String
}

/// One analysis pass: what is sent to the model in ONE go.
///
/// A single pass for a backend that swallows the whole briefing; several for
/// a narrow context window — the briefing is then split, and each pass's
/// recommendations are merged afterwards. This is the "map" half of a
/// map-reduce: the "reduce" is DETERMINISTIC (deduplication by `ref` plus
/// `CoachRanker`), not a third model call.
struct CoachAnalysisPass: Sendable, Equatable {
    /// 1-based, so it can be announced to the model ("pass 2 of 3").
    let index: Int
    let total: Int
    /// The sections examined in this pass, to frame the model.
    let focus: String
    /// The text sent: key figures + sections + goals.
    let body: String

    var isOnly: Bool { total <= 1 }
}

/// The two areas of expertise. Each has its own configurable AI backend:
/// the analysis is heavy and occasional, so one may want a cloud model here
/// and Apple Intelligence for the rest of the app.
enum CoachDomain: String, CaseIterable, Identifiable, Sendable {
    case transactions
    case investments

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transactions: return "Coach dépenses"
        case .investments:  return "Coach investissement"
        }
    }

    var icon: String {
        switch self {
        case .transactions: return "lightbulb"
        case .investments:  return "chart.line.uptrend.xyaxis"
        }
    }

    /// The matching AI feature (per-domain backend setting).
    ///
    /// `.insights` keeps its historical `rawValue`: it's the key under which
    /// the user's backend choice is already persisted (`ai.backend.insights`).
    /// Renaming it would silently lose their setting.
    var aiFeature: AIFeature {
        switch self {
        case .transactions: return .insights
        case .investments:  return .investmentCoach
        }
    }
}

/// A recommendation's lifecycle, PRESERVED from one analysis to the next
/// thanks to the stable `ref` key: dismissing a recommendation keeps it
/// dismissed even if the model proposes it again the following week.
enum CoachRecommendationStatus: String, Sendable {
    case new
    case seen
    case done
    case dismissed

    var isVisible: Bool { self == .new || self == .seen }
}

struct CoachRecommendation: Identifiable, Hashable, Sendable {
    let id: Int
    let domain: CoachDomain
    /// Stable cross-analysis key (supplied by the model, else derived from the title).
    let ref: String
    var title: String
    var detail: String
    /// The RATIONALE: which figures from the briefing the model relies on.
    /// This is what separates advice from a slogan, and what lets the user
    /// judge whether the recommendation holds up.
    var rationale: String?
    /// Free-form label returned by the model ("Subscriptions",
    /// "Diversification"…). Deliberately not an enum: freezing a taxonomy
    /// would bring back the rigidity of the 5 `InsightKind` values being left
    /// behind.
    var category: String?
    /// Estimated annual gain (or avoided cost), in euros. 0 = not quantifiable.
    var annualImpact: Double
    /// Feasibility 1-5 (5 = trivial).
    var effort: Int
    /// Confidence 0-1 self-assessed by the model, clamped on write.
    var confidence: Double
    var status: CoachRecommendationStatus
    var generatedAt: Date

    static func == (lhs: CoachRecommendation, rhs: CoachRecommendation) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// What the model understood of the situation, for ONE domain.
struct CoachAnalysis: Sendable {
    let domain: CoachDomain
    /// The "profile": a few sentences characterizing the user.
    var profileSummary: String?
    var generatedAt: Date?
    var isError: Bool
    var message: String?
    /// Backend that produced the analysis, for traceability ("Claude", …).
    var backend: String?
    /// Excerpt of the model's RAW response, kept only when parsing failed.
    /// It's the only way to distinguish "the model refused", "it answered
    /// off-topic" and "it was cut off mid-JSON" — without it, the error is
    /// undiagnosable.
    var rawResponse: String?

    static func empty(_ domain: CoachDomain) -> CoachAnalysis {
        CoachAnalysis(domain: domain, profileSummary: nil, generatedAt: nil,
                      isError: false, message: nil, backend: nil, rawResponse: nil)
    }

    /// Past this interval the analysis is considered stale and an AUTOMATIC
    /// re-run is allowed (asynchronous and non-blocking — see `CoachStore`).
    static let stalenessInterval: TimeInterval = 7 * 24 * 3600

    func isStale(now: Date = Date()) -> Bool {
        guard let generatedAt else { return true }
        return now.timeIntervalSince(generatedAt) > Self.stalenessInterval
    }
}

/// A recommendation as it comes out of the model, BEFORE persistence: no
/// `id` yet, no `status` yet (the repository keeps the existing row's status
/// when there is one).
struct CoachRecommendationDraft: Sendable {
    var ref: String
    var title: String
    var detail: String
    var rationale: String?
    var category: String?
    var annualImpact: Double
    var effort: Int
    var confidence: Double

    /// Builds a stable key from the text when the model supplies none that
    /// is usable.
    ///
    /// This key's stability is what holds the whole persistent-dismissal
    /// mechanism together. It is deliberately derived from NORMALIZED text
    /// (lowercased, diacritics and punctuation stripped, truncated): two
    /// successive analyses almost always reword the same advice slightly,
    /// and a key computed on the raw title would change every time.
    static func slug(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
        let allowed = folded.map { ch -> Character in
            ch.isLetter || ch.isNumber ? ch : "_"
        }
        let collapsed = String(allowed)
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        return String(collapsed.prefix(60))
    }
}

/// The goals written by the user — the only SYNCED part (hand-written
/// prose, tedious to retype on a second device).
struct CoachProfile: Sendable {
    var objectives: String
    var updatedAt: Date?

    static let empty = CoachProfile(objectives: "", updatedAt: nil)

    var hasObjectives: Bool {
        !objectives.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
