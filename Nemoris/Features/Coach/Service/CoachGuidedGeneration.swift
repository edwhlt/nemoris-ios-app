import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - CoachGuidedGeneration — génération GUIDÉE par schéma (Apple Intelligence)
//
// ⚠️ Pourquoi cette voie existe, alors que le coach avait délibérément choisi
// « un seul chemin JSON pour tous les backends » :
//
// Ce choix tenait tant que les backends savaient tenir un contrat de format en
// texte libre. Sur un petit modèle embarqué, non : Apple Intelligence et un
// Llama 1B rendaient de la PROSE là où on demandait du JSON — l'analyse
// échouait alors entièrement, alors que le modèle avait « compris » le dossier
// (retour d'usage 2026-09-02, avec la réponse en prose à l'appui).
//
// La génération guidée supprime cette classe d'échec par construction : le
// modèle est contraint PAR LE SCHÉMA au moment du décodage, il ne PEUT pas
// produire autre chose. C'est déjà ce que fait l'import de documents
// (`TransactionDocumentParser`) pour exactement la même raison.
//
// Apple uniquement (`@Generable` est propre à Foundation Models). Les autres
// backends continuent par le chemin JSON, qui leur convient.

@MainActor
enum CoachGuidedGeneration {

    /// Vrai si la fonctionnalité est réellement servie par Apple Intelligence
    /// ET que le modèle est disponible ici.
    ///
    /// ⚠️ Le test sur le backend RÉSOLU n'est pas cosmétique : appeler
    /// Foundation Models en direct ferait ignorer un « serveur local », un
    /// « cloud » ou un « désactivée » choisis pour CETTE fonctionnalité.
    static func isAvailable(for feature: AIFeature) -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return AIEnrichmentBackend.usesGuidedGeneration(for: feature)
                && SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Recommandations d'une passe. `nil` = indisponible ou échec ⇒ l'appelant
    /// retombe sur le chemin JSON générique, jamais sur rien.
    static func recommendations(system: String, user: String, feature: AIFeature)
        async -> [CoachRecommendationDraft]? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), isAvailable(for: feature) {
            // ⚠️ Une session NEUVE par passe. `LanguageModelSession` conserve
            // la transcription d'un appel à l'autre : réutiliser la même
            // session ferait grossir le contexte à chaque passe et
            // épuiserait la fenêtre — exactement ce que le découpage cherche
            // à éviter.
            let session = LanguageModelSession(instructions: system)
            do {
                let response = try await session.respond(to: user, generating: AICoachRecommendations.self)
                return convert(response.content)
            } catch {
                print("[CoachGuidedGeneration] recommandations KO : \(error)")
            }
        }
        #endif
        return nil
    }

    /// Profil de la passe finale. `nil` = indisponible ou échec.
    static func profile(system: String, user: String, feature: AIFeature) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), isAvailable(for: feature) {
            let session = LanguageModelSession(instructions: system)
            do {
                let response = try await session.respond(to: user, generating: AICoachProfile.self)
                let trimmed = response.content.profile.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } catch {
                print("[CoachGuidedGeneration] profil KO : \(error)")
            }
        }
        #endif
        return nil
    }

    // MARK: - Schémas

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

    /// Passe par les mêmes bornes que le chemin JSON (`CoachRanker.normalize`) :
    /// un modèle rend volontiers `effort: 12` ou une confiance de `95`, et ces
    /// valeurs contamineraient directement le classement.
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
