import Foundation

/// Prévient le Dashboard qu'une dépense Apple Pay a été déposée, écartée, ou
/// purgée.
///
/// Nécessaire car le dépôt vient d'un process séparé (automatisation
/// Raccourcis, `ImportTransactionApplePayEntityIntent`, `openAppWhenRun =
/// false`) qui n'a aucun accès à `AppState` pour bumper `dataRefreshToken`
/// lui-même. Sans ce nudge, le bandeau du Dashboard reste figé sur le compte
/// mis en cache lors du dernier chargement, même une fois l'app rouverte :
/// `DashboardSnapshotStore` ne recalcule que si la clé de cache (dérivée de
/// `dataRefreshToken`) a changé.
///
/// Appelé à chaque retour au premier plan (`NemorisApp`, `scenePhase ==
/// .active`) — extrait de l'ancien `ApplePayResolutionService` (résolution
/// auto retirée, ce nudge reste nécessaire indépendamment).
@MainActor
enum ApplePayDashboardSync {
    private static let lastKnownPendingCountKey = "applePay.lastKnownPendingCount"

    /// Vérifie le nombre d'entrées `pending` actuel et prévient le Dashboard
    /// s'il a bougé depuis la dernière vérification.
    static func syncIfNeeded(repository: PendingApplePayRepository = PendingApplePayRepository()) {
        let count = repository.fetchEntries(status: .pending).count
        notifyIfChanged(count)
    }

    /// Poste la notification SEULEMENT si le nombre en attente a bougé —
    /// évite de forcer un recalcul complet du Dashboard (`NemorisApp` bumpe
    /// `appState.dataRefreshToken` dessus, ce qui invalide TOUT le cache, pas
    /// seulement `.pendingApplePay`) à chaque foreground alors que rien n'a changé.
    static func notifyIfChanged(_ count: Int) {
        let last = UserDefaults.standard.integer(forKey: lastKnownPendingCountKey)
        guard count != last else { return }
        UserDefaults.standard.set(count, forKey: lastKnownPendingCountKey)
        NotificationCenter.default.post(name: .nemorisApplePayDataDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Une entrée `pending_apple_pay_entries` a été déposée, écartée, ou
    /// purgée.
    static let nemorisApplePayDataDidChange = Notification.Name("nemorisApplePayDataDidChange")
}
