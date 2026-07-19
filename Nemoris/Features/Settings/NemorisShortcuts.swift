import AppIntents
import Foundation

// MARK: - Get Monthly Balance

struct GetMonthlyBalanceIntent: AppIntent {
    static let title: LocalizedStringResource = "Solde du mois"
    static let description = IntentDescription(
        "Affiche vos dépenses, revenus et balance nette du mois en cours."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = WidgetDataStore.load()

        let fmt = NumberFormatter()
        fmt.numberStyle = .currency
        fmt.currencyCode = "EUR"
        fmt.maximumFractionDigits = 2

        func money(_ v: Double) -> String {
            fmt.string(from: NSNumber(value: v)) ?? "\(v) €"
        }

        let sign = snapshot.netBalance >= 0 ? "+" : ""
        let monthFmt = DateFormatter()
        monthFmt.dateFormat = "MMMM yyyy"
        let month = monthFmt.string(from: snapshot.updatedAt).capitalized

        let text = """
        \(snapshot.accountName) · \(month)
        Dépenses : \(money(snapshot.monthExpense))
        Revenus : \(money(snapshot.monthIncome))
        Balance : \(sign)\(money(snapshot.netBalance))
        """

        return .result(dialog: IntentDialog(stringLiteral: text))
    }
}

// MARK: - Import CSV File

struct ImportFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Importer un fichier CSV"
    static let description = IntentDescription(
        "Envoie un relevé bancaire CSV à Nemoris pour import immédiat."
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Fichier CSV") var file: IntentFile

    func perform() async throws -> some IntentResult {
        let data = try file.data
        guard let defaults = UserDefaults(suiteName: "group.fr.hedwin.nemoris") else {
            throw $file.needsValueError("Impossible d'accéder au conteneur partagé.")
        }
        defaults.set(data, forKey: "nemoris.pendingCSV")
        return .result()
    }
}

// MARK: - App Shortcuts Provider

struct NemorisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetMonthlyBalanceIntent(),
            phrases: [
                "Mon solde dans \(.applicationName)",
                "Mes dépenses du mois dans \(.applicationName)",
                "Ma balance dans \(.applicationName)",
                "Combien j'ai dépensé dans \(.applicationName)"
            ],
            shortTitle: "Solde du mois",
            systemImageName: "chart.bar.fill"
        )
        AppShortcut(
            intent: ImportFileIntent(),
            phrases: [
                "Importer un relevé dans \(.applicationName)",
                "Ajouter un fichier bancaire dans \(.applicationName)"
            ],
            shortTitle: "Importer un CSV",
            systemImageName: "square.and.arrow.down"
        )
    }
}
