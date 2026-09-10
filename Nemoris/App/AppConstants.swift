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
        /// Lien iCloud du raccourci "Importer une transaction Apple Pay"
        /// (automatisation personnelle Raccourcis → `ImportTransactionApplePayEntityIntent`).
        /// ⚠️ Se fige à l'export : si le raccourci est modifié côté Raccourcis,
        /// il faut le repartager (Partager → Copier le lien iCloud) et mettre
        /// à jour cette constante — Apple ne republie pas le même lien.
        static let applePayInstallURL = URL(string: "https://www.icloud.com/shortcuts/d43dedc201014857859c6b5204535233")!
    }
}
