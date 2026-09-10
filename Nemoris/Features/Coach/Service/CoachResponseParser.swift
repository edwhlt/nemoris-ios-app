import Foundation

// MARK: - CoachResponseParser
//
// PURE engine: turns the model's RAW response into usable recommendations.
// No network call, no database — therefore testable without a model.
//
// Tolerance is deliberate. This parser must NEVER throw away the whole
// analysis because of one malformed line: that's the class of bug already
// paid for in document import, where a missing key lost the entire page (see
// `LenientJSON`). Here an invalid recommendation is skipped and the rest go
// through.

enum CoachResponseParser {

    /// Why a response yielded nothing. Telling these apart is essential:
    /// "the model has nothing to recommend" is a SUCCESS, "I couldn't read
    /// its answer" is a DEFECT — and presenting them the same way makes
    /// anything impossible to diagnose.
    enum Failure: Equatable {
        /// Nothing usable: neither valid JSON nor a salvageable object.
        case unreadable
        /// JSON read, but the recommendation list is absent from the document.
        case missingList
        /// The model wrote a preamble (the profile) then was CUT OFF before
        /// a single recommendation. A distinct case: there is nothing to
        /// salvage, and the cause is an exhausted output budget — not
        /// malformed JSON.
        case truncatedBeforeRecommendations
    }

    struct Result {
        var profileSummary: String?
        var drafts: [CoachRecommendationDraft]
        /// `nil` when parsing went fine — including with zero
        /// recommendations, which is a legitimate answer.
        var failure: Failure?
        /// True when recommendations were salvaged one by one from a
        /// truncated response instead of being read in one block.
        var wasSalvaged: Bool = false
    }

    /// Maximum number of recommendations kept per analysis.
    ///
    /// This is NOT a product cap ("we don't limit ourselves to 3
    /// suggestions"): it's a guard against a model that loops and returns
    /// 200 lines. Past 40 it stops being advice and becomes noise — and it
    /// would fill the database.
    static let maxRecommendations = 40

    /// Accepted names for the recommendation list.
    ///
    /// `recommandations` (French spelling) is NOT an affectation: the model
    /// is asked to answer in French, and a model writing in French happily
    /// translates its own JSON keys. Rejecting that variant made the whole
    /// response unusable.
    private static let listKeys = ["recommendations", "recommandations", "items", "suggestions"]
    private static let profileKeys = ["profile", "profil", "summary", "resume"]

    static func parse(_ raw: String) -> Result {
        let cleaned = LenientJSON.repairSyntax(LenientJSON.repaired(LenientJSON.extractObject(from: raw)))

        // ── Nominal path: the whole document is valid JSON ──────────────────
        if let data = cleaned.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let profile = profileKeys.compactMap { root[$0] as? String }.first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawItems = listKeys.compactMap({ root[$0] as? [[String: Any]] }).first else {
                return Result(profileSummary: profile?.isEmpty == false ? profile : nil,
                              drafts: [], failure: .missingList)
            }
            // List present but empty = the model has nothing to propose.
            // That's a valid answer, definitely not an error.
            return Result(profileSummary: profile?.isEmpty == false ? profile : nil,
                          drafts: collect(rawItems), failure: nil)
        }

