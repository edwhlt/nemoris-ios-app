import Foundation

/// Tells the Dashboard that an Apple Pay expense was dropped off, dismissed
/// or purged.
///
/// Necessary because the drop-off comes from a separate process (the
/// Shortcuts automation `ImportTransactionApplePayEntityIntent`,
/// `openAppWhenRun = false`) which has no access to `AppState` to bump
/// `dataRefreshToken` itself. Without this nudge, the Dashboard banner stays
/// frozen on the count cached at the last load, even once the app is
/// reopened: `DashboardSnapshotStore` only recomputes when the cache key
/// (derived from `dataRefreshToken`) has changed.
///
/// Called on every return to the foreground (`NemorisApp`, `scenePhase ==
/// .active`).
@MainActor
enum ApplePayDashboardSync {
    private static let lastKnownPendingCountKey = "applePay.lastKnownPendingCount"

    /// Checks the current `pending` entry count and tells the Dashboard if
    /// it has moved since the last check.
    static func syncIfNeeded(repository: PendingApplePayRepository = PendingApplePayRepository()) {
        let count = repository.fetchEntries(status: .pending).count
        notifyIfChanged(count)
    }

    /// Posts the notification ONLY when the pending count has moved —
    /// avoids forcing a full Dashboard recomputation (`NemorisApp` bumps
    /// `appState.dataRefreshToken` on it, which invalidates the WHOLE cache,
    /// not just `.pendingApplePay`) on every foreground when nothing has
    /// changed.
    static func notifyIfChanged(_ count: Int) {
        let last = UserDefaults.standard.integer(forKey: lastKnownPendingCountKey)
        guard count != last else { return }
        UserDefaults.standard.set(count, forKey: lastKnownPendingCountKey)
        NotificationCenter.default.post(name: .nemorisApplePayDataDidChange, object: nil)
    }
}

extension Notification.Name {
    /// A `pending_apple_pay_entries` row was dropped off, dismissed or
    /// purged.
    static let nemorisApplePayDataDidChange = Notification.Name("nemorisApplePayDataDidChange")
}
