import Foundation
import UserNotifications

/// planifie/annule les rappels "Échéance budget dans 3 jours".
///
/// Permission demandée *lazy* (uniquement au premier scheduling, pas au launch),
/// conformément à la convention CLAUDE.md §6.7. Si l'utilisateur refuse, no-op silencieux.
///
/// Architecture :
///   - 1 notification par prévision PENDING dont `expectedDate - 3 jours >= maintenant`.
///   - Identifier : `budget_prevision_<id>` → permet de cancel quand l'utilisateur skip/match.
///   - Trigger : `UNCalendarNotificationTrigger` daté pour le j-3 à 9h00 locale.
///   - Idempotent : `removePendingNotificationRequests` avant chaque add (re-schedule safe).
///
/// Hooks ViewModel :
///   - Après `regeneratePrevisions(for:)` → `rescheduleForPattern(...)`
///   - `skipPrevision` / `matchPrevision` → `cancel(forPrevisionId:)`
///   - `deletePattern` → `cancelAll(forPatternId:)`
///   - `togglePattern` désactivé → `cancelAll(forPatternId:)`
enum BudgetNotificationService {

    /// Heure du j-3 à laquelle on déclenche la notif (locale appareil).
    static let notifyHour = 9
    static let notifyMinute = 0

    /// Décalage avant l'échéance (en jours). 3 = j-3.
    static let leadDays = 3

    // MARK: - Permission

    /// Demande la permission notifications si pas encore décidée.
    /// Retourne `true` si autorisée (in fine), `false` sinon.
    @discardableResult
    static func requestPermissionIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                print("[BudgetNotificationService] permission error: \(error.localizedDescription)")
                return false
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Schedule

    /// Planifie le rappel j-3 pour une prévision PENDING.
    /// No-op si :
    ///   - status != .pending
    ///   - j-3 est déjà passé (expectedDate trop proche ou dans le passé)
    ///   - permission refusée
    static func schedule(for prevision: BudgetPrevision, patternName: String) async {
        guard prevision.status == .pending else { return }

        let cal = Calendar.current
        guard let triggerDate = cal.date(byAdding: .day, value: -leadDays, to: prevision.expectedDate) else { return }
        guard triggerDate > Date() else { return } // j-3 déjà passé

        guard await requestPermissionIfNeeded() else { return }

        // Idempotent : remove ancien avant re-add
        cancel(forPrevisionId: prevision.id)

        var dateComps = cal.dateComponents([.year, .month, .day], from: triggerDate)
        dateComps.hour = notifyHour
        dateComps.minute = notifyMinute

        let content = UNMutableNotificationContent()
        content.title = "Échéance dans 3 jours"
        let amountText = formatAmount(prevision.amount)
        content.body = "\(patternName) — \(amountText) prévu le \(formatDate(prevision.expectedDate))"
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier(for: prevision.id),
                                            content: content,
                                            trigger: trigger)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            print("[BudgetNotificationService] schedule error: \(error.localizedDescription)")
        }
    }

    /// Re-schedule en masse pour toutes les prévisions PENDING d'un pattern.
    /// À appeler après `BudgetRepository.regeneratePrevisions(for:)` côté ViewModel.
    static func rescheduleForPattern(patternId: Int, patternName: String, previsions: [BudgetPrevision]) async {
        let relevant = previsions.filter { $0.recurringPatternId == patternId && $0.status == .pending }
        for prev in relevant {
            await schedule(for: prev, patternName: patternName)
        }
    }

    // MARK: - Cancel

    /// Annule la notif d'une prévision (à appeler sur skip / match / delete).
    static func cancel(forPrevisionId id: Int) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier(for: id)])
    }

    /// Annule toutes les notifs d'un pattern (delete ou désactivation).
    static func cancelAll(forPatternId patternId: Int, previsions: [BudgetPrevision]) {
        let ids = previsions
            .filter { $0.recurringPatternId == patternId }
            .map { identifier(for: $0.id) }
        guard !ids.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Helpers

    private static func identifier(for previsionId: Int) -> String {
        "budget_prevision_\(previsionId)"
    }

    private static func formatAmount(_ amount: Double) -> String {
        let f = NumberFormatter()
        // Locale forcée fr_FR : service statique, pas d'accès à l'environnement
        // SwiftUI — cf. commentaire équivalent dans InsightEngine.swift.
        f.locale = Locale(identifier: "fr_FR")
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }
}
