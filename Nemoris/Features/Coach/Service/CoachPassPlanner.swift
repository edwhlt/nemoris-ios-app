import Foundation

// MARK: - CoachPassPlanner — splitting the briefing when the model can't read it all
//
// PURE engine (`import Foundation` only): no database, network, AI or SwiftUI
// access. Same doctrine as `CoachBriefingBuilder` / `CoachRanker`.
//
// ─── The problem, stated honestly ──────────────────────────────────────────
//
// A context window is a WALL, not a gauge that refills: what doesn't fit
// isn't "gradually forgotten", it is never read. Apple Intelligence
// (`LanguageModelSession`) works within ~4,000 tokens, input AND output
// combined, with no parameter to widen it. With ~700 tokens of instructions
// and ~1,600 of briefing, ~1,700 tokens remain to write N reasoned
// recommendations: that's what made every analysis fail on this backend.
//
// What a tool like LM Studio does with "a 50-page document" is NOT long
// memory: it splits, it selects what's relevant, and it sends only that to
// the model. The model's own memory never exceeds its window. The same
// principle applies here — except there's no need to search for the relevant
// passages: this briefing is ALREADY a structured aggregate, and its
// sections are the natural cut points.
//
// ─── What this planner does ────────────────────────────────────────────────
//
// It turns the briefing's sections into N passes that each fit the budget,
// every pass carrying:
//   • the KEY FIGURES (repeated) — without them, a "merchants" pass has no
//     scale of reference and advises in a vacuum;
//   • the GOALS (repeated) — the coach's top priority, never sacrificed;
//   • one or more whole sections.
//
// Merging the results is DETERMINISTIC (deduplication by `ref`, then
// `CoachRanker`), not one more model call: asking an AI to sort what an AI
// just wrote would cost a round trip, wouldn't be reproducible, and couldn't
// be tested.

enum CoachPassPlanner {

    /// Target size of ONE pass, in characters, on a narrow window.
    ///
    /// ~2,200 characters ≈ 600 tokens. With ~450 tokens of partial-pass
    /// instructions, the input stays under 1,100 tokens: ample room remains
    /// to write 2 to 4 reasoned recommendations within a 4,000-token window.
    /// That ratio is what matters, not the absolute size.
    static let compactPassCharacters = 2_200

    /// Minimum room guaranteed to the SECTIONS within a pass.
    ///
    /// Without this floor, a user who writes a page of goals (capped at
    /// 1,500 characters by the briefing) would leave no room for the
    /// material to analyze: the pass would go out with goals and almost no
    /// data.
    static let minimumSectionCharacters = 700

    /// Goals repeated in every pass: capped shorter than in the full
    /// briefing, since they are paid for N times.
    static let objectivesPerPassCharacters = 600

    /// Splits the briefing into passes.
    ///
    /// - Parameters:
    ///   - sections: the briefing's named blocks, in reading order.
    ///   - header: the key figures, repeated in every pass.
    ///   - objectivesBlock: the already-formatted goals block, or `nil`.
    ///   - budget: `.generous` ⇒ ONE pass with everything (historical behavior).
    static func plan(sections: [CoachBriefingSection],
                     header: String,
                     objectivesBlock: String?,
                     budget: CoachContextBudget) -> [CoachAnalysisPass] {
        let usable = sections.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !usable.isEmpty else { return [] }

        // A backend that takes the whole briefing has nothing to gain from
        // splitting: several calls would cost more AND deprive the model of
        // the overall view, which is precisely what produces the
        // cross-cutting recommendations.
        if budget == .generous {
            var body = ([header] + usable.map(\.body)).joined(separator: "\n\n")
            if let objectivesBlock { body += "\n\n" + objectivesBlock }
            return [CoachAnalysisPass(index: 1, total: 1,
                                      focus: usable.map(\.title).joined(separator: ", "),
                                      body: body)]
        }

        let objectives = objectivesBlock.map { String($0.prefix(objectivesPerPassCharacters)) }
        let fixedCost = header.count + (objectives.map { $0.count + 2 } ?? 0)
        let sectionBudget = max(minimumSectionCharacters, compactPassCharacters - fixedCost)

        // Greedy grouping: a pass is filled as long as the next section
        // still fits. A SINGLE section larger than the budget is truncated
        // but keeps its own pass — never dropped, otherwise splitting would
        // make material disappear instead of spreading it out.
        var groups: [[CoachBriefingSection]] = []
        var current: [CoachBriefingSection] = []
        var currentCount = 0

        for section in usable {
            let separator = current.isEmpty ? 0 : 2   // the joining "\n\n"
            if !current.isEmpty, currentCount + separator + section.body.count > sectionBudget {
                groups.append(current)
                current = []
                currentCount = 0
            }
            currentCount += (current.isEmpty ? 0 : 2) + section.body.count
            current.append(section)
        }
        if !current.isEmpty { groups.append(current) }

        let total = groups.count
        return groups.enumerated().map { offset, group in
            var text = group.map(\.body).joined(separator: "\n\n")
            if text.count > sectionBudget {
                text = String(text.prefix(sectionBudget)) + "\n[…section tronquée]"
            }
            var body = header + "\n\n" + text
            if let objectives { body += "\n\n" + objectives }
            return CoachAnalysisPass(index: offset + 1, total: total,
                                     focus: group.map(\.title).joined(separator: ", "),
                                     body: body)
        }
    }
}
