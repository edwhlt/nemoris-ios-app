import Foundation

// AXE S — Budget d'une recherche marchand.
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT.
//
// Le budget est une DONNÉE, pas une politique éparpillée dans l'exécuteur. Conséquence
// utile : `plan.attempts.count <= budget.maxAttempts` est une assertion de test pure —
// le coût d'une recherche est auditable sans rien exécuter ni brancher le réseau.

struct SearchBudget: Hashable, Sendable {
    /// Plafond dur d'appels réseau. L'exécuteur décrémente et s'arrête.
    var maxRequests: Int
    /// Plafond de tentatives planifiées (`plan.attempts.count`).
    var maxAttempts: Int
    /// Délai mural global, en secondes.
    var deadline: TimeInterval
    /// Autorise un appel au modèle de langage pour raffiner le plan.
    var allowLLM: Bool
    /// Autorise les recherches cartographiques.
    var allowPlaces: Bool
    /// Autorise le rejeu final incluant les entreprises fermées.
    var includeCeased: Bool
    /// `limite_matching_etablissements` des requêtes registre.
    var matchingLimit: Int

    /// Import de masse : chaque libellé paie son coût N fois. Aucune IA (2 à 5 s par
    /// libellé la rendrait inutilisable sur 300 lignes), aucune carto, 1 seule requête
    /// registre après résolution de commune (elle-même presque toujours en cache).
    static let batch = SearchBudget(
        maxRequests: 2, maxAttempts: 2, deadline: 2.0,
        allowLLM: false, allowPlaces: false, includeCeased: false, matchingLimit: 10
    )

    /// L'utilisateur regarde l'écran et attend : on peut dépenser davantage.
    static let interactive = SearchBudget(
        maxRequests: 6, maxAttempts: 6, deadline: 6.0,
        allowLLM: true, allowPlaces: true, includeCeased: true, matchingLimit: 20
    )

    /// « Recherche approfondie », déclenchée explicitement sur une ligne précise.
    static let deep = SearchBudget(
        maxRequests: 10, maxAttempts: 8, deadline: 15.0,
        allowLLM: true, allowPlaces: true, includeCeased: true, matchingLimit: 100
    )

    /// Consommation observée, remontée à l'UI (« 18 requêtes · 42 libellés · 3,4 s »).
    /// De la perf qu'on voit est de la perf à laquelle on peut se fier.
    struct Usage: Hashable, Sendable {
        var requests: Int = 0
        var cacheHits: Int = 0
        var elapsed: TimeInterval = 0

        var totalLookups: Int { requests + cacheHits }
    }
}