        // ── Fallback: STRUCTURALLY broken document ──────────────────────────
        //
        // Two causes seen in practice, often together:
        //  • response CUT OFF mid-JSON (context too short) — the objects
        //    written before the cut remain complete;
        //  • the model OMITS `,"recommendations":` and glues the array to the
        //    end of the `profile` string, which it therefore never closes.
        //    Quote parity is then off for ALL the rest of the document, which
        //    defeats any global brace matching (`LenientJSON.innermostObjects`
        //    included).
        //
        // Hence a TARGETED salvage: restart from each `{` whose first key is a
        // known recommendation key. Starting from a real brace, parity becomes
        // reliable again regardless of the disorder that precedes it.
        //
        // Note this restarts from the RAW text, not from `cleaned`: global
        // repairs (re-joined quotes, bare keys quoted) require knowing at all
        // times whether one is INSIDE a string. On a document with broken
        // parity they are themselves disoriented and can worsen the disorder.
        // The correct order is therefore: EXTRACT first — each object starts
        // from a real brace, hence sane parity — then repair EACH fragment in
        // isolation.
        let salvaged = recommendationObjects(in: raw).compactMap { fragment -> [String: Any]? in
            let repairedFragment = LenientJSON.repairSyntax(LenientJSON.repaired(fragment))
            guard let data = repairedFragment.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let drafts = collect(salvaged)
        guard !drafts.isEmpty else {
            // A readable profile but no recommendation object: the model
            // spent its whole output budget on the preamble. Saying so
            // precisely beats a generic "unusable" — the only useful action
            // is to change backend, not to retry.
            if let profile = salvagedProfile(in: raw) {
                return Result(profileSummary: profile, drafts: [],
                              failure: .truncatedBeforeRecommendations)
            }
            return Result(profileSummary: nil, drafts: [], failure: .unreadable)
        }
        return Result(profileSummary: salvagedProfile(in: raw), drafts: drafts,
                      failure: nil, wasSalvaged: true)
    }

    // MARK: - Pass-split analysis

    /// Merges the recommendations of several passes.
    ///
    /// This is the "reduce" half of the split, and it is DETERMINISTIC: two
    /// passes spotting the same subject (a subscription seen both in the
    /// recurring charges and in the merchants) produce the same `ref` — the
    /// one the model is most confident about is kept, never both.
    ///
    /// STABLE tie-breaking on equal confidence: without it, pass ordering
    /// would decide, and two analyses of the same briefing could keep
    /// different variants of the same advice.
    static func merge(_ batches: [[CoachRecommendationDraft]]) -> [CoachRecommendationDraft] {
        var best: [String: CoachRecommendationDraft] = [:]
        var order: [String] = []
        for batch in batches {
            for draft in batch {
                guard let existing = best[draft.ref] else {
                    best[draft.ref] = draft
                    order.append(draft.ref)
                    continue
                }
                if draft.confidence > existing.confidence
                    || (draft.confidence == existing.confidence && draft.annualImpact > existing.annualImpact) {
                    best[draft.ref] = draft
                }
            }
        }
        return Array(order.compactMap { best[$0] }.prefix(maxRecommendations))
    }

    /// Reads a response carrying ONLY the profile (final pass of a split
    /// analysis). Tolerant in the same way as `parse`: valid JSON first,
    /// then salvage from the raw text.
    static func parseProfileOnly(_ raw: String) -> String? {
        let cleaned = LenientJSON.repairSyntax(LenientJSON.repaired(LenientJSON.extractObject(from: raw)))
        if let data = cleaned.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = profileKeys.compactMap({ root[$0] as? String }).first {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return salvagedProfile(in: raw)
    }

    /// Keys whose presence at the head of an object identifies a recommendation.
    private static let recognisableKeys: Set<String> = [
        "key", "title", "detail", "rationale", "category", "annual_impact", "effort", "confidence"
    ]

    /// Extracts recommendation objects from a broken document by matching
    /// braces LOCALLY from each candidate.
    private static func recommendationObjects(in text: String) -> [String] {
        var results: [String] = []
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "{", startsRecommendation(text, at: index) else {
                index = text.index(after: index)
                continue
            }
            // Matching starts here: `inString` restarts at false, which is
            // exact since this is a structural brace.
            var depth = 0
            var inString = false
            var escaped = false
            var cursor = index
            var closed: String.Index?

            while cursor < text.endIndex {
                let character = text[cursor]
                if inString {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { closed = cursor; break }
                }
                cursor = text.index(after: cursor)
            }

            guard let closed else { break }   // truncated object: nothing after it
            results.append(String(text[index...closed]))
            index = text.index(after: closed)
        }
        return results
    }

    /// `true` if the brace at `position` opens an object whose first key is
    /// a recommendation key.
    private static func startsRecommendation(_ text: String, at position: String.Index) -> Bool {
        var cursor = text.index(after: position)
        while cursor < text.endIndex, text[cursor].isWhitespace { cursor = text.index(after: cursor) }
        guard cursor < text.endIndex, text[cursor] == "\"" else { return false }
        cursor = text.index(after: cursor)
        var identifier = ""
        while cursor < text.endIndex, text[cursor] != "\"" {
            identifier.append(text[cursor])
            cursor = text.index(after: cursor)
            if identifier.count > 32 { return false }
        }
        return recognisableKeys.contains(identifier)
    }

