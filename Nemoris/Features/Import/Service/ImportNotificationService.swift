import Foundation
import UserNotifications

/// planifie/annule les rappels "Import Nemoris en attente".
///
/// Permission demandée *lazy* (uniquement au moment où l'utilisateur lance son premier
/// import — pas au launch), conformément à la convention CLAUDE.md §6.7.
///
/// Un rappel par session, identifié par `import_session_<UUID>`, déclenché toutes les
/// 12 heures via un `UNTimeIntervalNotificationTrigger` répété.
enum ImportNotificationService {

    static let intervalSeconds: TimeInterval = 12 * 3600

    /// Demande la permission notifications puis planifie le rappel. À appeler au démarrage
    /// d'un nouvel import. Si la permission est refusée, on ne fait rien (silencieux,
    /// pas d'erreur — le bandeau dans l'app suffit).
    static func scheduleReminder(forSessionId id: UUID, pendingRows: Int) async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                print("[ImportNotificationService] permission refused, skipping reminder")
                return
            }
        } catch {
            print("[ImportNotificationService] permission error: \(error.localizedDescription)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Import Nemoris en attente"
        content.body = pendingRows > 0
            ? "Vous avez encore \(pendingRows) transaction(s) à classer. Reprenez votre import."
            : "Une session d'import est encore ouverte. Finalisez-la ou annulez-la."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: intervalSeconds, repeats: true)
        let request = UNNotificationRequest(identifier: identifier(for: id),
                                            content: content,
                                            trigger: trigger)
        do {
            try await center.add(request)
        } catch {
            print("[ImportNotificationService] schedule error: \(error.localizedDescription)")
        }
    }

    /// Met à jour le body de la notification (compteur de lignes restantes) en
    /// réutilisant la même `identifier` (le système remplace silencieusement).
    /// Ne re-demande pas la permission — si elle n'a pas été accordée, on no-op.
    static func updateReminder(forSessionId id: UUID, pendingRows: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        await scheduleReminder(forSessionId: id, pendingRows: pendingRows)
    }

    /// Annule le rappel d'une session (à appeler à la complétion ou cancel).
    static func cancelReminder(forSessionId id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier(for: id)])
    }

    private static func identifier(for id: UUID) -> String {
        "import_session_\(id.uuidString)"
    }
}
