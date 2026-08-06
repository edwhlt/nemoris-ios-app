import AppIntents
import Foundation
import UniformTypeIdentifiers

// (GetMonthlyBalanceIntent supprimé 2026-07-22 — doublon du widget Solde,
//  jamais utilisé en vocal. Le widget lit toujours WidgetDataStore directement.)

// MARK: - Import Transactions CSV

/// Dépose un relevé bancaire CSV dans Nemoris via Siri, un raccourci ou la share
/// extension. AUCUN import silencieux : le fichier part dans `PendingImportInbox`
/// (kind `.transactions`) et l'app s'ouvre sur `ImportEntryView` pré-rempli —
/// l'utilisateur confirme le compte cible puis passe par le mapping habituel.
struct ImportFileIntent: AppIntent {
    static let title: LocalizedStringResource = "Importer des transactions (CSV)"
    static let description = IntentDescription(
        "Envoie un relevé bancaire CSV à Nemoris. L'app s'ouvre sur l'import pour choisir le compte, mapper les colonnes et valider les transactions."
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Fichiers") var files: [IntentFile]

    // Expose le paramètre comme jeton inline dans l'éditeur Raccourcis :
    // sans ça, le paramètre est résolu à l'exécution (= file picker Fichiers
    // imposé) et on ne peut PAS y déposer une variable / l'entrée du raccourci.
    // Avec le summary, le champ accepte une variable, un fichier partagé, la
    // sortie d'une action précédente, ou l'entrée du raccourci.
    static var parameterSummary: some ParameterSummary {
        Summary("Importer les transactions des fichiers \(\.$files)")
    }

    func perform() async throws -> some IntentResult {
        let payload: [(data: Data, fileExtension: String)] = files.compactMap { file in
            guard let data = try? file.data else { return nil }
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

    /// Extension : depuis le nom de fichier, sinon depuis le type déclaré.
    /// Elle n'est qu'indicative — la boîte de réception tranche sur les OCTETS.
    static func fileExtension(of file: IntentFile, fallback: String) -> String {
        let fromName = (file.filename as NSString?)?.pathExtension ?? ""
        if !fromName.isEmpty { return fromName }
        return file.type?.preferredFilenameExtension ?? fallback
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
    // (l'API @Parameter ne l'accepte pas ici de façon fiable multiplateforme),
    // ce qui laisse aussi le champ accepter n'importe quel type de variable.
    @Parameter(title: "Documents")
    var files: [IntentFile]

    // Rend le paramètre fillable par une variable / l'entrée du raccourci
    // dans l'éditeur Raccourcis (cf. commentaire détaillé sur ImportFileIntent).
    static var parameterSummary: some ParameterSummary {
        Summary("Importer les documents d'investissement \(\.$files)")
    }

    func perform() async throws -> some IntentResult {
        let payload: [(data: Data, fileExtension: String)] = files.compactMap { file in
            guard let data = try? file.data else { return nil }
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
    }
}
