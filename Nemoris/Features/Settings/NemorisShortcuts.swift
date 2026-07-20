import AppIntents
import Foundation
import UniformTypeIdentifiers

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

// MARK: - Import Investment Document (PDF / image / CSV)

/// Chantier D — dépose un document d'investissement (relevé PDF, capture d'écran
/// de PEA/CTO, CSV) dans Nemoris via Siri ou un raccourci. Le fichier peut venir
/// de n'importe quelle étape Raccourcis (capture d'écran, fichier partagé, sortie
/// d'une action « Use Model » iOS 26). AUCUN import silencieux : l'app s'ouvre sur
/// l'écran d'import intelligent pré-rempli pour relecture et validation manuelle.
struct ImportInvestmentDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Importer un document d'investissement"
    static let description = IntentDescription(
        "Envoie un relevé, une capture d'écran de portefeuille ou un CSV à Nemoris. L'app s'ouvre sur l'import intelligent pour relire et valider avant d'enregistrer."
    )
    static let openAppWhenRun: Bool = true

    // Accepte tout fichier (PDF, image/capture, CSV) — le parser détecte le
    // format. Comme `ImportFileIntent`, on n'impose pas de supportedContentTypes
    // (l'API @Parameter ne l'accepte pas ici de façon fiable multiplateforme).
    @Parameter(title: "Document")
    var file: IntentFile

    func perform() async throws -> some IntentResult {
        let data = try file.data
        // Extension : depuis le nom de fichier, sinon depuis le type déclaré.
        let ext: String = {
            let fromName = (file.filename as NSString?)?.pathExtension ?? ""
            if !fromName.isEmpty { return fromName }
            return file.type?.preferredFilenameExtension ?? "dat"
        }()

        let ok = await MainActor.run { PendingImportInbox.stash(data: data, fileExtension: ext) }
        guard ok else {
            throw $file.needsValueError("Impossible d'enregistrer le document dans Nemoris.")
        }
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
        AppShortcut(
            intent: ImportInvestmentDocumentIntent(),
            phrases: [
                "Importer un relevé d'investissement dans \(.applicationName)",
                "Ajouter ce document à mon portefeuille \(.applicationName)",
                "Importer une capture de portefeuille dans \(.applicationName)",
                "Importer mes positions dans \(.applicationName)"
            ],
            shortTitle: "Import investissement",
            systemImageName: "sparkles"
        )
    }
}
