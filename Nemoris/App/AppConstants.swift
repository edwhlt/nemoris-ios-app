import Foundation

/// Global application constants.
enum AppConstants {

    enum Store {
        static let monthlyID  = "fr.hedwin.nemoris.subscription.monthly"
        static let yearlyID   = "fr.hedwin.nemoris.subscription.yearly"
        static let lifetimeID = "fr.hedwin.nemoris.lifetime"

        /// Apple Settings "Subscriptions" page — the only place to cancel or
        /// change payment method (StoreKit does not expose this internally).
        static let manageSubscriptionsURL = URL(string: "itms-apps://apps.apple.com/account/subscriptions")!
    }

    enum Legal {
        static let privacyPolicyURL = URL(string: "https://nemorisapp.com/en/privacy")!
        static let termsOfUseURL    = URL(string: "https://nemorisapp.com/en/terms")!
    }

    enum Shortcuts {
        /// LAST-RESORT fallback for `ApplePayShortcutManifest.resolveInstallURL()`,
        /// used only if `versions.json` can't be reached at all (offline, site
        /// down, malformed manifest). Points at a `.shortcut` file WE host on
        /// `nemoris-site` (`assets/shortcuts/apple-pay-v2.shortcut`), not an
        /// iCloud share link: a file under our own control never gets revoked
        /// or expires the way a personal iCloud share could. It intentionally
        /// lags behind the real "latest" — that's the manifest's job, not
        /// this constant's. Update it only if this exact archived file is
        /// ever removed from the site.
        static let applePayInstallFallbackURL = URL(string: "https://nemorisapp.com/assets/shortcuts/apple-pay-v2.shortcut")!
    }
}
