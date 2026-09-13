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
        /// iCloud link for the "Import an Apple Pay transaction" shortcut
        /// (a personal Shortcuts automation → `ImportTransactionApplePayEntityIntent`).
        /// ⚠️ Frozen at export time: if the shortcut is edited in Shortcuts,
        /// it must be re-shared (Share → Copy iCloud Link) and this constant
        /// updated — Apple doesn't republish the same link.
        static let applePayInstallURL = URL(string: "https://www.icloud.com/shortcuts/d43dedc201014857859c6b5204535233")!
    }
}
