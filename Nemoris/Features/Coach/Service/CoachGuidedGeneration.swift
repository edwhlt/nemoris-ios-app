import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - CoachGuidedGeneration — SCHEMA-guided generation (Apple Intelligence)
//
// Why this path exists, when the coach had deliberately chosen "one JSON
// path for every backend":
//
// That choice held as long as the backends could honour a format contract in
// free text. On a small on-device model they can't: Apple Intelligence and a
// Llama 1B returned PROSE where JSON was asked for — the analysis then failed
// entirely, even though the model had "understood" the briefing.
//
// Guided generation removes that class of failure by construction: the model
// is constrained BY THE SCHEMA at decoding time, it CANNOT produce anything
// else. Document import (`TransactionDocumentParser`) already does this for
// exactly the same reason.
//
// Apple only (`@Generable` is specific to Foundation Models). The other
// backends keep using the JSON path, which suits them.
//
// The prompt and `@Guide` descriptions stay in French: they are content for a
// model asked to answer the user in their own language.

@MainActor
enum CoachGuidedGeneration {

    /// True if the feature is actually served by Apple Intelligence AND the
    /// model is available here.
    ///
    /// Testing the RESOLVED backend is not cosmetic: calling Foundation
    /// Models directly would ignore a "local server", a "cloud" or a
    /// "disabled" chosen for THIS feature.
    static func isAvailable(for feature: AIFeature) -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return AIEnrichmentBackend.usesGuidedGeneration(for: feature)
                && SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// One pass's recommendations. `nil` = unavailable or failed ⇒ the
    /// caller falls back to the generic JSON path, never to nothing.
    static func recommendations(system: String, user: String, feature: AIFeature)
        async -> [CoachRecommendationDraft]? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), isAvailable(for: feature) {
            // A FRESH session per pass. `LanguageModelSession` keeps its
            // transcript from one call to the next: reusing the same session
            // would grow the context on every pass and exhaust the window —
            // exactly what splitting is meant to avoid.
            let session = LanguageModelSession(instructions: system)
            do {
                let response = try await session.respond(to: user, generating: AICoachRecommendations.self)
                return convert(response.content)
            } catch {
                print("[CoachGuidedGeneration] recommendations failed: \(error)")
            }
        }
        #endif
        return nil
    }

    /// The final pass's profile. `nil` = unavailable or failed.
    static func profile(system: String, user: String, feature: AIFeature) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), isAvailable(for: feature) {
            let session = LanguageModelSession(instructions: system)
            do {
                let response = try await session.respond(to: user, generating: AICoachProfile.self)
                let trimmed = response.content.profile.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } catch {
                print("[CoachGuidedGeneration] profile failed: \(error)")
            }
        }
        #endif
        return nil
    }

    // MARK: - Schemas

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct AICoachRecommendations {
        @Guide(description: "Les recommandations justifiées par cet extrait du dossier", .count(0...8))
        var recommendations: [AICoachRecommendation]
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct AICoachRecommendation {
        @Guide(description: "Identifiant court et stable, en minuscules sans accent, par exemple abonnements_streaming")
        var key: String
        @Guide(description: "Une phrase courte et spécifique, pas un thème générique")
        var title: String
        @Guide(description: "L'action à mener, précisément, en 2 à 4 phrases")
        var detail: String
        @Guide(description: "Les chiffres exacts du dossier qui justifient ce conseil")
        var rationale: String
        @Guide(description: "Un ou deux mots, par exemple Abonnements, Alimentation, Diversification")
        var category: String
        @Guide(description: "Gain ou économie annuelle en euros, 0 si ce n'est pas déductible du dossier")
        var annualImpact: Double
        @Guide(description: "Faisabilité de 1 à 5, 5 signifiant trivial à mettre en oeuvre")
        var effort: Int
        @Guide(description: "Confiance dans ce conseil, de 0 à 1")
        var confidence: Double
    }

    @available(iOS 26.0, macOS 26.0, *)
    @Generable
    struct AICoachProfile {
        @Guide(description: "Portrait financier de la personne en 6 à 10 phrases, appuyé sur les chiffres fournis")
        var profile: String
    }

    /// Goes through the same bounds as the JSON path
    /// (`CoachRanker.normalize`): a model happily returns `effort: 12` or a
    /// confidence of `95`, and those values would contaminate the ranking
    /// directly.
    @available(iOS 26.0, macOS 26.0, *)
    private static func convert(_ extraction: AICoachRecommendations) -> [CoachRecommendationDraft] {
        var seen = Set<String>()
        return extraction.recommendations.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            let modelKey = CoachRecommendationDraft.slug(item.key)
            let ref = modelKey.isEmpty ? CoachRecommendationDraft.slug(title) : modelKey
            guard !ref.isEmpty, seen.insert(ref).inserted else { return nil }

            let bounded = CoachRanker.normalize(annualImpact: item.annualImpact,
                                                effort: item.effort,
                                                confidence: item.confidence)
            func nonEmpty(_ value: String) -> String? {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return CoachRecommendationDraft(
                ref: ref,
                title: title,
                detail: nonEmpty(item.detail) ?? "",
                rationale: nonEmpty(item.rationale),
                category: nonEmpty(item.category),
                annualImpact: bounded.annualImpact,
                effort: bounded.effort,
                confidence: bounded.confidence
            )
        }
    }
    #endif
}
