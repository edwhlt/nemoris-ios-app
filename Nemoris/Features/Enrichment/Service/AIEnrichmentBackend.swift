import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Backend IA choisi par l'utilisateur pour cet appareil. Réglage 100% local
/// (`UserDefaults.standard`) — jamais synchronisé par CloudKit (cf. `SyncSchema`)
/// ni par iCloud Key-Value Store (jamais utilisé dans ce projet). Deux appareils
/// peuvent donc avoir des réglages différents par construction : un Mac peut rester
/// sur `.automatic` (Foundation Models) pendant qu'un iPhone pointe vers `.localServer`.
enum AIBackendPreference: String, Codable, CaseIterable {
    /// Comportement historique : Foundation Models si disponible sur l'appareil, sinon
    /// aucune source IA (repli silencieux sur Sirene + MapKit + moteur embarqué).
    case automatic
    /// Force un serveur HTTP compatible OpenAI configuré par l'utilisateur (LM Studio,
    /// Ollama, ou toute app exposant `/v1/chat/completions`), indépendamment de la
    /// disponibilité de Foundation Models sur cet appareil.
    case localServer
    /// Aucune source IA n'est jamais appelée.
    case off

    var displayName: String {
        switch self {
        case .automatic:   return "Automatique"
        case .localServer: return "Serveur local"
        case .off:         return "Désactivée"
        }
    }

    var icon: String {
        switch self {
        case .automatic:   return "sparkles"
        case .localServer: return "server.rack"
        case .off:         return "slash.circle"
        }
    }

    private static let key = "ai.backendPreference"

    static var current: AIBackendPreference {
        get {
            UserDefaults.standard.string(forKey: key).flatMap(AIBackendPreference.init(rawValue:)) ?? .automatic
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}

/// Point de dispatch UNIQUE vers le backend IA sélectionné. `EnrichmentOrchestrator`
/// (import batch), `EnrichmentSheetView` (recherche rapide) et `PayeeCreationFormSheet`
/// (aide à l'identification) passent tous par ici — avant, chacun appelait
/// `EnrichmentLLMService.shared` directement, donc un backend local configuré n'aurait
/// été respecté que par l'un des trois. Même discipline que le reste du projet vis-à-vis
/// des calculs dupliqués (cf. AXE Q) : un seul endroit qui sait "quel backend est actif".
///
/// `@MainActor` car il lit `EnrichmentLLMService.shared.isAvailable`, qui est
/// lui-même `@MainActor` — les 2 sites synchrones (`.disabled(...)`, `State(initialValue:)`
/// dans les Views) tournent déjà sur le main actor, donc aucun hop supplémentaire.
@MainActor
enum AIEnrichmentBackend {

    /// Vérification rapide et synchrone (pas de test réseau) pour griser/dégriser
    /// le toggle "IA" dans les sheets de recherche manuelle.
    static var isAvailable: Bool {
        switch AIBackendPreference.current {
        case .automatic:   return EnrichmentLLMService.shared.isAvailable
        case .localServer: return LocalLLMService.hasConfiguration
        case .off:         return false
        }
    }

    /// Identifie un marchand via le backend actif. `nil` si désactivé, non configuré,
    /// ou en cas d'échec — même contrat de silence que `EnrichmentLLMService.identify`.
    static func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        switch AIBackendPreference.current {
        case .automatic:
            guard EnrichmentLLMService.shared.isAvailable else { return nil }
            return await EnrichmentLLMService.shared.identify(context: context)
        case .localServer:
            return await LocalLLMService.shared.identify(context: context)
        case .off:
            return nil
        }
    }

    /// Complétion texte GÉNÉRIQUE via le backend actif — pour les tâches qui ne sont
    /// pas de l'identification de marchand (extraction d'opérations depuis un relevé,
    /// notamment). `nil` si désactivé, non configuré ou en cas d'échec : l'appelant
    /// doit toujours avoir un chemin sans IA.
    ///
    /// Passer par ici plutôt que d'appeler un service en direct est ce qui garantit
    /// qu'un utilisateur en `.localServer` a l'IA partout où elle est proposée — le
    /// module d'import de documents parlait à Foundation Models sans intermédiaire,
    /// donc ne voyait aucun serveur local configuré.
    /// Le backend actif sait-il lire une IMAGE ?
    ///
    /// Apple : `Attachment` image est `@available(iOS 27.0, macOS 27.0)`.
    /// Serveur local : on tente — c'est le modèle chargé qui décide (les
    /// multimodaux suivent le protocole OpenAI à parties typées). Un modèle
    /// purement textuel répondra une erreur, et l'appelant retombe alors sur
    /// l'OCR.
    static var supportsImageInput: Bool {
        switch AIBackendPreference.current {
        case .automatic:   return EnrichmentLLMService.shared.supportsImageInput
        case .localServer: return LocalLLMService.hasConfiguration
        case .off:         return false
        }
    }

    /// Complétion à partir d'une IMAGE — le modèle lit la capture lui-même,
    /// mise en page comprise. `nil` si aucun backend ne sait le faire ou en cas
    /// d'échec : l'appelant doit toujours avoir un chemin sans image.
    static func completeText(system: String, user: String, image: CGImage) async -> String? {
        switch AIBackendPreference.current {
        case .automatic:
            return await EnrichmentLLMService.shared.complete(system: system, user: user, image: image)
        case .localServer:
            guard LocalLLMService.hasConfiguration,
                  let dataURL = Self.pngDataURL(from: image) else { return nil }
            do {
                return try await LocalLLMService.shared.complete(systemPrompt: system,
                                                                 userPrompt: user,
                                                                 imageDataURL: dataURL)
            } catch {
                print("[AIEnrichmentBackend] completeText(image) error: \(error)")
                return nil
            }
        case .off:
            return nil
        }
    }

    /// Encodage PNG en data-URL, format attendu par le champ `image_url` du
    /// protocole OpenAI.
    private static func pngDataURL(from image: CGImage) -> String? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }

    static func completeText(system: String, user: String) async -> String? {
        switch AIBackendPreference.current {
        case .automatic:
            guard EnrichmentLLMService.shared.isAvailable else { return nil }
            return await EnrichmentLLMService.shared.complete(system: system, user: user)
        case .localServer:
            guard LocalLLMService.hasConfiguration else { return nil }
            do {
                return try await LocalLLMService.shared.complete(systemPrompt: system, userPrompt: user)
            } catch {
                print("[AIEnrichmentBackend] completeText error: \(error)")
                return nil
            }
        case .off:
            return nil
        }
    }
}
