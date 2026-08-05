import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Assistant IA pour construire des requêtes SQL en conversation multi-tours.
///
/// 100 % on-device via Apple Foundation Models (`LanguageModelSession`).
/// Requiert iOS 26.0+ et Apple Intelligence activé. Sinon `isAvailable` est false
/// et la UI affichera un état "Non disponible".
///
/// La session est stateful : chaque `respond(to:)` continue le contexte. C'est
/// idéal pour le raffinement progressif d'une requête.
@MainActor
final class SQLAssistantService {

    /// ⚠️ Respecte désormais le choix de l'utilisateur pour cette
    /// fonctionnalité. Ce service appelait Foundation Models en DIRECT : un
    /// « Désactivée » dans les Réglages ne le coupait pas.
    ///
    /// Le moteur reste Foundation Models, et c'est ici une contrainte
    /// technique, pas un oubli : l'assistant est MULTI-TOURS et s'appuie sur
    /// l'état conservé par `LanguageModelSession` d'une question à l'autre. Le
    /// porter sur un backend HTTP demanderait de gérer l'historique de
    /// conversation nous-mêmes — un chantier à part, d'où la capacité
    /// `.multiTurn` déclarée par `AIFeature.sqlAssistant`.
    var isAvailable: Bool {
        guard AIEnrichmentBackend.usesGuidedGeneration(for: .sqlAssistant) else { return false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// État de disponibilité détaillé pour l'UI.
    enum Availability {
        case ready
        case notImplemented        // < iOS 26 — pas de Foundation Models
        case appleIntelligenceOff  // iOS 26+ mais user n'a pas activé AI
        case deviceNotEligible     // appareil pas compatible
        case modelNotReady         // téléchargement en cours
    }

    var availability: Availability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
                case .deviceNotEligible:           return .deviceNotEligible
                case .modelNotReady:               return .modelNotReady
                @unknown default:                  return .modelNotReady
                }
            }
        }
        #endif
        return .notImplemented
    }

    // MARK: - Session (multi-turn)
    //
    // `LanguageModelSession` n'existe qu'à partir d'iOS 26 → on ne peut pas
    // annoter une stored property `@available`. Astuce : on stocke un `Any?`
    // et on cast au moment de l'usage (sous `if #available`).
    private var sessionStorage: Any?

    /// Reset complet : la prochaine question repart d'une session vide.
    func resetConversation() {
        sessionStorage = nil
    }

    /// Envoie un message user au LLM. Renvoie la réponse complète (texte avec bloc SQL).
    func send(_ userMessage: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            guard SystemLanguageModel.default.isAvailable else { return nil }
            let session: LanguageModelSession
            if let existing = sessionStorage as? LanguageModelSession {
                session = existing
            } else {
                session = LanguageModelSession(instructions: Self.systemInstructions)
                sessionStorage = session
            }
            do {
                let response = try await session.respond(to: userMessage)
                return response.content
            } catch {
                print("[SQLAssistantService] generation error: \(error)")
                print("[SQLAssistantService] system instructions length: \(Self.systemInstructions.count) chars")
                return nil
            }
        }
        #endif
        return nil
    }

    // MARK: - System prompt

    /// Le schéma SQL injecté dans le prompt est généré dynamiquement depuis
    /// `SchemaDoc.llmSchemaPrompt` — source de vérité unique avec la doc
    /// utilisateur de `DatabaseSchemaView`. Si une migration ajoute une table,
    /// mets à jour `SchemaDoc.domains` une seule fois et l'assistant suit.
    static var systemInstructions: String {
        Self.instructionsTemplate.replacingOccurrences(
            of: "{{SCHEMA}}",
            with: SchemaDoc.llmSchemaPrompt
        )
    }

    private static let instructionsTemplate = """
    SQL assistant for Nemoris (personal finance iOS app, SQLite).
    Reply in the user's language. SQL keywords stay English.

    RULES:
    1. Only SQL questions about the schema below.
    2. Prefer SELECT. Warn for UPDATE/DELETE/INSERT.
    3. Put queries in ```sql``` blocks.
    4. Add LIMIT 100 unless user says "all"/"tout".
    5. Use exact table/column names below.
    6. Concise: 1-2 sentences then the query.
    7. Ask ONE clarification if needed.
    8. If the user wants a REUSABLE/parameterized query (not a one-off question),
       use {{name:type=default}} tokens instead of hardcoding the literal — see
       VARIABLES below.

    KEY NOTES:
    - transactions date column = tx_date (TEXT ISO), NOT date.
    - amount < 0 = expense, > 0 = income.
    - Group by month: strftime('%Y-%m', tx_date).
    - tier_type: merchant|contact|internal|organization.
    - loan_type: AMORT|IN_FINE|DEFERRED_TOTAL|DEFERRED_PARTIAL|REVOLVING.
    - goals.kind: SAVINGS|NETWORTH|DEBT_PAYOFF|CUSTOM.

    VARIABLES (only for reusable queries the user wants to save and rerun):
    - Token: {{name}} (free text) | {{name:type}} | {{name:type=default}}.
    - Types: text (quoted, default) | number (unquoted) | year (4-digit, ALWAYS
      quoted since it's compared as text: strftime('%Y', tx_date) = {{annee:year=2026}})
      | date (native date picker, substituted as 'yyyy-MM-dd').
    - The app renders one form field per token (right keyboard/picker per type)
      and substitutes it on Run. Never add your own quotes around {{...}} —
      quoting is automatic based on the declared type.

    SCHEMA:

    {{SCHEMA}}

    EXAMPLE (one-off question):
    User: "mes 10 plus grosses dépenses ce mois"
    ```sql
    SELECT tx_date, p.name AS tiers, t.amount
    FROM transactions t
    LEFT JOIN payees p ON p.id = t.payee_id
    WHERE t.amount < 0 AND tx_date >= date('now','start of month')
    ORDER BY t.amount ASC LIMIT 10;
    ```

    EXAMPLE (reusable query — user asked to save/rerun it):
    User: "une requête que je peux relancer chaque année pour mes dépenses par catégorie"
    ```sql
    SELECT c.name, SUM(t.amount) AS total
    FROM transactions t
    JOIN categories c ON c.id = t.category_id
    WHERE strftime('%Y', t.tx_date) = {{annee:year=2026}}
    GROUP BY c.id ORDER BY total ASC;
    ```
    """
}
