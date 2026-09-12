import Foundation
import UserNotifications

/// schedules/cancels "Budget due date in 3 days" reminders.
///
/// Permission requested *lazily* (only on the first scheduling, not at launch),
/// per the CLAUDE.md §6.7 convention. If the user refuses, a silent no-op.
///
/// Architecture:
///   - 1 notification per PENDING prevision where `expectedDate - 3 days >= now`.
///   - Identifier: `budget_prevision_<id>` → lets it be canceled when the user skips/matches.
///   - Trigger: `UNCalendarNotificationTrigger` dated for j-3 at 9:00 AM local time.
///   - Idempotent: `removePendingNotificationRequests` before every add (safe to re-schedule).
///
/// ViewModel hooks:
///   - After `regeneratePrevisions(for:)` → `rescheduleForPattern(...)`
///   - `skipPrevision` / `matchPrevision` → `cancel(forPrevisionId:)`
///   - `deletePattern` → `cancelAll(forPatternId:)`
///   - `togglePattern` disabled → `cancelAll(forPatternId:)`
enum BudgetNotificationService {

    /// Time of day at j-3 when the notification fires (device local time).
    static let notifyHour = 9
    static let notifyMinute = 0

    /// Offset before the due date (in days). 3 = j-3.
    static let leadDays = 3

    // MARK: - Permission

    /// Requests notification permission if not yet decided.
    /// Returns `true` if authorized (in the end), `false` otherwise.
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

    /// Schedules the j-3 reminder for a PENDING prevision.
    /// A no-op if:
    ///   - status != .pending
    ///   - j-3 has already passed (expectedDate too close or in the past)
    ///   - permission was refused
    static func schedule(for prevision: BudgetPrevision, patternName: String) async {
        guard prevision.status == .pending else { return }

        let cal = Calendar.current
        guard let triggerDate = cal.date(byAdding: .day, value: -leadDays, to: prevision.expectedDate) else { return }
        guard triggerDate > Date() else { return } // j-3 already past

        guard await requestPermissionIfNeeded() else { return }

        // Idempotent: remove the old one before re-adding
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

    /// Bulk re-schedule for every PENDING prevision of a pattern.
    /// Call after `BudgetRepository.regeneratePrevisions(for:)` on the ViewModel side.
    static func rescheduleForPattern(patternId: Int, patternName: String, previsions: [BudgetPrevision]) async {
        let relevant = previsions.filter { $0.recurringPatternId == patternId && $0.status == .pending }
        for prev in relevant {
            await schedule(for: prev, patternName: patternName)
        }
    }

    // MARK: - Cancel

    /// Cancels a prevision's notification (call on skip / match / delete).
    static func cancel(forPrevisionId id: Int) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [identifier(for: id)])
    }

    /// Cancels every notification of a pattern (delete or disabling).
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
        // A static service, no access to the SwiftUI environment — AppLocalization
        // re-reads the same language preference directly from UserDefaults.
        f.locale = AppLocalization.locale
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    private static func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = AppLocalization.locale
        f.dateFormat = "d MMM"
        return f.string(from: date)
    }
}
