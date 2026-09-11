import Foundation
import UserNotifications

/// Schedules/cancels the "Nemoris import pending" reminders.
///
/// Permission is requested *lazily* (only when the user starts their first
/// import — not at launch).
///
/// One reminder per session, identified by `import_session_<UUID>`, fired
/// every 12 hours through a repeating `UNTimeIntervalNotificationTrigger`.
enum ImportNotificationService {

    static let intervalSeconds: TimeInterval = 12 * 3600

    /// Requests the notification permission, then schedules the reminder. Call it
    /// when a new import starts. If permission is denied, nothing happens
    /// (silent, no error — the in-app banner is enough).
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

    /// Updates the notification body (remaining row count) by reusing the same
    /// `identifier` (the system silently replaces it).
    /// Doesn't ask for permission again — if it wasn't granted, this is a no-op.
    static func updateReminder(forSessionId id: UUID, pendingRows: Int) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        await scheduleReminder(forSessionId: id, pendingRows: pendingRows)
    }

    /// Cancels a session's reminder (call it on completion or cancel).
    static func cancelReminder(forSessionId id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier(for: id)])
    }

    private static func identifier(for id: UUID) -> String {
        "import_session_\(id.uuidString)"
    }
}
