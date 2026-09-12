import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// The SINGLE dispatch point to the AI backend, **per feature**.
///
/// Every AI feature in the app goes through here. Previously, each one
/// called `EnrichmentLLMService.shared` directly, so a configured local server
/// was only honored by some of them. The setting then became
/// global — insufficient once capabilities diverged
/// (Foundation Models reads text since iOS 26, images only since
/// iOS 27), hence the move to a per-feature choice (see `AIFeature`).
///
/// ⚠️ Two features used to bypass this crossing point and
/// talked to Foundation Models directly: the financial coach (via a
/// rephrasing service that was never actually called, since removed — see
/// AXE AC) and the SQL assistant (`SQLAssistantService`). A "Disabled"
/// choice made in Settings therefore had no effect on them. The coach is
/// now wired in here via `CoachService`/`CoachPrompt`.
///
/// `@MainActor` because it reads `EnrichmentLLMService.shared.isAvailable`,
/// itself `@MainActor` — synchronous call sites (`.disabled(...)`,
/// `State(initialValue:)`) already run on the main actor, so no extra hop.
@MainActor
enum AIEnrichmentBackend {

    // MARK: - Resolving the effective backend

    /// The backend actually used for this feature, once the
    /// user's choice has been confronted with what the device can do.
    /// `nil` = no AI here.
    ///
    /// This is THE point where "Automatic" gets its meaning: it picks Foundation
    /// Models when the required capability is there, otherwise the first
    /// configured backend that has it.
    static func resolved(for feature: AIFeature) -> AIBackendChoice? {
        AIBackendResolver.resolve(choice: AIFeatureSettings.choice(for: feature),
                                  feature: feature,
                                  availability: currentAvailability)
    }

    /// The device's real state, the only untestable part of the resolution —
    /// hence its separation from the RULE, which lives in `AIBackendResolver`
    /// (a pure engine, covered by `run_ai_backend_tests.sh`).
    private static var currentAvailability: AIBackendAvailability {
        AIBackendAvailability(
            foundationModels: EnrichmentLLMService.shared.isAvailable,
            foundationModelsReadsImages: EnrichmentLLMService.shared.supportsImageInput,
            localServer: LocalLLMService.hasConfiguration,
            embeddedModel: EmbeddedModelService.hasConfiguration,
            configuredCloudProviders: AICloudProvider.allCases.filter {
                CloudLLMService.hasConfiguration($0)
            })
    }

    // MARK: - Availability

    /// Fast, synchronous check (no network call): to gray out a
    /// button, or decide a toggle's initial state.
    static func isAvailable(for feature: AIFeature) -> Bool {
        resolved(for: feature) != nil
    }

    /// Can the effective backend read an IMAGE?
    ///
    /// Apple: image attachments are `@available(iOS 27, macOS 27)`.
    /// Local server: we try — the loaded model decides, a purely text-only
    /// model answers with an error and the caller falls back to OCR.
    /// Cloud: both Claude and OpenAI can.
    static func supportsImageInput(for feature: AIFeature) -> Bool {
        AIBackendResolver.readsImages(resolved(for: feature), availability: currentAvailability)
    }

    /// Is `@Generable` guided generation available here?
    ///
    /// ⚠️ It is SPECIFIC to Foundation Models. Callers that use it
    /// must go through this check rather than a hardcoded preference
    /// check: without it, choosing "local server", "cloud" or "disabled"
    /// wouldn't stop a direct call to Apple.
    static func usesGuidedGeneration(for feature: AIFeature) -> Bool {
        resolved(for: feature) == .foundationModels
    }

    /// Short message explaining WHY AI is unavailable here, or `nil`
    /// if it is. Shown under grayed-out toggles.
    static func unavailabilityReason(for feature: AIFeature) -> String? {
        guard resolved(for: feature) == nil else { return nil }
        switch AIFeatureSettings.choice(for: feature) {
        case .off:
            return "L'IA est désactivée pour cette fonctionnalité dans les Réglages."
        case .foundationModels:
            return "Apple Intelligence est imposé pour cette fonctionnalité mais n'est pas disponible sur cet appareil."
        case .localServer:
            return "Aucun serveur local n'est configuré. Réglages → Intelligence artificielle."
        case .embeddedModel:
            return "Aucun modèle embarqué actif. Réglages → Intelligence artificielle → Sources avancées."
        case .cloud(let provider):
            return "Aucune clé API enregistrée pour \(provider.displayName). Réglages → Intelligence artificielle."
        case .automatic:
            return "Aucune source d'IA disponible sur cet appareil. Configure un serveur local ou une clé API dans les Réglages."
        }
    }

    // MARK: - Identification de marchand

