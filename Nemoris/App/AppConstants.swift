import Foundation

/// Global application constants.
enum AppConstants {

    // MARK: - Store (StoreKit product IDs)
    //
    // These identifiers must match exactly what is configured in
    // App Store Connect > app > In-App Purchases.
    //
    // Subscriptions ("Finance Pro" group):
    //   - monthlyID  → Auto-Renewable Subscription, duration: 1 month
    //   - yearlyID   → Auto-Renewable Subscription, duration: 1 year
    //
    // One-time purchase:
    //   - lifetimeID → Non-Consumable

    enum Store {
        static let monthlyID  = "fr.hedwin.nemoris.subscription.monthly"
        static let yearlyID   = "fr.hedwin.nemoris.subscription.yearly"
        static let lifetimeID = "fr.hedwin.nemoris.lifetime"

        /// Apple Settings "Subscriptions" page — the only place to cancel or
        /// change payment method (StoreKit does not expose this internally).
        static let manageSubscriptionsURL = URL(string: "itms-apps://apps.apple.com/account/subscriptions")!
    }

    enum Legal {
        static let privacyPolicyURL = URL(string: "https://nemoris.hedwin.fr/en/privacy")!
        static let termsOfUseURL    = URL(string: "https://nemoris.hedwin.fr/en/terms")!
    }
}