    /// Salvages the profile when the document is broken — best effort,
    /// inventing nothing: read the string following `"profile":` and strip
    /// the stray tail (`\n[{`) the model glued on when it forgot the
    /// `recommendations` key.
    private static func salvagedProfile(in text: String) -> String? {
        for key in profileKeys {
            guard let keyRange = text.range(of: "\"\(key)\"") else { continue }
            var cursor = keyRange.upperBound
            while cursor < text.endIndex, text[cursor] != "\"" {
                if text[cursor] == "}" || text[cursor] == "[" { break }
                cursor = text.index(after: cursor)
            }
            guard cursor < text.endIndex, text[cursor] == "\"" else { continue }
            cursor = text.index(after: cursor)
            var value = ""
            var escaped = false
            while cursor < text.endIndex {
                let character = text[cursor]
                if escaped { value.append(character); escaped = false }
                else if character == "\\" { value.append(character); escaped = true }
                else if character == "\"" { break }
                else { value.append(character) }
                cursor = text.index(after: cursor)
            }
            // The tail glued on by the model: "…acute.\n[{".
            var cleanedValue = value
            while let last = cleanedValue.last, "[{ \t\n".contains(last) {
                cleanedValue.removeLast()
            }
            if cleanedValue.hasSuffix("\\n") { cleanedValue.removeLast(2) }
            let trimmed = cleanedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Converts and deduplicates a list of raw objects.
    private static func collect(_ rawItems: [[String: Any]]) -> [CoachRecommendationDraft] {
        var drafts: [CoachRecommendationDraft] = []
        var seenRefs = Set<String>()
        for item in rawItems {
            guard let draft = draft(from: item) else { continue }
            // A model sometimes proposes the same subject twice under two
            // phrasings. The table has a UNIQUE (domain, ref): without this
            // deduplication, the second would silently overwrite the first.
            guard seenRefs.insert(draft.ref).inserted else { continue }
            drafts.append(draft)
            if drafts.count >= maxRecommendations { break }
        }
        return drafts
    }

    // MARK: - One recommendation

    private static func draft(from item: [String: Any]) -> CoachRecommendationDraft? {
        guard let title = string(item["title"]), !title.isEmpty else { return nil }
        let detail = string(item["detail"]) ?? ""
        // Advice with no explanation isn't actionable — but it isn't
        // rejected for that: the title alone is still information.
        let rationale = string(item["rationale"])
        let category = string(item["category"])

        let normalized = CoachRanker.normalize(
            annualImpact: number(item["annual_impact"]) ?? 0,
            effort: Int(number(item["effort"]) ?? 3),
            confidence: number(item["confidence"]) ?? 0.5
        )

        // Stable key: the model's when usable, otherwise derived from the
        // title.
        let modelKey = string(item["key"]).map(CoachRecommendationDraft.slug) ?? ""
        let ref = modelKey.isEmpty ? CoachRecommendationDraft.slug(title) : modelKey
        guard !ref.isEmpty else { return nil }

        return CoachRecommendationDraft(
            ref: ref,
            title: title,
            detail: detail,
            rationale: rationale,
            category: category,
            annualImpact: normalized.annualImpact,
            effort: normalized.effort,
            confidence: normalized.confidence
        )
    }

    // MARK: - Tolerant reading

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    /// A model returns `120`, `120.5` or `"120,50"` interchangeably — and
    /// the last case is common when it answers in French. All three must
    /// yield the same number, otherwise the impact drops to 0 and the
    /// recommendation falls in the ranking for a purely typographic reason.
    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String {
            let normalized = s
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: "")
                .replacingOccurrences(of: "€", with: "")
                .replacingOccurrences(of: "%", with: "")
                .replacingOccurrences(of: ",", with: ".")
            return Double(normalized)
        }
        return nil
    }
}