    /// `nil` if disabled, unconfigured, or on failure — same silent-failure
    /// contract as `EnrichmentLLMService.identify`.
    static func identify(context: MerchantEnrichmentContext) async -> MerchantEnrichment? {
        switch resolved(for: .merchantEnrichment) {
        case .foundationModels:
            return await EnrichmentLLMService.shared.identify(context: context)
        case .localServer:
            return await LocalLLMService.shared.identify(context: context)
        case .embeddedModel:
            return await EmbeddedModelService.shared.identify(context: context)
        case .cloud(let provider):
            return await CloudLLMService(provider: provider).identify(context: context)
        case .automatic, .off, .none:
            return nil
        }
    }

    // MARK: - Generic completion

    /// What a completion actually produced.
    ///
    /// ⚠️ `isReasoningOnly` isn't a logging detail: it's the
    /// difference between "this model answers poorly" and "this server just
    /// showed its true limit". The second case CAN BE RECOVERED (retry with a
    /// shorter context), the first can't — conflating them showed a failure
    /// where a second attempt would have succeeded.
    struct CompletionOutcome {
        var text: String?
        var isReasoningOnly = false
    }

    /// Text completion via this feature's active backend. `nil` if
    /// unavailable or on failure: the caller must ALWAYS have a path without
    /// AI.
    static func completeText(feature: AIFeature,
                             system: String,
                             user: String) async -> String? {
        await complete(feature: feature, system: system, user: user).text
    }

    /// Same completion, with the failure REASON when it's usable.
    ///
    /// - Parameter forceDirectAnswer: turns off a local server's reasoning
    ///   mode for this call. Reserved for a retry after `isReasoningOnly` —
    ///   the first attempt always keeps the configuration the
    ///   user chose.
    static func complete(feature: AIFeature,
                         system: String,
                         user: String,
                         forceDirectAnswer: Bool = false) async -> CompletionOutcome {
        switch resolved(for: feature) {
        case .foundationModels:
            return CompletionOutcome(text: await EnrichmentLLMService.shared.complete(system: system, user: user))
        case .localServer:
            do {
                let text = try await LocalLLMService.shared.complete(
                    systemPrompt: system, userPrompt: user,
                    maxTokens: feature.maxOutputTokens,
                    forceDirectAnswer: forceDirectAnswer)
                return CompletionOutcome(text: text)
            } catch let error as LocalLLMError {
                print("[AIEnrichmentBackend] \(feature.rawValue) local error: \(error)")
                if case .reasoningOnly(let reasoning) = error {
                    // The reasoning comes back as TEXT: without it, the
                    // diagnostic panel would be empty if the retry fails
                    // too. Nobody will successfully parse it, and
                    // that's fine — the flag carries the useful information.
                    return CompletionOutcome(text: reasoning, isReasoningOnly: true)
                }
                return CompletionOutcome(text: nil)
            } catch {
                print("[AIEnrichmentBackend] \(feature.rawValue) local error: \(error)")
                return CompletionOutcome(text: nil)
            }
        case .embeddedModel:
            do {
                let text = try await EmbeddedModelService.shared.complete(
                    systemPrompt: system, userPrompt: user, maxTokens: feature.maxOutputTokens)
                return CompletionOutcome(text: text)
            } catch {
                print("[AIEnrichmentBackend] \(feature.rawValue) embedded error: \(error)")
                return CompletionOutcome(text: nil)
            }
        case .cloud(let provider):
            do {
                let text = try await CloudLLMService(provider: provider).complete(systemPrompt: system, userPrompt: user)
                return CompletionOutcome(text: text)
            } catch {
                print("[AIEnrichmentBackend] \(feature.rawValue) cloud error: \(error)")
                return CompletionOutcome(text: nil)
            }
        case .automatic, .off, .none:
            return CompletionOutcome(text: nil)
        }
    }

    /// Completion from an IMAGE — the model reads the screenshot itself,
    /// layout included. `nil` if no backend can do it.
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
                    systemPrompt: system, userPrompt: user, imageDataURL: dataURL,
                    maxTokens: feature.maxOutputTokens)
            } catch {
                print("[AIEnrichmentBackend] \(feature.rawValue) local image error: \(error)")
                return nil
            }
        case .embeddedModel:
            // Scope v1 : texte seulement, cf. `EmbeddedModelService`.
            return nil
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

    /// PNG encoded as a data-URL, the format expected by the OpenAI protocol's
    /// `image_url` field (and re-split for Anthropic, see `CloudLLMService`).
    private static func pngDataURL(from image: CGImage) -> String? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
                data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return "data:image/png;base64," + (data as Data).base64EncodedString()
    }
}
