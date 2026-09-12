import AppIntents
import Foundation
import UniformTypeIdentifiers

// (GetMonthlyBalanceIntent removed 2026-07-22 — a duplicate of the Balance widget,
//  never used by voice. The widget still reads WidgetDataStore directly.)

// MARK: - Import Transactions CSV

/// Drops a bank-statement CSV into Nemoris via Siri, a shortcut, or the share
/// extension. NO silent import: the file goes into `PendingImportInbox`
/// (kind `.transactions`) and the app opens on a pre-filled `ImportEntryView` —
/// the user confirms the target account then goes through the usual mapping.
struct ImportFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Importer des transactions (CSV)"
    static let description = IntentDescription(
        "Envoie un relevé bancaire CSV à Nemoris. L'app s'ouvre sur l'import pour choisir le compte, mapper les colonnes et valider les transactions."
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Fichiers") var files: [IntentFile]

    // Exposes the parameter as an inline token in the Shortcuts editor:
    // without this, the parameter is resolved at run time (= a Files
    // picker is forced) and no variable / shortcut input can be dropped in.
    // With the summary, the field accepts a variable, a shared file, the
    // output of a previous action, or the shortcut's input.
    static var parameterSummary: some ParameterSummary {
        Summary("Importer les transactions des fichiers \(\.$files)")
    }

    func perform() async throws -> some IntentResult {
        let payload: [(data: Data, fileExtension: String)] = files.compactMap { file in
            let data = file.data
            return (data, Self.fileExtension(of: file, fallback: "csv"))
        }
        guard !payload.isEmpty else {
            throw $files.needsValueError("Aucun fichier lisible.")
        }
        let ok = await MainActor.run {
            PendingImportInbox.stash(files: payload, kind: .transactions)
        }
        guard ok else {
            throw $files.needsValueError("Impossible d'enregistrer les fichiers dans Nemoris.")
        }
        return .result()
    }

    /// Extension: from the file name, otherwise from the declared type.
    /// It's purely indicative — the inbox decides based on the BYTES.
    static func fileExtension(of file: IntentFile, fallback: String) -> String {
        let fromName = (file.filename as NSString?)?.pathExtension ?? ""
        if !fromName.isEmpty { return fromName }
        return file.type?.preferredFilenameExtension ?? fallback
    }
}

// MARK: - Import Investment Document (PDF / image / CSV)

/// Drops an investment document (a PDF statement, a PEA/CTO screenshot,
/// a CSV) into Nemoris via Siri or a shortcut. The file can come from
/// any Shortcuts step (a screenshot, a shared file, the output of a
/// "Use Model" action on iOS 26). NO silent import: the app opens on the
/// pre-filled smart-import screen for review and manual confirmation.
struct ImportInvestmentDocumentIntent: AppIntent {
    static let title: LocalizedStringResource = "Importer un document d'investissement"
    static let description = IntentDescription(
        "Envoie un relevé, une capture d'écran de portefeuille ou un CSV à Nemoris. L'app s'ouvre sur l'import intelligent pour relire et valider avant d'enregistrer."
    )
    static let openAppWhenRun: Bool = true

    // Accepts any file (PDF, image/screenshot, CSV) — the parser detects the
    // format. As with `ImportFileIntent`, no supportedContentTypes is imposed
    // (the @Parameter API doesn't reliably accept it here across platforms),
    // which also lets the field accept any variable type.
    @Parameter(title: "Documents")
    var files: [IntentFile]

    // Makes the parameter fillable by a variable / the shortcut's input
    // in the Shortcuts editor (see the detailed comment on ImportFileIntent).
    static var parameterSummary: some ParameterSummary {
        Summary("Importer les documents d'investissement \(\.$files)")
    }

    func perform() async throws -> some IntentResult {
        let payload: [(data: Data, fileExtension: String)] = files.compactMap { file in
            let data = file.data
            return (data, ImportFileIntent.fileExtension(of: file, fallback: "dat"))
        }
        guard !payload.isEmpty else {
            throw $files.needsValueError("Aucun document lisible.")
        }
        let ok = await MainActor.run { PendingImportInbox.stash(files: payload, kind: .investment) }
        guard ok else {
            throw $files.needsValueError("Impossible d'enregistrer les documents dans Nemoris.")
        }
        return .result()
    }
}

