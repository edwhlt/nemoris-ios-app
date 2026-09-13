import Foundation
import SwiftUI

// MARK: - AppLocalization
//
// Resolves localized strings in the language CHOSEN IN THE APP (the
// Settings picker → `AppState.preferredLanguage`), not the system's.
//
// ⚠️⚠️ THE CENTRAL PITFALL, measured — `String(localized:locale:)`
// DOES NOT USE `locale:` TO CHOOSE THE LANGUAGE.
//
// The `locale:` parameter ONLY drives the formatting of interpolated values
// (numbers, dates). The key's lookup goes through `bundle:` — whose
// default is `Bundle.main`, which resolves its language from the
// SYSTEM's preferences, fixed at process launch. Verified on a machine set to English:
//
//     String(localized: "Données", locale: Locale(identifier: "fr_FR"))  →  "Data"
//
// That's why the earlier version of this file always translated
// into the system language, whatever the picker said — and why the
// `AppLocalization.string(...)` calls placed in `Text`s had to be removed one
// by one.
//
// **The only axis that actually drives the language is the BUNDLE**: by pointing
// at the `<lang>.lproj` sub-bundle (which holds only one language), the lookup
// can't fall back anywhere else. Measured, and interpolation is preserved:
//
//     String(localized: "\(n) compte…", bundle: frLproj)  →  "3 comptes" (FR)
//
// The two axes are orthogonal and both apply: `bundle` = the language,
// `locale` = number formatting.
//
// ── Two distinct problems, two fixes ─────────────────────────────────────────
//
// 1. CORRECTNESS (this file): the lookup targets `<lang>.lproj`.
// 2. REACTIVITY (the modifiers at the bottom of this file): a resolved
//    `String` is a dead value — nothing recomputes it when the language changes. The
//    `.localizedNavigationTitle` / `.localizedHelp` / `.localizedAccessibilityLabel`
//    modifiers read `@Environment(\.locale)`, which makes them a REAL SwiftUI
//    dependency: on a language change, the modifier is re-evaluated and produces
//    a fresh string.
//
// ── When to use what ─────────────────────────────────────────────────────────
//
// • CONTENT text (`Text`, `Label`, `Button`…): nothing special needed —
//   `Text("literal")` and `Text(LocalizedStringKey(runtimeValue))` already respect
//   the environment's `\.locale` (injected at the root in `NemorisApp`) and
//   refresh on their own. **Never route these back through `AppLocalization.string`.**
// • NATIVE chrome (`.navigationTitle`, `.help`, `.accessibilityLabel`): these
//   APIs bridge to AppKit/UIKit and do NOT consult `\.locale` — hence the
//   dedicated modifiers at the bottom of this file.
// • Outside SwiftUI (pure engines, static services: `InsightEngine`,
//   `AlertEngine`, `LiveSyncRegistry`, `BudgetNotificationService`…):
//   `AppLocalization.string(...)`, which reads the preference from `UserDefaults`.
enum AppLocalization {

    // MARK: - Langue courante

    /// The language code to use for the lookup, based on the stored preference.
    /// `nil` = "system": `Bundle.main` is then left to do its normal
    /// job, which is exactly the expected behavior in that mode.
    ///
    /// A mirror of `AppState.preferredLanguage` (the same `UserDefaults` key) — this
    /// is what lets pure engines, with no access to the SwiftUI environment,
    /// follow the same setting without depending on `AppState`.
    private static var preferredLanguageCode: String? {
        switch UserDefaults.standard.string(forKey: "appLanguage") ?? "system" {
        case "fr": return "fr"
        case "en": return "en"
        default:   return nil
        }
    }

    /// The locale for FORMATTING (numbers, dates). Doesn't drive translation —
    /// see the warning at the top of this file.
    static var locale: Locale {
        switch UserDefaults.standard.string(forKey: "appLanguage") ?? "system" {
        case "fr": return Locale(identifier: "fr_FR")
        case "en": return Locale(identifier: "en_US")
        default:   return Locale.current
        }
    }

    // MARK: - Resolving the language bundle

