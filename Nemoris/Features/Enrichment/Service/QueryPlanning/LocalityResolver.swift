import Foundation

// Contrat de résolution d'une localité.
// ⚠️ FICHIER PUR : `import Foundation` UNIQUEMENT.
//
// Pourquoi le planificateur reçoit une localité DÉJÀ RÉSOLUE plutôt qu'un résolveur :
//
// `MerchantQueryPlanner.extract` et `.plan` doivent rester des fonctions pures totales,
// testables sans mock ni témoin de protocole. Si le plan portait une localité qu'un
// résolveur remplissait ensuite, `attempts` — précisément ce que les tests doivent
// affirmer — n'existerait qu'après une entrée/sortie réseau, et le plan deviendrait un
// objet mutable en deux temps dont l'ordre de cascade ne serait observable qu'à travers
// un bouchon réseau. C'est exactement la forme intestable qu'on fuit.
//
// L'ordre d'appel est donc, chez l'exécuteur : extract → resolve → plan → execute.
// Une seule direction, aucun cycle.
protocol LocalityResolver: Sendable {
    /// Résout le premier fragment reconnaissable parmi `tokens`.
    /// Renvoie nil si aucun n'est une commune connue — ce n'est PAS un échec :
    /// le fragment reste utilisé comme texte de tri sur les adresses des candidats.
    func resolve(_ tokens: [LocalityToken], countryHint: String?) async -> ResolvedLocality?
}
