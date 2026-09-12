import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// AI assistant for building SQL queries in a multi-turn conversation.
///
/// 100% on-device via Apple Foundation Models (`LanguageModelSession`).
/// Requires iOS 26.0+ and Apple Intelligence enabled. Otherwise `isAvailable` is false
/// and the UI shows an "Unavailable" state.
///
/// The session is stateful: each `respond(to:)` continues the context. Ideal
/// for progressively refining a query.
@MainActor
final class SQLAssistantService {

    /// ⚠️ Now respects the user's choice for this
    /// feature. This service used to call Foundation Models DIRECTLY: a
    /// "Disabled" setting had no effect on it.
    ///
    /// The engine stays Foundation Models, and that's a technical
    /// constraint here, not an oversight: the assistant is MULTI-TURN and relies on
    /// the state `LanguageModelSession` keeps from one question to the next. Porting
    /// it to an HTTP backend would require managing the conversation
    /// history ourselves — a separate undertaking, hence the
    /// `.multiTurn` capability declared by `AIFeature.sqlAssistant`.
    var isAvailable: Bool {
        guard AIEnrichmentBackend.usesGuidedGeneration(for: .sqlAssistant) else { return false }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Detailed availability state for the UI.
    enum Availability {
        case ready
        case notImplemented        // < iOS 26 — pas de Foundation Models
        case appleIntelligenceOff  // iOS 26+ but the user hasn't enabled Apple Intelligence
        case deviceNotEligible     // appareil pas compatible
        case modelNotReady         // download in progress
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
    // `LanguageModelSession` only exists from iOS 26 onward → a stored property
    // can't be annotated `@available`. Workaround: store an `Any?`
    // and cast it at use time (under `if #available`).
    private var sessionStorage: Any?

    /// Full reset: the next question starts from an empty session.
    func resetConversation() {
        sessionStorage = nil
    }

    /// Sends a user message to the LLM. Returns the full response (text with an SQL block).
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

    /// The SQL schema injected into the prompt is generated dynamically from
    /// `SchemaDoc.llmSchemaPrompt` — a single source of truth shared with the
    /// user-facing docs in `DatabaseSchemaView`. If a migration adds a table,
    /// update `SchemaDoc.domains` once and the assistant follows along.
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
    - payment_types / transactions.payment_type_id are DEPRECATED (v46, not
      seeded on new DBs). For "payment method" questions, use
      transaction_metadata_keys/transaction_metadata_values instead (join on
      key_id, filter role='payment_method' or name). A transaction can carry
      MULTIPLE metadata values (unlike the old 0..1 payment_type_id).

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
