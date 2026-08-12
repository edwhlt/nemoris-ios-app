import Testing

/// Suite parente de tous les tests qui passent par `StubURLProtocol`.
///
/// ⚠️ `.serialized` posé sur une suite ne sérialise QUE ses propres tests —
/// deux suites distinctes tournent en parallèle. Or l'interception réseau est
/// un état global du processus : `start()` vide la table, donc une suite qui
/// démarre efface les réponses armées par une autre. Symptôme observé : le
/// premier test de chaque suite passe, tous les suivants échouent.
///
/// Regrouper les suites réseau SOUS ce parent règle le problème par
/// construction — le trait se propage à toute la descendance, et un futur
/// contributeur n'a rien à savoir : il lui suffit de nicher sa suite ici.
@Suite("Réseau", .serialized)
struct NetworkSeam {}
