import Foundation
import Testing
@testable import Nemoris

/// Règle de choix du backend IA, fonctionnalité par fonctionnalité.
///
/// L'état réel de l'appareil — Apple Intelligence disponible ? clé en
/// trousseau ? — n'est pas testable. Il est donc DONNÉ au résolveur en
/// paramètre, ce qui rend la règle elle-même vérifiable.
@Suite("AIBackendResolver")
struct AIBackendResolverTests {

    private let toutDisponible = AIBackendAvailability(
        foundationModels: true, foundationModelsReadsImages: true,
        localServer: true, configuredCloudProviders: [.claude, .openAI])

    // MARK: - « Automatique » : le plus privé d'abord

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

    // MARK: - Le cas qui a motivé le réglage par fonctionnalité

    @Test("En iOS 26 Apple lit le texte mais pas les images")
    func appleAveugleEnIOS26() {
        let ios26 = AIBackendAvailability(
            foundationModels: true, foundationModelsReadsImages: false,
            localServer: true, configuredCloudProviders: [])

        // L'import de documents ne REQUIERT pas l'image (il océrise) : l'en
        // priver ici serait une régression pour tout appareil en iOS 26, où il
        // travaille très bien sur du texte.
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

        // C'est exactement ce qu'un réglage global ne savait pas exprimer.
        #expect(AIBackendResolver.resolve(choice: .localServer, feature: .transactionImport,
                                          availability: ios26) == .localServer)
        #expect(AIBackendResolver.readsImages(.localServer, availability: ios26),
                "le serveur local, lui, peut lire l'image")
    }

    // MARK: - Backend imposé : jamais de repli

    @Test("Un backend imposé mais absent ne bascule pas ailleurs")
    func aucunRepliSilencieux() {
        let sansApple = AIBackendAvailability(localServer: true,
                                              configuredCloudProviders: [.claude])
        // Tout l'intérêt d'imposer un backend est de DIAGNOSTIQUER : un repli
        // ferait croire qu'Apple répond alors que la requête part ailleurs.
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

    // MARK: - Capacités déclarées

    @Test("Une capacité optionnelle n'exclut pas un backend qui en manque")
    func capacitesRequisesEtOptionnelles() {
        #expect(AIFeature.transactionImport.optionalCapabilities.contains(.image))
        #expect(!AIFeature.transactionImport.requiredCapabilities.contains(.image),
                "l'exiger priverait d'IA tous les appareils en iOS 26")
        #expect(AIFeature.merchantEnrichment.optionalCapabilities.isEmpty)
    }

    @Test("L'assistant SQL exige le multi-tours")
    func assistantSQLMultiTours() {
        // Il s'appuie sur l'état conservé entre deux questions, qu'un backend
        // HTTP sans gestion d'historique ne fournit pas.
        #expect(AIFeature.sqlAssistant.requiredCapabilities.contains(.multiTurn))
    }

    @Test("Chaque fonctionnalité a besoin du texte et sait se présenter")
    func inventaireDesFonctionnalites() {
        #expect(AIFeature.allCases.allSatisfy { $0.requiredCapabilities.contains(.text) })
        #expect(AIFeature.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.explanation.isEmpty },
                "une fonctionnalité sans libellé serait invisible dans les Réglages")
    }

    // MARK: - Ce qui quitte l'appareil

    @Test("Seul le cloud fait sortir les données")
    func sortieDesDonnees() {
        #expect(AIBackendChoice.cloud(.claude).leavesDevice)
        #expect(AIBackendChoice.cloud(.openAI).leavesDevice)
        // Le serveur local ne « sort » pas au sens qui compte ici : il reste sur
        // le réseau de l'utilisateur. Le classer autrement noierait
        // l'avertissement qui compte vraiment.
        #expect(!AIBackendChoice.localServer.leavesDevice)
        #expect(!AIBackendChoice.foundationModels.leavesDevice)
        #expect(!AIBackendChoice.automatic.leavesDevice)
        #expect(!AIBackendChoice.off.leavesDevice)
    }

    @Test("Aucune option n'est orpheline du sélecteur")
    func toutesLesOptionsProposees() {
        #expect(AIBackendChoice.allChoices.contains(.cloud(.claude)))
        #expect(AIBackendChoice.allChoices.contains(.cloud(.openAI)))
        // automatique + Apple + serveur local + N cloud + désactivée
        #expect(AIBackendChoice.allChoices.count == 4 + AICloudProvider.allCases.count,
                "obtenu : \(AIBackendChoice.allChoices.count)")
    }

    // MARK: - Reprise de l'ancien réglage global

    @Test("Un choix à valeur associée survit à l'encodage")
    func encodageDuChoix() throws {
        // Un simple `rawValue` d'énumération ne saurait pas porter le
        // fournisseur associé au cas cloud.
        let encode = try JSONEncoder().encode(AIBackendChoice.cloud(.claude))
        let decode = try JSONDecoder().decode(AIBackendChoice.self, from: encode)
        #expect(decode == .cloud(.claude))
    }

    @Test("Le réglage global antérieur est repris sur chaque fonctionnalité")
    func repriseDuReglageGlobal() throws {
        let nom = "nemoris.ai.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: nom))
        defer { defaults.removePersistentDomain(forName: nom) }

        // Sans reprise, un utilisateur ayant choisi son serveur repartirait en
        // « Automatique » — donc sur Apple Intelligence — après la mise à jour.
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
