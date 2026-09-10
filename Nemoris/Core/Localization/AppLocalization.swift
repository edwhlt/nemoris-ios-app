import Foundation
import SwiftUI

// MARK: - AppLocalization
//
// Résolution de chaînes localisées dans la langue CHOISIE DANS L'APP (picker
// des Réglages → `AppState.preferredLanguage`), et pas dans celle du système.
//
// ⚠️⚠️ LE PIÈGE CENTRAL, mesuré (2026-08-25) — `String(localized:locale:)`
// N'UTILISE PAS `locale:` POUR CHOISIR LA LANGUE.
//
// Le paramètre `locale:` ne pilote QUE le formatage des valeurs interpolées
// (nombres, dates). Le lookup de la clé, lui, passe par le `bundle:` — dont le
// défaut est `Bundle.main`, qui résout sa langue d'après les préférences
// SYSTÈME, figées au lancement du process. Vérifié sur machine en anglais :
//
//     String(localized: "Données", locale: Locale(identifier: "fr_FR"))  →  "Data"
//
// C'est la raison pour laquelle l'ancienne version de ce fichier traduisait
// toujours en langue système, quel que soit le picker — et pourquoi les
// `AppLocalization.string(...)` posés dans des `Text` ont dû être retirés un
// par un.
//
// **Le seul axe qui pilote réellement la langue est le BUNDLE** : en pointant
// le sous-bundle `<lang>.lproj` (qui ne contient qu'une langue), le lookup ne
// peut pas retomber ailleurs. Mesuré, et l'interpolation est préservée :
//
//     String(localized: "\(n) compte…", bundle: frLproj)  →  "3 comptes" (FR)
//
// Les deux axes sont orthogonaux et se cumulent : `bundle` = la langue,
// `locale` = le formatage des nombres.
//
// ── Deux problèmes distincts, deux remèdes ───────────────────────────────────
//
// 1. CORRECTION (ce fichier) : le lookup vise `<lang>.lproj`.
// 2. RÉACTIVITÉ (les modificateurs en bas de fichier) : une `String` résolue
//    est une valeur morte — rien ne la recalcule quand la langue change. Les
//    `.localizedNavigationTitle` / `.localizedHelp` / `.localizedAccessibilityLabel`
//    lisent `@Environment(\.locale)`, ce qui en fait une VRAIE dépendance
//    SwiftUI : au changement de langue, le modificateur est réévalué et produit
//    une chaîne fraîche.
//
// ── Quand utiliser quoi ──────────────────────────────────────────────────────
//
// • Texte de CONTENU (`Text`, `Label`, `Button`…) : ne rien faire de spécial —
//   `Text("littéral")` et `Text(LocalizedStringKey(runtimeValue))` respectent
//   déjà `\.locale` d'environnement (injecté à la racine dans `NemorisApp`) et
//   se rafraîchissent seuls. **Ne jamais y remettre `AppLocalization.string`.**
// • Chrome NATIVE (`.navigationTitle`, `.help`, `.accessibilityLabel`) : ces
//   API pontent vers AppKit/UIKit et ne consultent PAS `\.locale` — d'où les
//   modificateurs dédiés en bas de ce fichier.
// • Hors SwiftUI (moteurs purs, services statiques : `InsightEngine`,
//   `AlertEngine`, `LiveSyncRegistry`, `BudgetNotificationService`…) :
//   `AppLocalization.string(...)`, qui lit la préférence dans `UserDefaults`.
enum AppLocalization {

    // MARK: - Langue courante

    /// Code de langue à utiliser pour le lookup, d'après la préférence stockée.
    /// `nil` = « système » : on laisse alors `Bundle.main` faire son travail
    /// normal, ce qui est exactement le comportement attendu dans ce mode.
    ///
    /// Miroir de `AppState.preferredLanguage` (même clé `UserDefaults`) — c'est
    /// ce qui permet aux moteurs purs, sans accès à l'environnement SwiftUI, de
    /// suivre le même réglage sans dépendre d'`AppState`.
    private static var preferredLanguageCode: String? {
        switch UserDefaults.standard.string(forKey: "appLanguage") ?? "system" {
        case "fr": return "fr"
        case "en": return "en"
        default:   return nil
        }
    }

    /// Locale pour le FORMATAGE (nombres, dates). Ne pilote pas la traduction —
    /// cf. l'avertissement en tête de fichier.
    static var locale: Locale {
        switch UserDefaults.standard.string(forKey: "appLanguage") ?? "system" {
        case "fr": return Locale(identifier: "fr_FR")
        case "en": return Locale(identifier: "en_US")
        default:   return Locale.current
        }
    }

    // MARK: - Résolution du bundle de langue

    /// Cache des bundles `<lang>.lproj`. `Bundle(path:)` est déjà mis en cache
    /// par Foundation, mais `path(forResource:ofType:)` touche le disque à
    /// chaque appel — or on résout des chaînes à chaque rendu.
    ///
    /// `nonisolated(unsafe)` + `NSLock` : ce cache est lu depuis le main actor
    /// (vues) ET depuis des tâches de fond (moteurs, services de sync), donc il
    /// ne peut pas être isolé sur un acteur sans rendre l'API `async`.
    nonisolated(unsafe) private static var bundleCache: [String: Bundle] = [:]
    private static let cacheLock = NSLock()