// MARK: - Import Apple Pay Transactions

/// Drops an Apple Pay expense into the `pending_apple_pay_entries` buffer
/// (migration v49), via the personal "Apple Pay" Shortcuts automation.
///
/// `openAppWhenRun = false`: runs in the background, the app NEVER
/// comes to the foreground — that's the only condition that makes the
/// automation truly invisible to the user (Apple doesn't notify third-party
/// apps of Apple Pay payments, this Shortcuts trigger is the only
/// available path). NO commit into `transactions` here: the entry stays
/// pending, shown separately, until it's either resolved (opening the app)
/// or matched against the real bank transaction when the statement is imported.
struct ImportTransactionApplePayEntityIntent: AppIntent {
    static let title: LocalizedStringResource = "Importer une transaction Apple Pay"
    static let description = IntentDescription(
        "Dépose une dépense Apple Pay dans Nemoris en arrière-plan, sans ouvrir l'app. Elle apparaît à part, en attente, jusqu'à sa résolution."
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Carte")
    var card: String

    // Deliberately optional: on some transactions (no contact with
    // pre-authorization, public transit, a tip added afterward…),
    // Apple Pay doesn't yet know the final amount when the
    // trigger fires — the "Amount" variable arrives empty on the
    // Shortcuts side. With a required `Double`, Shortcuts has no
    // choice but to INTERRUPT the automation to ask for
    // manual entry — exactly what `openAppWhenRun = false` is meant to avoid.
    // As an optional, a missing value is legitimate: Shortcuts passes `nil`
    // without ever prompting the user. `perform()` then stores 0 —
    // the entry stays visible, to fix by hand (see `PendingApplePayListView`).
    @Parameter(title: "Montant")
    var amount: Double?

    @Parameter(title: "Marchand")
    var merchant: String

    // The "Apple Pay" Shortcuts trigger can supply a name distinct from the
    // merchant's (e.g. a card label) depending on the user's automation
    // configuration. It isn't stored separately (no dedicated column, usage
    // still uncertain): just a fallback if `merchant` is empty.
    @Parameter(title: "Name")
    var name: String

    // Without this, every parameter is resolved "at run time" (manual entry
    // forced) instead of being exposed as a token in the Shortcuts
    // editor — impossible to drop in a variable like "Amount" from
    // "Get Transaction". The same fix as `ImportFileIntent`/
    // `ImportInvestmentDocumentIntent` (see their comments).
    static var parameterSummary: some ParameterSummary {
        Summary("Enregistrer \(\.$amount) € chez \(\.$merchant) avec la carte \(\.$card) (\(\.$name))")
    }

    func perform() async throws -> some IntentResult {
        // A missing amount (a transaction with no known amount at this
        // point): stored as 0 rather than lost or re-requested — `PendingApplePayListView`
        // spots these entries and offers to fix the amount by hand.
        let resolvedAmount = amount ?? 0

        let label = merchant.isEmpty ? name : merchant
        // No `MainActor.run` here: unlike `PendingImportInbox`
        // (@MainActor, App Group files), `PendingApplePayRepository` is
        // stateless and opens its own SQLite connection — no thread affinity.
        let ok = PendingApplePayRepository().addEntry(card: card, amount: resolvedAmount, merchant: label)
        guard ok else {
            throw $amount.needsValueError("Impossible d'enregistrer la dépense Apple Pay dans Nemoris.")
        }
        // Checks right away whether the configured threshold is crossed over
        // the current period — that's the only moment it makes sense here: this
        // intent runs without ever opening the app (`openAppWhenRun = false`),
        // so the notification is the only signal the user gets.
        await ApplePayAlertService.checkAndNotifyIfNeeded()
        return .result()
    }
}

// MARK: - App Shortcuts Provider

struct NemorisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ImportFileIntent(),
            phrases: [
                "Importer mes transactions dans \(.applicationName)",
                "Importer un relevé dans \(.applicationName)",
                "Ajouter un fichier bancaire dans \(.applicationName)"
            ],
            shortTitle: "Importer transactions",
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
        AppShortcut(
            intent: ImportTransactionApplePayEntityIntent(),
            phrases: [
                "Importer une transaction Apple Pay dans \(.applicationName)",
            ],
            shortTitle: "Import Apple Pay Transaction",
            systemImageName: "creditcard.rewards"
        )
    }
}
