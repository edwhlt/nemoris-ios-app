import Foundation
import Observation

// MARK: - DashboardSnapshotStore
//
// The Dashboard's observable state + cache. The view reads `snapshot` **synchronously**
// in its `body`, hence `@MainActor @Observable` rather than an `actor`: there's
// no shared mutable state to protect (the computation is a pure one-shot), an actor
// would only add an extra hop and `await`s everywhere.
//
// ⚠️ Inject it ONCE into the environment (`NemorisApp`), never as
// `@State` in the view: `DashboardView` is instantiated in two places
// (`MainTabView`'s iOS TabView and the macOS sidebar's detail pane). Two `@State`s
// = two caches = everything computed twice.

@MainActor
@Observable
final class DashboardSnapshotStore {

    /// Data ready to display. Each field is optional: `nil` = not yet
    /// computed, which allows a per-card skeleton rather than a whole-screen one.
    private(set) var snapshot = DashboardSnapshot()

    /// Aggregates already computed for `loadedKey`.
    private(set) var loadedUnits: Set<DashboardAggregate> = []

    /// True during the second pass (heavy aggregates: insights).
    private(set) var isLoadingExpensive = false

    /// True as long as the first, light pass has never completed.
    private(set) var isLoadingInitial = true

    /// The key each aggregate was computed with, restricted to what it depends on.
    /// This is what avoids recomputing everything when only the month filter changes.
    private var loadedKeys: [DashboardAggregate: DashboardUnitKey] = [:]
    private var currentKey: DashboardCacheKey?
    /// Aggregates currently being computed — keeps a second concurrent call (the
    /// two `DashboardView` instances, or a relaunched `.task`) from recomputing the same thing.
    private var pendingUnits: Set<DashboardAggregate> = []

    // MARK: - API

    /// Computes the aggregates whose result is no longer up to date for this key.
    ///
    /// - Cache: an aggregate already computed with the same restricted key isn't
    ///   recomputed → zero SQL query. Toggling the month filter therefore only recomputes
    ///   categories and tags.
    /// - A partial hit: only the missing aggregates are computed then merged
    ///   (the case of a card the user just re-enabled).
    /// - Two passes: light aggregates are published as soon as they're ready, the
    ///   heavy ones (insights) follow at low priority.
    func load(units: Set<DashboardAggregate>, key: DashboardCacheKey) async {
        currentKey = key

        // The previous snapshot is deliberately kept displayed during a recompute:
        // clearing it would make the screen flicker on every fiscal-year change.
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

    /// Forces a full recompute on the next request, without clearing the display.
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

        // The key may have changed during the computation (the user switched fiscal
        // year): the result is then potentially stale, so it's discarded rather
        // than showing another period's figures. The view's `.task(id:)` has
        // already relaunched a pass for the new key.
        guard key == currentKey else { return }

        snapshot = snapshot.merging(partial)
        loadedUnits.formUnion(units)
        for unit in units { loadedKeys[unit] = key.unitKey(for: unit) }
    }
}
