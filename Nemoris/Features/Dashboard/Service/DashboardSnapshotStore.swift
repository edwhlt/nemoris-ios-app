import Foundation
import Observation

// MARK: - DashboardSnapshotStore
//
// État observable du Dashboard + cache. La vue lit `snapshot` **synchroniquement**
// dans son `body`, d'où `@MainActor @Observable` plutôt qu'un `actor` : il n'y a
// aucun état mutable partagé à protéger (le calcul est un one-shot pur), un actor
// n'apporterait qu'un hop de plus et des `await` partout.
//
// ⚠️ À injecter UNE SEULE FOIS dans l'environnement (`NemorisApp`), jamais en
// `@State` dans la vue : `DashboardView` est instanciée à deux endroits
// (`MainTabView` TabView iOS et volet détail de la sidebar macOS). Deux `@State`
// = deux caches = tout calculé deux fois.

@MainActor
@Observable
final class DashboardSnapshotStore {

    /// Données prêtes à afficher. Chaque champ est optionnel : `nil` = pas encore
    /// calculé, ce qui permet un squelette par carte plutôt qu'un squelette d'écran.
    private(set) var snapshot = DashboardSnapshot()

    /// Agrégats déjà calculés pour `loadedKey`.
    private(set) var loadedUnits: Set<DashboardAggregate> = []

    /// Vrai pendant la seconde passe (agrégats lourds : insights).
    private(set) var isLoadingExpensive = false

    /// Vrai tant que la première passe légère n'a jamais abouti.
    private(set) var isLoadingInitial = true

    /// Clé avec laquelle chaque agrégat a été calculé, restreinte à ce dont il dépend.
    /// C'est ce qui évite de tout recalculer quand seul le filtre mois change.
    private var loadedKeys: [DashboardAggregate: DashboardUnitKey] = [:]
    private var currentKey: DashboardCacheKey?
    /// Agrégats en cours de calcul — évite qu'un second appel concurrent (les deux
    /// instances de `DashboardView`, ou un `.task` relancé) recalcule la même chose.
    private var pendingUnits: Set<DashboardAggregate> = []

    // MARK: - API

    /// Calcule les agrégats dont le résultat n'est plus à jour pour cette clé.
    ///
    /// - Cache : un agrégat déjà calculé avec la même clé restreinte n'est pas
    ///   recalculé → zéro requête SQL. Basculer le filtre mois ne recalcule donc que
    ///   les catégories et les tags.
    /// - Hit partiel : seuls les agrégats manquants sont calculés puis fusionnés
    ///   (cas d'une carte que l'utilisateur vient de réactiver).
    /// - Deux passes : les agrégats légers sont publiés dès qu'ils sont prêts, les
    ///   lourds (insights) suivent à priorité basse.
    func load(units: Set<DashboardAggregate>, key: DashboardCacheKey) async {
        currentKey = key

        // On garde volontairement le snapshot précédent affiché pendant un recalcul :
        // le vider ferait clignoter l'écran à chaque changement d'exercice.
        let stale = DashboardAggregate.expanded(units).filter { unit in
            loadedKeys[unit] != key.unitKey(for: unit) && !pendingUnits.contains(unit)
        }
        guard !stale.isEmpty else { return }

        let light = stale.filter { !$0.isExpensive }
        let heavy = stale.filter(\.isExpensive)

        if !light.isEmpty {
            await run(light, key: key, priority: .userInitiated)
            isLoadingInitial = false
        }
        if !heavy.isEmpty {
            isLoadingExpensive = true
            await run(heavy, key: key, priority: .utility)
            isLoadingExpensive = false
        }
    }

    /// Force un recalcul complet à la prochaine demande, sans vider l'affichage.
    func invalidate() {
        loadedKeys = [:]
        loadedUnits = []
    }

    // MARK: - Private

    private func run(
        _ units: Set<DashboardAggregate>,
        key: DashboardCacheKey,
        priority: TaskPriority
    ) async {
        pendingUnits.formUnion(units)
        defer { pendingUnits.subtract(units) }

        let period = key.period
        let partial = await Task.detached(priority: priority) {
            DashboardSnapshotBuilder.build(units: units, period: period)
        }.value

        // La clé a pu changer pendant le calcul (l'utilisateur a changé d'exercice) :
        // le résultat est alors potentiellement périmé, on le jette plutôt que
        // d'afficher les chiffres d'une autre période. Le `.task(id:)` de la vue a
        // déjà relancé une passe pour la nouvelle clé.
        guard key == currentKey else { return }

        snapshot = snapshot.merging(partial)
        loadedUnits.formUnion(units)
        for unit in units { loadedKeys[unit] = key.unitKey(for: unit) }
    }
}