    /// A cache of `<lang>.lproj` bundles. `Bundle(path:)` is already cached
    /// by Foundation, but `path(forResource:ofType:)` hits disk on
    /// every call — and strings are resolved on every render.
    ///
    /// `nonisolated(unsafe)` + `NSLock`: this cache is read from the main actor
    /// (views) AND from background tasks (engines, sync services), so it
    /// can't be isolated on an actor without making the API `async`.
    nonisolated(unsafe) private static var bundleCache: [String: Bundle] = [:]
    private static let cacheLock = NSLock()

    /// The bundle to look up keys for `language` in.
    /// Falls back to `Bundle.main` if the language is "system", or if the
    /// requested `.lproj` doesn't exist (an untranslated language) — never fails.
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

    /// A language code carried by a `Locale` — the bridge between
    /// `@Environment(\.locale)` (what SwiftUI gives us) and the `.lproj` to target.
    ///
    /// For the system locale, this returns the system language, which is the
    /// intended behavior in "system" mode.
    static func languageCode(for locale: Locale) -> String? {
        locale.language.languageCode?.identifier
    }

    // MARK: - Lookup

    /// The `String` equivalent of `Text(_ key: LocalizedStringKey)`: looks up
    /// `value` as a key in `Localizable.strings` and returns a plain
    /// `String`, for sites that need to store, concatenate or pass along the
    /// result rather than handing it directly to a `View`.
    ///
    /// Falls back to the source text (French), interpolations substituted,
    /// when no entry matches — never a crash, never a raw key shown.
    ///
    /// - Parameter language: forces a language (`"fr"`, `"en"`). `nil` = the
    ///   saved preference. View modifiers pass the language
    ///   inferred from `@Environment(\.locale)` here, which makes the result reactive.
    static func string(_ value: String.LocalizationValue, language: String? = nil) -> String {
        let lang = language ?? preferredLanguageCode
        return String(localized: value, bundle: bundle(for: lang), locale: locale)
    }

    /// The same lookup, for a value that only exists as a runtime `String` —
    /// typically an enum's computed `.label` property (`GoalKind.label`,
    /// `AccountType.label`…), whose branches are all literals but
    /// whose declared TYPE must stay `String` because other sites
    /// pass it to APIs that require `StringProtocol`.
    ///
    /// Named differently from `string(_:)` on purpose: a second overload
    /// taking a bare `String` would make every existing call site
    /// ambiguous (they currently resolve via `ExpressibleByStringLiteral`).
    static func string(fromLabel value: String, language: String? = nil) -> String {
        string(String.LocalizationValue(value), language: language)
    }
}

// MARK: - Reactive native chrome
//
// `.navigationTitle`, `.help` and `.accessibilityLabel` bridge to
// AppKit/UIKit chrome (an `NSWindow`/`NSToolbar` title bar, tooltips, VoiceOver).
// This bridge does NOT consult `\.locale`: a `.navigationTitle("Données")` on a
// machine set to English shows "Data" even when the app is set to French,
// and is never refreshed afterward.
//
// These modifiers fix both aspects at once:
//   • the LANGUAGE, by resolving against the `<lang>.lproj` bundle;
//   • REACTIVITY, because reading `@Environment(\.locale)` creates a real
//     SwiftUI dependency — the modifier is re-evaluated on a language change
//     and republishes a fresh string to the native chrome.
//
// ⚠️ Always pass the SOURCE key (the French text as it is in
// `Localizable.strings`), never an already-resolved string.

private struct LocalizedNavigationTitle: ViewModifier {
    @Environment(\.locale) private var locale
    let key: String

    func body(content: Content) -> some View {
        // A deliberate verbatim `String` overload: the string is ALREADY resolved
        // here, in the right language. Letting it pass through a
        // `LocalizedStringKey` would make the native chrome look it up again, so
        // in the system language — precisely the bug being fixed.
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
    /// A `.navigationTitle` that follows the app's language picker.
    /// **Use this systematically instead of `.navigationTitle`** — see
    /// the explanation above. Pass the source key (French text).
    func localizedNavigationTitle(_ key: String) -> some View {
        modifier(LocalizedNavigationTitle(key: key))
    }

    /// A `.help` (macOS tooltip) that follows the app's language picker.
    func localizedHelp(_ key: String) -> some View {
        modifier(LocalizedHelp(key: key))
    }

    /// An `.accessibilityLabel` (VoiceOver) that follows the app's language picker.
    func localizedAccessibilityLabel(_ key: String) -> some View {
        modifier(LocalizedAccessibilityLabel(key: key))
    }
}
