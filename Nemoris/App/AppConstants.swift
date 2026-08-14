import Foundation

/// Constantes globales de l'application.
enum AppConstants {

    // MARK: - Store (StoreKit product IDs)
    //
    // Ces identifiants doivent correspondre exactement à ceux configurés dans
    // App Store Connect > Votre app > Achats intégrés.
    //
    // Abonnements (groupe "Finance Pro") :
    //   - monthlyID  → Auto-Renewable Subscription, durée : 1 mois
    //   - yearlyID   → Auto-Renewable Subscription, durée : 1 an
    //
    // Achat unique :
    //   - lifetimeID → Non-Consumable

    enum Store {
        static let monthlyID  = "fr.hedwin.nemoris.subscription.monthly"
        static let yearlyID   = "fr.hedwin.nemoris.subscription.yearly"
        static let lifetimeID = "fr.hedwin.nemoris.lifetime"

        /// Page "Abonnements" des Réglages Apple — seul endroit pour résilier ou
        /// changer de moyen de paiement (StoreKit ne l'expose pas en interne).
        static let manageSubscriptionsURL = URL(string: "itms-apps://apps.apple.com/account/subscriptions")!
    }

    enum Legal {
        static let privacyPolicyURL = URL(string: "https://nemoris.hedwin.fr/en/privacy")!
        static let termsOfUseURL    = URL(string: "https://nemoris.hedwin.fr/en/terms")!
    }
}
