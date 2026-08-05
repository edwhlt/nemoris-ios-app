import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
import os

// MARK: - InsightLLMService
//
// Couche 3 du moteur d'insights : humanise le `title` et le `detail` des
// `Insight` produits par `InsightEngine` en utilisant Apple Foundation Models
// (iOS 26+). La détection reste **100 % déterministe** côté `InsightEngine` —
// seul le wording est délégué au LLM.
//
// **Fallback gracieux** : si Foundation Models est indisponible (iOS < 26,
// hardware non éligible, Apple Intelligence désactivée), on renvoie l'insight
// brut tel quel. L'app continue de fonctionner normalement.
//
// **Privacy-first** : inférence locale, aucune donnée transmise. Cohérent avec
// l'usage déjà en place pour l'enrichissement Sirene/MapKit (cf. EnrichmentLLMService).
//
// **Pas activé par défaut côté UI** — le service est prêt mais le Dashboard
// affiche le wording brut. Pour l'activer, il suffira d'appeler
// `await InsightLLMService.shared.humanize(insights)` avant `appState.insights = …`
// dans le `load()` du VM Dashboard. Documenté ici pour aider la future itération.

actor InsightLLMService {

    static let shared = InsightLLMService()

    private static let log = Logger(subsystem: "fr.hedwin.nemoris", category: "InsightLLM")

    /// `true` si l'utilisateur a laissé une IA active pour le coach ET que
    /// Foundation Models est utilisable sur cet appareil.
    ///
    /// ⚠️ Le premier test manquait : ce service appelait Foundation Models en
    /// DIRECT, donc un « Désactivée » (ou un serveur local) choisi dans les
    /// Réglages n'avait aucun effet ici — l'IA continuait de reformuler les
    /// insights alors que l'utilisateur croyait l'avoir coupée. C'est
    /// exactement la classe de bug que le point de dispatch unique existe pour
    /// éteindre.
    ///
    /// Le moteur reste Foundation Models pour l'instant : la reformulation
    /// tourne sur chaque insight du tableau de bord, à chaque chargement — la
    /// faire passer par un serveur ou un fournisseur cloud ajouterait une
    /// latence réseau à un écran qui doit s'afficher tout de suite. Le choix
    /// « Apple Intelligence » ou « Automatique » l'active, tout autre choix la
    /// laisse éteinte, ce qui est le comportement attendu dans les deux cas.
    var isAvailable: Bool {
        get async {
            guard await AIEnrichmentBackend.usesGuidedGeneration(for: .insights) else {
                return false
            }
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *) {
                return SystemLanguageModel.default.availability == .available
            }
            return false
            #else
            return false
            #endif
        }
    }

    /// Humanise une liste d'insights. Renvoie une nouvelle liste avec les
    /// `title` et `detail` éventuellement réécrits par le LLM. En cas d'échec
    /// (LLM indisponible, parse error, timeout), renvoie l'insight inchangé.
    func humanize(_ insights: [Insight]) async -> [Insight] {
        guard await isAvailable else { return insights }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            var result: [Insight] = []
            for insight in insights {
                let humanized = await humanizeOne(insight)
                result.append(humanized)
            }
            return result
        }
        #endif
        return insights
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, *)
    private func humanizeOne(_ insight: Insight) async -> Insight {
        // Prompt très contraint pour éviter les hallucinations. On donne
        // l'input structuré + on demande explicitement de garder les chiffres
        // tels quels.
        let prompt = """
        Tu es un coach financier français. Réécris en français naturel le titre et le détail \
        de cet insight pour qu'il soit plus engageant — sans inventer de chiffres, sans ajouter \
        de conseils que je n'ai pas mentionnés. Ton ton : direct, bienveillant, jamais culpabilisant.

        Type d'insight : \(insight.kind.label)
        Titre actuel : \(insight.title)
        Détail actuel : \(insight.detail)
        Gain annuel : \(insight.annualImpact) EUR

        Réponds avec le format JSON suivant, UNIQUEMENT (pas de markdown, pas de texte avant ou après) :
        {"title": "…", "detail": "…"}
        """
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let content = response.content
            // Parse JSON tolérant (le LLM ajoute parfois des code fences malgré tout)
            let cleaned = content
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = cleaned.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let newTitle = json["title"], !newTitle.isEmpty,
                  let newDetail = json["detail"], !newDetail.isEmpty
            else {
                Self.log.warning("Parse LLM response failed for \(insight.id)")
                return insight
            }
            return Insight(
                id: insight.id,
                kind: insight.kind,
                title: newTitle,
                detail: newDetail,
                annualImpact: insight.annualImpact,
                actionability: insight.actionability,
                confidence: insight.confidence
            )
        } catch {
            Self.log.warning("LLM humanize error : \(error.localizedDescription)")
            return insight
        }
    }
    #endif
}
