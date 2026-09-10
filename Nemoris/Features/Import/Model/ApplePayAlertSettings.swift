import Foundation

/// Fenêtre calendaire sur laquelle le cumul des dépenses Apple Pay en attente
/// est comparé au seuil configuré. Ancrée sur le calendrier (début de
/// jour/semaine/mois), pas une fenêtre glissante — ce qui rend "déjà notifié
/// pour cette période" trivial à mémoriser (une simple date de début à comparer).
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

    /// Début de la période courante contenant `now`.
    ///
    /// ⚠️ Le paramètre `calendar` par défaut est FIXE (`.applePayWeek`, ISO
    /// 8601 — lundi premier jour), jamais `Calendar.current` : le premier
    /// jour de semaine dépend de la région, et `.weekOfYear` était calculé à
    /// deux endroits différents (ici, et — avant cette correction —
    /// directement dans `PendingApplePayListView` avec `Calendar.current`
    /// ambiant). Cette dernière tourne dans le process AU PREMIER PLAN,
    /// tandis que cette fonction est appelée par `ApplePayAlertService`
    /// depuis l'exécution EN ARRIÈRE-PLAN de l'automatisation Raccourcis
    /// (`ImportTransactionApplePayEntityIntent`, `openAppWhenRun = false`) —
    /// deux contextes système séparés, sans garantie qu'un `Calendar.current`
    /// ambiant y résolve identiquement le premier jour de semaine. Fixer le
    /// calendrier élimine la question plutôt que de compter sur une
    /// coïncidence. `PendingApplePayListView` appelle maintenant CETTE MÊME
    /// fonction pour son groupement — plus qu'une seule définition de
    /// "semaine" dans tout le flux Apple Pay.
    func start(from now: Date, calendar: Calendar = .applePayWeek) -> Date {
        calendar.dateInterval(of: calendarComponent, for: now)?.start ?? now
    }
}

extension Calendar {
    /// Calendrier FIXE (ISO 8601 : semaine lundi-dimanche, fuseau de
    /// l'appareil) utilisé pour tout calcul de "début de semaine/jour/mois"
    /// lié à Apple Pay. Jamais `Calendar.current` ici : ses réglages
    /// (premier jour de semaine notamment) dépendent de la région ET
    /// peuvent différer entre le process de l'app au premier plan et celui,
    /// séparé, de l'automatisation Raccourcis en arrière-plan.
    static let applePayWeek: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = .current
        // Vérifié : `.iso8601` seul résout déjà `firstWeekday = 2` /
        // `minimumDaysInFirstWeek = 4` sur ce toolchain — mais posés
        // EXPLICITEMENT quand même, pour ne dépendre d'aucune version d'OS
        // ni d'un héritage silencieux de la locale du process.
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        return cal
    }()
}

/// Réglages de l'alerte "dépenses Apple Pay en attente" — lus/écrits
/// directement dans `UserDefaults.standard`, PAS via `AppState` : ils doivent
/// être lisibles depuis `ImportTransactionApplePayEntityIntent.perform()`,
/// qui s'exécute en arrière-plan (`openAppWhenRun = false`) sans accès à
/// l'environnement SwiftUI de l'app (même doctrine que `AIFeatureSettings`/
/// `AppLocalization`). L'écran de config (`ApplePayAlertSettingsView`) lit et
/// écrit ces mêmes clés depuis son propre `@State` local, sans passer par
/// `AppState` non plus — rien d'autre dans l'app n'a besoin de réagir en
/// direct à ce réglage.
enum ApplePayAlertSettings {
    private static let enabledKey = "applePay.alert.enabled"
    private static let thresholdKey = "applePay.alert.threshold"
    private static let periodKey = "applePay.alert.period"
    private static let lastNotifiedPeriodKey = "applePay.alert.lastNotifiedPeriodStart"

    /// Désactivée par défaut : contrairement au reste des notifications de
    /// l'app, celle-ci porte sur un flux (Apple Pay) que l'utilisateur vient
    /// d'activer explicitement en configurant son automatisation — pas de
    /// bruit tant qu'il n'a pas choisi un seuil.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// Seuil en euros. 100 € par défaut si jamais configuré.
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

    /// Début (ISO8601) de la dernière période pour laquelle une notification a
    /// déjà été envoyée. Évite de renotifier à chaque nouvelle dépense tant
    /// qu'on reste dans la même période.
    static var lastNotifiedPeriodStart: String? {
        get { UserDefaults.standard.string(forKey: lastNotifiedPeriodKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastNotifiedPeriodKey) }
    }
}
