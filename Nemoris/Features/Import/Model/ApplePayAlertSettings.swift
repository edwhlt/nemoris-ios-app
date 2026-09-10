import Foundation

/// Calendar window over which the running total of pending Apple Pay
/// spending is compared to the configured threshold. Anchored on the
/// calendar (start of day/week/month), not a sliding window — which makes
/// "already notified for this period" trivial to remember (a single start
/// date to compare).
enum ApplePayAlertPeriod: String, CaseIterable, Codable {
    case day
    case week
    case month

    var label: String {
        switch self {
        case .day:   return "Aujourd'hui"
        case .week:  return "Cette semaine"
        case .month: return "Ce mois-ci"
        }
    }

    private var calendarComponent: Calendar.Component {
        switch self {
        case .day:   return .day
        case .week:  return .weekOfYear
        case .month: return .month
        }
    }

    /// Start of the current period containing `now`.
    ///
    /// The default `calendar` parameter is FIXED (`.applePayWeek`, ISO 8601 —
    /// Monday first), never `Calendar.current`: the first weekday depends on
    /// the region, and `.weekOfYear` must not be computed in two places with
    /// two different calendars. The list view runs in the FOREGROUND
    /// process, while this function is also called by `ApplePayAlertService`
    /// from the BACKGROUND execution of the Shortcuts automation
    /// (`ImportTransactionApplePayEntityIntent`, `openAppWhenRun = false`) —
    /// two separate system contexts, with no guarantee that an ambient
    /// `Calendar.current` resolves the first weekday identically in both.
    /// Fixing the calendar removes the question rather than relying on a
    /// coincidence. `PendingApplePayListView` calls THIS SAME function for
    /// its grouping — a single definition of "week" across the whole Apple
    /// Pay flow.
    func start(from now: Date, calendar: Calendar = .applePayWeek) -> Date {
        calendar.dateInterval(of: calendarComponent, for: now)?.start ?? now
    }
}

extension Calendar {
    /// FIXED calendar (ISO 8601: Monday-to-Sunday week, device time zone)
    /// used for every "start of week/day/month" computation tied to Apple
    /// Pay. Never `Calendar.current` here: its settings (the first weekday
    /// in particular) depend on the region AND can differ between the app's
    /// foreground process and the separate background process of the
    /// Shortcuts automation.
    static let applePayWeek: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        // `.iso8601` alone already resolves `firstWeekday = 2` /
        // `minimumDaysInFirstWeek = 4` on this toolchain — but they are set
        // EXPLICITLY anyway, so nothing depends on an OS version or on a
        // silent inheritance from the process locale.
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }()
}

/// Settings for the "pending Apple Pay spending" alert — read from and
/// written to `UserDefaults.standard` directly, NOT through `AppState`: they
/// must be readable from `ImportTransactionApplePayEntityIntent.perform()`,
/// which runs in the background (`openAppWhenRun = false`) with no access to
/// the app's SwiftUI environment (same doctrine as `AIFeatureSettings` /
/// `AppLocalization`). The settings screen (`ApplePayAlertSettingsView`)
/// reads and writes those same keys from its own local `@State`, also
/// without going through `AppState` — nothing else in the app needs to react
/// live to this setting.
enum ApplePayAlertSettings {
    private static let enabledKey = "applePay.alert.enabled"
    private static let thresholdKey = "applePay.alert.threshold"
    private static let periodKey = "applePay.alert.period"
    private static let lastNotifiedPeriodKey = "applePay.alert.lastNotifiedPeriodStart"

    /// Disabled by default: unlike the app's other notifications, this one
    /// concerns a flow (Apple Pay) the user has only just enabled explicitly
    /// by configuring their automation — no noise until they've chosen a
    /// threshold.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Threshold in euros. €100 by default when never configured.
    static var threshold: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: thresholdKey)
            return stored > 0 ? stored : 100
        }
        set { UserDefaults.standard.set(newValue, forKey: thresholdKey) }
    }

    static var period: ApplePayAlertPeriod {
        get { ApplePayAlertPeriod(rawValue: UserDefaults.standard.string(forKey: periodKey) ?? "") ?? .week }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: periodKey) }
    }

    /// Start (ISO8601) of the last period for which a notification was
    /// already sent. Avoids re-notifying on every new expense while still
    /// inside the same period.
    static var lastNotifiedPeriodStart: String? {
        get { UserDefaults.standard.string(forKey: lastNotifiedPeriodKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastNotifiedPeriodKey) }
    }
}
