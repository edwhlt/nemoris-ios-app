import Foundation
import UserNotifications

/// Notifie l'utilisateur quand le cumul des dépenses Apple Pay encore
/// `pending` dépasse le seuil configuré (`ApplePayAlertSettings`) sur la
/// période choisie (jour/semaine/mois).
///
/// Appelée juste après chaque `PendingApplePayRepository.addEntry` — y
/// compris depuis `ImportTransactionApplePayEntityIntent.perform()`, qui
/// s'exécute en arrière-plan (`openAppWhenRun = false`). C'est précisément le
/// scénario que cette alerte sert : l'utilisateur n'ouvre jamais l'app,
/// la notification est le seul signal qu'il reçoit.
///
/// Permission demandée *lazy* (uniquement à la 1ère alerte réellement due, pas
/// au premier dépôt), conformément à la convention CLAUDE.md §6.7. Si
/// l'utilisateur refuse, no-op silencieux — l'entrée reste visible dans la
/// liste "à part" du Dashboard de toute façon.
enum ApplePayAlertService {

    private static let identifierPrefix = "applepay_alert_"

    /// Vérifie le cumul de la période courante et notifie si le seuil est
    /// franchi ET qu'on n'a pas déjà notifié pour CETTE période — une
    /// nouvelle dépense dans la même période ne renvoie pas une 2e notif.
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

        // `trigger: nil` = livraison immédiate, cohérent avec un seuil qui vient
        // d'être franchi À L'INSTANT (contrairement à `BudgetNotificationService`,
        // qui planifie pour une échéance FUTURE).
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

    // MARK: - Formatage
    //
    // Service statique sans accès à l'environnement SwiftUI — même convention
    // que `BudgetNotificationService` : `AppLocalization` relit la préférence
    // de langue directement depuis `UserDefaults`.

    private static func formatAmount(_ amount: Double) -> String {
        let f = NumberFormatter()
        f.locale = AppLocalization.locale
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    /// Clé stable identifiant une période, dérivée de son DÉBUT (déjà aligné
    /// par `Calendar.dateInterval`) — même valeur pour toute date retombant
    /// dans le même jour/semaine/mois. Formateur créé à chaque appel plutôt
    /// que mis en cache dans une propriété statique : `ISO8601DateFormatter`
    /// n'est pas `Sendable`, un `static let` en ferait une variable globale
    /// mutable rejetée par la concurrence stricte Swift 6 (même contrainte
    /// que `PendingApplePayRepository.isoFormatter`, ici sans instance où la
    /// loger puisque ce service est un `enum` sans état).
    private static func periodKey(for start: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: start)
    }
}
