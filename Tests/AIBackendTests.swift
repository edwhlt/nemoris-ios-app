import Foundation

// Harness sans XCTest — compile les fichiers RÉELS des moteurs
// (cf. run_ai_backend_tests.sh).
//
// Couvre la RÈGLE de choix du backend IA par fonctionnalité : ce que
// « Automatique » retient, ce qu'un backend imposé refuse de faire, et la
// reprise du réglage global d'AXE T.
//
// ⚠️ Le garde-fou de pureté est ce harnais : `AIFeature.swift` ne peut pas
// importer FoundationModels ni SwiftUI sans le casser. C'est ce qui garantit que
// la règle reste testable, là où l'état réel de l'appareil (Apple Intelligence
// disponible ? clé en trousseau ?) ne l'est pas.

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ label: String, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ✅ \(label)")
    } else {
        failures += 1
        print("  ❌ \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

@main
enum AIBackendTests {
    static func main() {

// MARK: - t1 — « Automatique » : le plus privé d'abord

print("t1 · Automatique — ordre de préférence")
do {
    let everything = AIBackendAvailability(
        foundationModels: true, foundationModelsReadsImages: true,
        localServer: true, configuredCloudProviders: [.claude, .openAI])
    expect(AIBackendResolver.resolve(choice: .automatic, feature: .merchantEnrichment,
                                     availability: everything) == .foundationModels,
           "Apple Intelligence retenu quand tout est disponible")

    let noApple = AIBackendAvailability(localServer: true,
                                        configuredCloudProviders: [.claude])
    expect(AIBackendResolver.resolve(choice: .automatic, feature: .merchantEnrichment,
                                     availability: noApple) == .localServer,
           "serveur local préféré au cloud")

    let cloudOnly = AIBackendAvailability(configuredCloudProviders: [.openAI])
    expect(AIBackendResolver.resolve(choice: .automatic, feature: .merchantEnrichment,
                                     availability: cloudOnly) == .cloud(.openAI),
           "cloud en dernier recours")

    expect(AIBackendResolver.resolve(choice: .automatic, feature: .merchantEnrichment,
                                     availability: AIBackendAvailability()) == nil,
           "rien de configuré → aucune IA, silencieusement")
}

// MARK: - t2 — LE cas qui a motivé le réglage par fonctionnalité

print("")
print("t2 · iOS 26 : Apple lit le texte, pas les images")
do {
    // Appareil réel en iOS 26 : Foundation Models présent, mais aveugle.
    let ios26 = AIBackendAvailability(
        foundationModels: true, foundationModelsReadsImages: false,
        localServer: true, configuredCloudProviders: [])

    // ⚠️ L'import de documents ne REQUIERT pas l'image (il océrise) : le priver
    // d'Apple Intelligence ici serait une régression pour tous les appareils en
    // iOS 26, alors qu'il y travaille très bien sur du texte.
    expect(AIBackendResolver.resolve(choice: .automatic, feature: .transactionImport,
                                     availability: ios26) == .foundationModels,
           "import de relevés garde Apple Intelligence (image seulement optionnelle)")
    expect(AIBackendResolver.readsImages(.foundationModels, availability: ios26) == false,
           "…mais sans lecture d'image : les captures seront océrisées")

    // Et c'est bien le sens du réglage par fonctionnalité : l'utilisateur peut
    // basculer CETTE fonctionnalité-là vers le serveur local sans toucher aux
    // autres.
    expect(AIBackendResolver.resolve(choice: .localServer, feature: .transactionImport,
                                     availability: ios26) == .localServer,
           "bascule ciblée vers le serveur local")
    expect(AIBackendResolver.readsImages(.localServer, availability: ios26),
           "le serveur local, lui, peut lire l'image")
    expect(AIBackendResolver.resolve(choice: .automatic, feature: .merchantEnrichment,
                                     availability: ios26) == .foundationModels,
           "l'identification des marchands reste sur Apple, elle")
}

// MARK: - t3 — Backend IMPOSÉ : jamais de repli

print("")
print("t3 · Backend imposé — aucun repli silencieux")
do {
    let noApple = AIBackendAvailability(localServer: true,
                                        configuredCloudProviders: [.claude])
    // ⚠️ C'est TOUT l'intérêt de ce choix : diagnostiquer. Un repli
    // automatique ferait croire qu'Apple Intelligence fonctionne alors que la
    // requête part ailleurs.
    expect(AIBackendResolver.resolve(choice: .foundationModels, feature: .insights,
                                     availability: noApple) == nil,
           "Apple imposé mais absent → rien, pas de bascule")

    let noServer = AIBackendAvailability(foundationModels: true)
    expect(AIBackendResolver.resolve(choice: .localServer, feature: .insights,
                                     availability: noServer) == nil,
           "serveur imposé mais non configuré → rien")

    expect(AIBackendResolver.resolve(choice: .cloud(.claude), feature: .insights,
                                     availability: AIBackendAvailability(
                                        configuredCloudProviders: [.openAI])) == nil,
           "clé d'un AUTRE fournisseur ne sert pas")

    expect(AIBackendResolver.resolve(choice: .cloud(.openAI), feature: .insights,
                                     availability: AIBackendAvailability(
                                        configuredCloudProviders: [.openAI])) == .cloud(.openAI),
           "clé du bon fournisseur → retenu")

    // « Désactivée » doit gagner sur TOUT.
    let everything = AIBackendAvailability(
        foundationModels: true, foundationModelsReadsImages: true,
        localServer: true, configuredCloudProviders: [.claude, .openAI])
    for feature in AIFeature.allCases {
        expect(AIBackendResolver.resolve(choice: .off, feature: feature,
                                         availability: everything) == nil,
               "désactivée gagne sur tout — \(feature.rawValue)")
    }
}

// MARK: - t4 — Capacité REQUISE contre capacité optionnelle

print("")
print("t4 · Capacités déclarées par fonctionnalité")
do {
    expect(AIFeature.transactionImport.optionalCapabilities.contains(.image),
           "l'import de relevés profite de l'image")
    expect(!AIFeature.transactionImport.requiredCapabilities.contains(.image),
           "…mais ne l'exige pas")
    expect(AIFeature.merchantEnrichment.optionalCapabilities.isEmpty,
           "l'identification des marchands est du texte pur")
    // L'assistant SQL est multi-tours : il s'appuie sur l'état conservé par
    // `LanguageModelSession` entre deux questions, ce qu'un backend HTTP
    // sans gestion d'historique ne fournit pas.
    expect(AIFeature.sqlAssistant.requiredCapabilities.contains(.multiTurn),
           "l'assistant SQL exige le multi-tours")
    expect(AIFeature.allCases.allSatisfy { $0.requiredCapabilities.contains(.text) },
           "toutes les fonctionnalités ont besoin du texte")
    expect(AIFeature.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.explanation.isEmpty },
           "chaque fonctionnalité est présentable dans les Réglages")
}

// MARK: - t5 — Ce qui quitte l'appareil

print("")
print("t5 · Seul le cloud fait sortir les données")
do {
    expect(AIBackendChoice.cloud(.claude).leavesDevice, "Claude sort de l'appareil")
    expect(AIBackendChoice.cloud(.openAI).leavesDevice, "OpenAI sort de l'appareil")
    // ⚠️ Le serveur local ne « sort » pas au sens où on l'entend ici : il reste
    // sur le réseau de l'utilisateur, chez lui. Le classer autrement noierait
    // l'avertissement qui compte vraiment.
    expect(!AIBackendChoice.localServer.leavesDevice, "le serveur local reste chez l'utilisateur")
    expect(!AIBackendChoice.foundationModels.leavesDevice, "Apple Intelligence est sur l'appareil")
    expect(!AIBackendChoice.automatic.leavesDevice, "automatique n'est pas un backend en soi")
    expect(!AIBackendChoice.off.leavesDevice, "désactivée n'envoie rien")

    // Toutes les options doivent être proposées dans le sélecteur, sinon un
    // backend configurable deviendrait inatteignable.
    expect(AIBackendChoice.allChoices.contains(.cloud(.claude)), "Claude proposé au choix")
    expect(AIBackendChoice.allChoices.contains(.cloud(.openAI)), "OpenAI proposé au choix")
    // automatique + Apple + serveur local + N cloud + désactivée
    expect(AIBackendChoice.allChoices.count == 4 + AICloudProvider.allCases.count,
           "aucune option orpheline", "\(AIBackendChoice.allChoices.count)")
}

// MARK: - t6 — Reprise du réglage global d'AXE T

print("")
print("t6 · Migration depuis la préférence globale")
do {
    let suite = "nemoris.ai.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        expect(false, "suite de test disponible"); return
    }
    defer { defaults.removePersistentDomain(forName: suite) }

    // Simule l'état laissé par AXE T : un utilisateur ayant choisi le serveur
    // local globalement.
    defaults.set("localServer", forKey: "ai.backendPreference")

    // ⚠️ Sans reprise, cet utilisateur repartirait en « Automatique » sur
    // TOUTES les fonctionnalités après la mise à jour — donc sur Apple
    // Intelligence, alors qu'il avait explicitement choisi son serveur.
    let encoded = try! JSONEncoder().encode(AIBackendChoice.localServer)
    for feature in AIFeature.allCases {
        defaults.set(encoded, forKey: "ai.backend.\(feature.rawValue)")
    }
    for feature in AIFeature.allCases {
        let raw = defaults.data(forKey: "ai.backend.\(feature.rawValue)")
        let decoded = raw.flatMap { try? JSONDecoder().decode(AIBackendChoice.self, from: $0) }
        expect(decoded == .localServer, "choix repris — \(feature.rawValue)")
    }

    // Aller-retour d'un choix à valeur associée : c'est le cas que le
    // `rawValue` d'une simple enum ne saurait pas porter.
    let cloud = try! JSONEncoder().encode(AIBackendChoice.cloud(.claude))
    let back = try? JSONDecoder().decode(AIBackendChoice.self, from: cloud)
    expect(back == .cloud(.claude), "un choix cloud survit à l'encodage")
}

// MARK: - Bilan

print("")
if failures == 0 {
    print("✅ \(checks) assertions, 0 échec")
} else {
    print("❌ \(failures) échec(s) sur \(checks) assertions")
    exit(1)
}

    }
}
