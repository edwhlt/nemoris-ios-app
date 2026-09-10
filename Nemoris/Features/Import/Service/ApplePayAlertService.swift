import Foundation
import UserNotifications

/// Notifies the user when the running total of still-`pending` Apple Pay
/// expenses exceeds the configured threshold (`ApplePayAlertSettings`) over
/// the chosen period (day/week/month).
///
/// Called right after each `PendingApplePayRepository.addEntry` — including
/// from `ImportTransactionApplePayEntityIntent.perform()`, which runs in the
/// background (`openAppWhenRun = false`). That is precisely the scenario
/// this alert serves: the user never opens the app, and the notification is
/// the only signal they get.
///
/// Permission is requested *lazily* (only on the 1st alert actually due, not
/// on the first drop-off). If the user declines, this is a silent no-op —
/// the entry stays visible in the Dashboard's separate list anyway.
enum ApplePayAlertService {

    private static let identifierPrefix = "applepay_alert_"

    /// Checks the current period's total and notifies if the threshold is
    /// crossed AND no notification was already sent for THIS period — a new
    /// expense within the same period doesn't send a second one.
    static func checkAndNotifyIfNeeded(repository: PendingApplePayRepository = PendingApplePayRepository()) async {
        guard ApplePayAlertSettings.isEnabled else { return }

        let period = ApplePayAlertSettings.period
        let periodStart = period.start(from: Date())
        let periodKey = Self.periodKey(for: periodStart)

        guard ApplePayAlertSettings.lastNotifiedPeriodStart != periodKey else { return }

        let total = abs(repository.pendingTotal(since: periodStart))
        guard total >= ApplePayAlertSettings.threshold else { return }

        guard await requestPermissionIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Dépenses Apple Pay élevées"
        content.body = "\(formatAmount(total)) \(period.label.lowercased()) — seuil : \(formatAmount(ApplePayAlertSettings.threshold))"
        content.sound = .default

        // `trigger: nil` = immediate delivery, consistent with a threshold
        // crossed JUST NOW (unlike `BudgetNotificationService`, which
        // schedules for a FUTURE due date).
        let request = UNNotificationRequest(
            identifier: "\(identifierPrefix)\(periodKey)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            ApplePayAlertSettings.lastNotifiedPeriodStart = periodKey
        } catch {
            print("[ApplePayAlertService] schedule error: \(error.localizedDescription)")
        }
    }

    // MARK: - Permission

    private static func requestPermissionIfNeeded() async -> Bool {
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
                print("[ApplePayAlertService] permission error: \(error.localizedDescription)")
                return false
            }
        @unknown default:
            return false
        }
    }

    // MARK: - Formatting
    //
    // A static service with no access to the SwiftUI environment — same
    // convention as `BudgetNotificationService`: `AppLocalization` reads the
    // language preference straight from `UserDefaults`.

    private static func formatAmount(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.locale = AppLocalization.locale
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    /// Stable key identifying a period, derived from its START (already
    /// aligned by `Calendar.dateInterval`) — the same value for any date
    /// falling in the same day/week/month. The formatter is created on every
    /// call rather than cached in a static property: `ISO8601DateFormatter`
    /// isn't `Sendable`, and a `static let` would make it a mutable global
    /// rejected by Swift 6 strict concurrency (same constraint as
    /// `PendingApplePayRepository.isoFormatter`, with no instance to host it
    /// here since this service is a stateless `enum`).
    private static func periodKey(for start: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: start)
    }
}
