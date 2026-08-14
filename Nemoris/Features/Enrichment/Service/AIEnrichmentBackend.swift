import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Point de dispatch UNIQUE vers le backend IA, **par fonctionnalité**.
///
/// Toutes les fonctionnalités IA de l'app passent par ici. Auparavant, chacune
/// appelait `EnrichmentLLMService.shared` en direct, donc un serveur local
/// configuré n'était respecté que par certaines d'entre elles. Le réglage était
/// ensuite devenu global — insuffisant dès que les capacités ont divergé
/// (Foundation Models lit du texte depuis iOS 26, des images seulement depuis
/// iOS 27), d'où le passage à un choix par fonctionnalité (cf. `AIFeature`).
///
/// ⚠️ Deux fonctionnalités contournaient encore ce point de passage et
/// parlaient à Foundation Models directement : le coach financier
/// (`InsightLLMService`) et l'assistant SQL (`SQLAssistantService`). Un
/// « Désactivée » choisi dans les Réglages n'avait donc aucun effet sur elles.
/// Elles sont désormais branchées ici.
///
/// `@MainActor` car il lit `EnrichmentLLMService.shared.isAvailable`, lui-même
/// `@MainActor` — les sites synchrones (`.disabled(...)`, `State(initialValue:)`)
/// tournent déjà sur le main actor, donc aucun hop supplémentaire.
@MainActor
enum AIEnrichmentBackend {

    // MARK: - Résolution du backend effectif

    /// Le backend réellement utilisé pour cette fonctionnalité, une fois le
    /// choix de l'utilisateur confronté à ce que l'appareil sait faire.
    /// `nil` = aucune IA ici.
    ///
    /// C'est LE point où « Automatique » prend son sens : il retient Foundation
    /// Models quand la capacité requise y est, sinon le premier backend
    /// configuré qui l'a.
    static func resolved(for feature: AIFeature) -> AIBackendChoice? {
        AIBackendResolver.resolve(choice: AIFeatureSettings.choice(for: feature),
                                  feature: feature,
                                  availability: currentAvailability)
    }

    /// L'état réel de l'appareil, seule partie non testable de la résolution —
    /// d'où sa séparation d'avec la RÈGLE, qui vit dans `AIBackendResolver`
    /// (moteur pur, couvert par `run_ai_backend_tests.sh`).
    private static var currentAvailability: AIBackendAvailability {
        AIBackendAvailability(
            foundationModels: EnrichmentLLMService.shared.isAvailable,
            foundationModelsReadsImages: EnrichmentLLMService.shared.supportsImageInput,
            localServer: LocalLLMService.hasConfiguration,
            configuredCloudProviders: AICloudProvider.allCases.filter {
                CloudLLMService.hasConfiguration($0)
            })
    }

    // MARK: - Disponibilité

    /// Vérification rapide et synchrone (aucun appel réseau) : pour griser un
    /// bouton, décider d'un état initial de toggle.
    static func isAvailable(for feature: AIFeature) -> Bool {
        resolved(for: feature) != nil
    }

    /// Le backend effectif sait-il lire une IMAGE ?
    ///
    /// Apple : les pièces jointes image sont `@available(iOS 27, macOS 27)`.
    /// Serveur local : on tente — c'est le modèle chargé qui décide, un modèle
    /// purement textuel répondra une erreur et l'appelant retombe sur l'OCR.
    /// Cloud : Claude et OpenAI savent tous les deux.
    static func supportsImageInput(for feature: AIFeature) -> Bool {
        AIBackendResolver.readsImages(resolved(for: feature), availability: currentAvailability)
    }

    /// La génération guidée `@Generable` est-elle disponible ici ?
    ///
    /// ⚠️ Elle est PROPRE à Foundation Models. Les appelants qui l'utilisent
    /// doivent passer par ce test plutôt que par un contrôle de préférence en
    /// dur : sans lui, choisir « serveur local », « cloud » ou « désactivée »
    /// n'empêchait pas l'appel direct à Apple.
    static func usesGuidedGeneration(for feature: AIFeature) -> Bool {
        resolved(for: feature) == .foundationModels
    }

