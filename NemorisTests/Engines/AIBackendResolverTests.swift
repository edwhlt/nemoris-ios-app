import Foundation
import Testing
@testable import Nemoris

/// The rule for choosing the AI backend, feature by feature.
///
/// The device's real state — is Apple Intelligence available? a key in
/// the keychain? — isn't testable. It's therefore GIVEN to the resolver as
/// a parameter, which makes the rule itself verifiable.
@Suite("AIBackendResolver")
struct AIBackendResolverTests {

    private let toutDisponible = AIBackendAvailability(
        foundationModels: true, foundationModelsReadsImages: true,
        localServer: true, configuredCloudProviders: [.claude, .openAI])

    // MARK: - "Automatic": the most private option first

    @Test("Apple Intelligence est retenu quand tout est disponible")
    func ordreDePreference() {
        #expect(AIBackendResolver.resolve(choice: .automatic, feature: .merchantEnrichment,
                                          availability: toutDisponible) == .foundationModels)

        let sansApple = AIBackendAvailability(localServer: true,
                                              configuredCloudProviders: [.claude])
        #expect(AIBackendResolver.resolve(choice: .automatic, feature: .merchantEnrichment,
                                          availability: sansApple) == .localServer,
                "le serveur local reste chez l'utilisateur, le cloud non")

        let cloudSeul = AIBackendAvailability(configuredCloudProviders: [.openAI])
        #expect(AIBackendResolver.resolve(choice: .automatic, feature: .merchantEnrichment,
                                          availability: cloudSeul) == .cloud(.openAI),
                "le réseau est le dernier recours")
    }

    @Test("Rien de configuré ne donne aucune IA, sans bruit")
    func rienDeConfigure() {
        #expect(AIBackendResolver.resolve(choice: .automatic, feature: .merchantEnrichment,
                                          availability: AIBackendAvailability()) == nil,
                "l'app reste entièrement fonctionnelle sans IA")
    }

    // MARK: - The case that motivated the per-feature setting

    @Test("En iOS 26 Apple lit le texte mais pas les images")
    func appleAveugleEnIOS26() {
        let ios26 = AIBackendAvailability(
            foundationModels: true, foundationModelsReadsImages: false,
            localServer: true, configuredCloudProviders: [])

        // Document import doesn't REQUIRE images (it falls back to OCR): depriving it
        // of them here would be a regression for any device on iOS 26, where it
        // works very well on text.
        #expect(AIBackendResolver.resolve(choice: .automatic, feature: .transactionImport,
                                          availability: ios26) == .foundationModels)
        #expect(AIBackendResolver.readsImages(.foundationModels, availability: ios26) == false,
                "les captures seront océrisées")
        #expect(AIBackendResolver.resolve(choice: .automatic, feature: .merchantEnrichment,
                                          availability: ios26) == .foundationModels)
    }

    @Test("Une fonctionnalité bascule sans entraîner les autres")
    func basculeCiblee() {
        let ios26 = AIBackendAvailability(
            foundationModels: true, foundationModelsReadsImages: false,
            localServer: true, configuredCloudProviders: [])

        // This is exactly what a global setting couldn't express.
        #expect(AIBackendResolver.resolve(choice: .localServer, feature: .transactionImport,
                                          availability: ios26) == .localServer)
        #expect(AIBackendResolver.readsImages(.localServer, availability: ios26),
                "le serveur local, lui, peut lire l'image")
    }

    // MARK: - An imposed backend: never a fallback

    @Test("Un backend imposé mais absent ne bascule pas ailleurs")
    func aucunRepliSilencieux() {
        let sansApple = AIBackendAvailability(localServer: true,
                                              configuredCloudProviders: [.claude])
        // The whole point of forcing a backend is to DIAGNOSE: a fallback
        // would make it look like Apple is answering when the request goes elsewhere.
        #expect(AIBackendResolver.resolve(choice: .foundationModels, feature: .insights,
                                          availability: sansApple) == nil)

        let sansServeur = AIBackendAvailability(foundationModels: true)
        #expect(AIBackendResolver.resolve(choice: .localServer, feature: .insights,
                                          availability: sansServeur) == nil)
    }

    @Test("La clé d'un fournisseur ne sert pas pour un autre")
    func cleNonInterchangeable() {
        let openAISeul = AIBackendAvailability(configuredCloudProviders: [.openAI])
        #expect(AIBackendResolver.resolve(choice: .cloud(.claude), feature: .insights,
                                          availability: openAISeul) == nil)
        #expect(AIBackendResolver.resolve(choice: .cloud(.openAI), feature: .insights,
                                          availability: openAISeul) == .cloud(.openAI))
    }

    @Test("« Désactivée » gagne sur toutes les fonctionnalités")
    func desactiveeGagneSurTout() {
        for fonctionnalite in AIFeature.allCases {
            #expect(AIBackendResolver.resolve(choice: .off, feature: fonctionnalite,
                                              availability: toutDisponible) == nil,
                    "\(fonctionnalite.rawValue)")
        }
    }

    // MARK: - Declared capabilities

    @Test("Une capacité optionnelle n'exclut pas un backend qui en manque")
    func capacitesRequisesEtOptionnelles() {
        #expect(AIFeature.transactionImport.optionalCapabilities.contains(.image))
        #expect(!AIFeature.transactionImport.requiredCapabilities.contains(.image),
                "l'exiger priverait d'IA tous les appareils en iOS 26")
        #expect(AIFeature.merchantEnrichment.optionalCapabilities.isEmpty)
    }

    @Test("L'assistant SQL exige le multi-tours")
    func assistantSQLMultiTours() {
        // It relies on state kept between two questions, which an
        // HTTP backend with no history management doesn't provide.
        #expect(AIFeature.sqlAssistant.requiredCapabilities.contains(.multiTurn))
    }

    @Test("Chaque fonctionnalité a besoin du texte et sait se présenter")
    func inventaireDesFonctionnalites() {
        #expect(AIFeature.allCases.allSatisfy { $0.requiredCapabilities.contains(.text) })
        #expect(AIFeature.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.explanation.isEmpty },
                "une fonctionnalité sans libellé serait invisible dans les Réglages")
    }

    // MARK: - What leaves the device

    @Test("Seul le cloud fait sortir les données")
    func sortieDesDonnees() {
        #expect(AIBackendChoice.cloud(.claude).leavesDevice)
        #expect(AIBackendChoice.cloud(.openAI).leavesDevice)
        // The local server doesn't "leave" in the sense that matters here: it stays on
        // the user's own network. Classifying it otherwise would drown out
        // the warning that really matters.
        #expect(!AIBackendChoice.localServer.leavesDevice)
        #expect(!AIBackendChoice.foundationModels.leavesDevice)
        #expect(!AIBackendChoice.automatic.leavesDevice)
        #expect(!AIBackendChoice.off.leavesDevice)
    }

    @Test("Aucune option n'est orpheline du sélecteur")
    func toutesLesOptionsProposees() {
        #expect(AIBackendChoice.allChoices.contains(.cloud(.claude)))
        #expect(AIBackendChoice.allChoices.contains(.cloud(.openAI)))
        // ⚠️ The count had stayed at 4 when the EMBEDDED model joined the
        // selector: a backend you can pick but that no test
        // knows about is exactly what this assertion exists to prevent.
        #expect(AIBackendChoice.allChoices.contains(.embeddedModel))
        // automatic + Apple + embedded model + local server + N cloud + disabled
        #expect(AIBackendChoice.allChoices.count == 5 + AICloudProvider.allCases.count,
                "obtenu : \(AIBackendChoice.allChoices.count)")
    }

    // MARK: - Migrating the old global setting

    @Test("Un choix à valeur associée survit à l'encodage")
    func encodageDuChoix() throws {
        // A plain enum `rawValue` couldn't carry the
        // provider associated with the cloud case.
        let encode = try JSONEncoder().encode(AIBackendChoice.cloud(.claude))
        let decode = try JSONDecoder().decode(AIBackendChoice.self, from: encode)
        #expect(decode == .cloud(.claude))
    }

    @Test("Le réglage global antérieur est repris sur chaque fonctionnalité")
    func repriseDuReglageGlobal() throws {
        let nom = "nemoris.ai.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: nom))
        defer { defaults.removePersistentDomain(forName: nom) }

        // Without migration, a user who had chosen their server would end up back on
        // "Automatic" — so on Apple Intelligence — after the update.
        let encode = try JSONEncoder().encode(AIBackendChoice.localServer)
        for fonctionnalite in AIFeature.allCases {
            defaults.set(encode, forKey: "ai.backend.\(fonctionnalite.rawValue)")
        }

        for fonctionnalite in AIFeature.allCases {
            let brut = defaults.data(forKey: "ai.backend.\(fonctionnalite.rawValue)")
            let choix = brut.flatMap { try? JSONDecoder().decode(AIBackendChoice.self, from: $0) }
            #expect(choix == .localServer, "\(fonctionnalite.rawValue)")
        }
    }
}