    /// Le bundle dans lequel chercher les clés pour `language`.
    /// Retombe sur `Bundle.main` si la langue est « système », ou si le
    /// `.lproj` demandé n'existe pas (langue non traduite) — jamais d'échec.
    private static func bundle(for language: String?) -> Bundle {
        guard let language else { return .main }

        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = bundleCache[language] { return cached }
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let resolved = Bundle(path: path) else {
            bundleCache[language] = .main
            return .main
        }
        bundleCache[language] = resolved
        return resolved
    }

    /// Code de langue porté par une `Locale` — le pont entre
    /// `@Environment(\.locale)` (que SwiftUI nous donne) et le `.lproj` à viser.
    ///
    /// Pour la locale système, ça renvoie la langue système, ce qui est le
    /// comportement voulu en mode « système ».
    static func languageCode(for locale: Locale) -> String? {
        locale.language.languageCode?.identifier
    }

    // MARK: - Lookup

    /// L'équivalent `String` de `Text(_ key: LocalizedStringKey)` : cherche
    /// `value` comme clé dans `Localizable.strings` et renvoie une `String`
    /// simple, pour les sites qui doivent stocker, concaténer ou transmettre le
    /// résultat plutôt que le donner directement à une `View`.
    ///
    /// Retombe sur le texte source (français), interpolations substituées,
    /// quand aucune entrée ne correspond — jamais de crash, jamais de clé brute
    /// affichée.
    ///
    /// - Parameter language: force une langue (`"fr"`, `"en"`). `nil` = la
    ///   préférence enregistrée. Les modificateurs de vue passent ici la langue
    ///   déduite de `@Environment(\.locale)`, ce qui rend le résultat réactif.
    static func string(_ value: String.LocalizationValue, language: String? = nil) -> String {
        let lang = language ?? preferredLanguageCode
        return String(localized: value, bundle: bundle(for: lang), locale: locale)
    }

    /// Même lookup, pour une valeur qui n'existe qu'en `String` à l'exécution —
    /// typiquement la propriété calculée `.label` d'un enum (`GoalKind.label`,
    /// `AccountType.label`…), dont les branches sont toutes des littéraux mais
    /// dont le TYPE déclaré doit rester `String` parce que d'autres sites la
    /// passent à des API qui exigent `StringProtocol`.
    ///
    /// Nommée différemment de `string(_:)` à dessein : une seconde surcharge
    /// prenant une `String` nue rendrait ambigus tous les sites d'appel
    /// existants (qui se résolvent aujourd'hui via `ExpressibleByStringLiteral`).
    static func string(fromLabel value: String, language: String? = nil) -> String {
        string(String.LocalizationValue(value), language: language)
    }
}

// MARK: - Chrome native réactive
//
// `.navigationTitle`, `.help` et `.accessibilityLabel` pontent vers la chrome
// AppKit/UIKit (barre de titre `NSWindow`/`NSToolbar`, infobulles, VoiceOver).
// Ce pont ne consulte PAS `\.locale` : un `.navigationTitle("Données")` sur une
// machine en anglais affiche « Data » même quand l'app est réglée en français,
// et n'est jamais rafraîchi ensuite.
//
// Ces modificateurs corrigent les deux volets d'un coup :
//   • la LANGUE, en résolvant contre le bundle `<lang>.lproj` ;
//   • la RÉACTIVITÉ, parce que lire `@Environment(\.locale)` crée une vraie
//     dépendance SwiftUI — le modificateur est réévalué au changement de langue
//     et republie une chaîne fraîche vers la chrome native.
//
// ⚠️ Toujours passer la CLÉ source (le texte français tel qu'il est dans
// `Localizable.strings`), jamais une chaîne déjà résolue.

private struct LocalizedNavigationTitle: ViewModifier {
    @Environment(\.locale) private var locale
    let key: String

    func body(content: Content) -> some View {
        // Surcharge verbatim `String` volontaire : la chaîne est DÉJÀ résolue
        // ici, dans la bonne langue. La laisser repasser par un
        // `LocalizedStringKey` la ferait re-chercher par la chrome native, donc
        // en langue système — précisément le bug qu'on corrige.
        content.navigationTitle(AppLocalization.string(fromLabel: key,
                                                       language: AppLocalization.languageCode(for: locale)))
    }
}

private struct LocalizedHelp: ViewModifier {
    @Environment(\.locale) private var locale
    let key: String

    func body(content: Content) -> some View {
        content.help(AppLocalization.string(fromLabel: key,
                                            language: AppLocalization.languageCode(for: locale)))
    }
}

private struct LocalizedAccessibilityLabel: ViewModifier {
    @Environment(\.locale) private var locale
    let key: String

    func body(content: Content) -> some View {
        content.accessibilityLabel(AppLocalization.string(fromLabel: key,
                                                          language: AppLocalization.languageCode(for: locale)))
    }
}

extension View {
    /// `.navigationTitle` qui suit le picker de langue de l'app.
    /// **À utiliser systématiquement à la place de `.navigationTitle`** — cf.
    /// l'explication au-dessus. Passer la clé source (texte français).
    func localizedNavigationTitle(_ key: String) -> some View {
        modifier(LocalizedNavigationTitle(key: key))
    }

    /// `.help` (infobulle macOS) qui suit le picker de langue de l'app.
    func localizedHelp(_ key: String) -> some View {
        modifier(LocalizedHelp(key: key))
    }

    /// `.accessibilityLabel` (VoiceOver) qui suit le picker de langue de l'app.
    func localizedAccessibilityLabel(_ key: String) -> some View {
        modifier(LocalizedAccessibilityLabel(key: key))
    }
}