    /// Message court expliquant POURQUOI l'IA est indisponible ici, ou `nil`
    /// si elle l'est. Affiché sous les toggles grisés.
    static func unavailabilityReason(for feature: AIFeature) -> String? {
        guard resolved(for: feature) == nil else { return nil }
        switch AIFeatureSettings.choice(for: feature) {
        case .off:
            return "L'IA est désactivée pour cette fonctionnalité dans les Réglages."
        case .foundationModels:
            return "Apple Intelligence est imposé pour cette fonctionnalité mais n'est pas disponible sur cet appareil."
        case .localServer:
            return "Aucun serveur local n'est configuré. Réglages → Intelligence artificielle."
        case .cloud(let provider):
            return "Aucune clé API enregistrée pour \(provider.displayName). Réglages → Intelligence artificielle."
        case .automatic:
            return "Aucune source d'IA disponible sur cet appareil. Configure un serveur local ou une clé API dans les Réglages."
        }
    }

    // MARK: - Identification de marchand

    /// `nil` si désactivé, non configuré, ou en cas d'échec — même contrat de
    /// silence que `EnrichmentLLMService.identify`.
    static func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        switch resolved(for: .merchantEnrichment) {
        case .foundationModels:
            return await EnrichmentLLMService.shared.identify(context: context)
        case .localServer:
            return await LocalLLMService.shared.identify(context: context)
        case .cloud(let provider):
            return await CloudLLMService(provider: provider).identify(context: context)
        case .automatic, .off, .none:
            return nil
        }
    }

    // MARK: - Complétion générique

    /// Complétion texte via le backend actif de cette fonctionnalité. `nil` si
    /// indisponible ou en échec : l'appelant doit TOUJOURS avoir un chemin sans
    /// IA.
    static func completeText(feature: AIFeature,
                             system: String,
                             user: String) async -> String? {
        switch resolved(for: feature) {
        case .foundationModels:
            return await EnrichmentLLMService.shared.complete(system: system, user: user)
        case .localServer:
            do { return try await LocalLLMService.shared.complete(systemPrompt: system, userPrompt: user) }
            catch { print("[AIEnrichmentBackend] \(feature.rawValue) local error: \(error)"); return nil }
        case .cloud(let provider):
            do { return try await CloudLLMService(provider: provider).complete(systemPrompt: system, userPrompt: user) }
            catch { print("[AIEnrichmentBackend] \(feature.rawValue) cloud error: \(error)"); return nil }
        case .automatic, .off, .none:
            return nil
        }
    }

    /// Complétion à partir d'une IMAGE — le modèle lit la capture lui-même,
    /// mise en page comprise. `nil` si aucun backend ne sait le faire.
    static func completeText(feature: AIFeature,
                             system: String,
                             user: String,
                             image: CGImage) async -> String? {
        switch resolved(for: feature) {
        case .foundationModels:
            return await EnrichmentLLMService.shared.complete(system: system, user: user, image: image)
        case .localServer:
            guard let dataURL = Self.pngDataURL(from: image) else { return nil }
            do {
                return try await LocalLLMService.shared.complete(
                    systemPrompt: system, userPrompt: user, imageDataURL: dataURL)
            } catch {
                print("[AIEnrichmentBackend] \(feature.rawValue) local image error: \(error)")
                return nil
            }
        case .cloud(let provider):
            guard let dataURL = Self.pngDataURL(from: image) else { return nil }
            do {
                return try await CloudLLMService(provider: provider).complete(
                    systemPrompt: system, userPrompt: user, imageDataURL: dataURL)
            } catch {
                print("[AIEnrichmentBackend] \(feature.rawValue) cloud image error: \(error)")
                return nil
            }
        case .automatic, .off, .none:
            return nil
        }
    }

    /// Encodage PNG en data-URL, format attendu par le champ `image_url` du
    /// protocole OpenAI (et re-découpé pour Anthropic, cf. `CloudLLMService`).
    private static func pngDataURL(from image: CGImage) -> String? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }
}
