import Foundation

// Refining a query plan.
// ⚠️ PURE FILE: `import Foundation` ONLY. Definitely not `FoundationModels`.
//
// This is the type the planner consumes, produced indifferently by:
//   • `DeterministicQueryRefiner`  — tables + rules, works EVERYWHERE (iOS 18 included)
//   • `LLMQueryRefinementGenerable` — guided generation, iOS/macOS 26 + Apple Intelligence
//
// The fact that both paths return the SAME type is the whole reason for this split:
// the planner has only ONE code path, so the test corpus exercises the real production
// path. It's the CLAUDE.md doctrine ("never let two code paths compute
// the same thing differently") applied at the AI boundary.

struct LLMQueryRefinement: Hashable, Sendable, Codable {
    /// Commercial name alone, with no processor, city, or reference.
    var merchantName: String?
    /// City / town / district as written in the label.
    var localityName: String?
    var postalCode: String?
    /// ISO 3166-1 alpha-2, MAJUSCULES.
    var countryCode: String?
    var processorName: String?
    /// Abbreviations expanded in full ("RES" → "restaurant").
    var expandedTokens: [String]
    /// Virement nominatif vers un particulier.
    var isPersonNotBusiness: Bool
    /// 0…1.
    var confidence: Double
    var rationale: String?

    init(merchantName: String? = nil,
         localityName: String? = nil,
         postalCode: String? = nil,
         countryCode: String? = nil,
         processorName: String? = nil,
         expandedTokens: [String] = [],
         isPersonNotBusiness: Bool = false,
         confidence: Double = 0,
         rationale: String? = nil) {
        self.merchantName = merchantName
        self.localityName = localityName
        self.postalCode = postalCode
        self.countryCode = countryCode
        self.processorName = processorName
        self.expandedTokens = expandedTokens
        self.isPersonNotBusiness = isPersonNotBusiness
        self.confidence = min(1, max(0, confidence))
        self.rationale = rationale
    }

    /// A neutral element: adds nothing, removes nothing.
    static let none = LLMQueryRefinement()

    var isEmpty: Bool {
        merchantName == nil && localityName == nil && postalCode == nil
            && countryCode == nil && expandedTokens.isEmpty && !isPersonNotBusiness
    }
}

// MARK: - Normalization shared with the @Generable path

/// The model returns EMPTY STRINGS rather than optionals (a flatter schema, more
/// robust across OS versions). This function does the conversion, the clamping, and
/// the uppercasing.
///
/// It lives here, in a PURE file, not in the `@Generable` file: the macro isn't
/// testable by the harness, but this mapping — empty→nil, bounds, case — is, and it's
/// where the real bugs live. `GeneratedQueryPlan.toRefinement()` is just a
/// one-line forward to this function.
enum GeneratedQueryPlanMapping {

    static func map(merchantName: String,
                    localityName: String,
                    postalCode: String,
                    countryCode: String,
                    processorName: String,
                    expandedTokens: [String],
                    isPersonNotBusiness: Bool,
                    confidence: Double) -> LLMQueryRefinement {
        LLMQueryRefinement(
            merchantName: clean(merchantName),
            localityName: clean(localityName).map { $0.lowercased() },
            postalCode: clean(postalCode).flatMap { pc in
                // A French postal code is exactly 5 digits. Everything else is
                // hallucinated noise we don't want going into the `code_postal` filter.
                pc.count == 5 && pc.allSatisfy(\.isNumber) ? pc : nil
            },
            countryCode: clean(countryCode).flatMap { cc in
                cc.count == 2 ? ForeignLocalityTable.normalizeCountryCode(cc) : nil
            },
            processorName: clean(processorName).map { $0.lowercased() },
            expandedTokens: expandedTokens.compactMap { clean($0)?.lowercased() },
            isPersonNotBusiness: isPersonNotBusiness,
            confidence: min(1, max(0, confidence))
        )
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // The model sometimes literally writes "null" / "none" when it doesn't know.
        guard !t.isEmpty, t.lowercased() != "null", t.lowercased() != "none" else { return nil }
        return t
    }
}
