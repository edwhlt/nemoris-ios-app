import Foundation

/// Classifies an isolated SQL statement by what it would ACTUALLY do to the
/// database (read / write rows / change the schema) — this is the safety net
/// for the SQL Console and the AI assistant (the only two paths that run
/// freely typed/generated SQL, see `TransactionRepository.executeSQL`).
///
/// Two distinct dangers, handled differently:
/// - a SCHEMA change (CREATE/ALTER/DROP…) desynchronizes the database from
///   the schema the app expects (`DatabaseManager.migrateIfNeeded`, whose
///   drift detector already treats any hand-edit "via the SQL console" as
///   THE risk to watch for). It isn't recoverable from within the app:
///   blocked, with no override option.
/// - a DATA change (INSERT/UPDATE/DELETE/REPLACE) remains a legitimate
///   power-user operation, but irreversible from the app —
///   requires explicit confirmation, with a backup offered beforehand.
///
/// PURE engine (no SQLite/network access, only knows the TEXT of the
/// query) — never runs it, only reads it. Covered by
/// `Tests/check_purity.sh` and `NemorisTests/SQLStatementGuardTests.swift`.
enum SQLStatementKind: Equatable {
    /// Lecture seule : SELECT, EXPLAIN, PRAGMA de lecture.
    case query
    /// Writes ROWS without touching the schema: INSERT / UPDATE / DELETE / REPLACE.
    case dataModification
    /// Changes the database's STRUCTURE: CREATE / ALTER / DROP / ATTACH / DETACH,
    /// or a PRAGMA that alters a persistent setting (`user_version`,
    /// `journal_mode`…) — `user_version` in particular is what
    /// `DatabaseManager` uses to know which migrations to apply:
    /// changing it by hand amounts to lying to the app about its own schema.
    case schemaModification
    /// BEGIN / COMMIT / ROLLBACK / SAVEPOINT / RELEASE — transaction control,
    /// neither a read nor a write of content in itself.
    case transactionControl
    /// VACUUM / ANALYZE / REINDEX — rewrites the file or internal
    /// statistics, but changes neither the logical schema nor tables' content.
    case maintenance
    /// First keyword this classifier doesn't recognize. Never auto-approved:
    /// a query we can't name isn't one we can guarantee
    /// doesn't change anything.
    case unrecognized

    /// Blocks execution before any confirmation — would break the
    /// database's compatibility with the app, no "anyway" button in the console.
    var isBlockedBySchemaGuard: Bool { self == .schemaModification }

    /// Asks for explicit confirmation (with a backup offered)
    /// before running — the action stays possible, just never silent.
    var requiresDataModificationConfirmation: Bool {
        self == .dataModification || self == .unrecognized
    }
}

struct SQLStatementClassification: Equatable {
    let kind: SQLStatementKind
    /// First significant keyword detected, uppercased (e.g. "DROP", "DELETE").
    let keyword: String
    /// Detected target (a table/index/trigger name) if the pattern allows it —
    /// purely informational for display, never used to decide anything.
    let target: String?
}

enum SQLStatementGuard {

    // MARK: - Classification

    static func classify(_ rawStatement: String) -> SQLStatementClassification {
        let stripped = strippedOfCommentsAndWhitespace(rawStatement)
        guard let firstWord = leadingKeyword(in: stripped) else {
            return SQLStatementClassification(kind: .unrecognized, keyword: "", target: nil)
        }
        let upper = firstWord.uppercased()

        if upper == "WITH" {
            // CTE: the verb that matters is the one following `WITH x AS (...), y AS (...)`.
            guard let realKeyword = keywordAfterCTE(in: stripped) else {
                // A CTE with no detectable verb after its balanced parentheses: we
                // don't know what follows, so we don't silently approve it.
                return SQLStatementClassification(kind: .unrecognized, keyword: upper, target: nil)
            }
            return classification(forKeyword: realKeyword, in: stripped)
        }

        return classification(forKeyword: upper, in: stripped)
    }

    static func classify(_ statements: [String]) -> [SQLStatementClassification] {
        statements.map(classify)
    }

    // MARK: - Batch assessment

    /// Verdict on a batch of statements (a console can run several
    /// queries separated by `;` in one pass): the most severe one wins.
    struct BatchAssessment {
        let classifications: [SQLStatementClassification]

        var blockedStatements: [SQLStatementClassification] {
            classifications.filter { $0.kind.isBlockedBySchemaGuard }
        }
        var isBlocked: Bool { !blockedStatements.isEmpty }

        var statementsNeedingConfirmation: [SQLStatementClassification] {
            classifications.filter { $0.kind.requiresDataModificationConfirmation }
        }
        /// A confirmation only makes sense if NOTHING is already blocking — a
        /// blocked batch doesn't run at all, so confirming another
        /// line in the same batch is a moot question.
        var needsConfirmation: Bool { !isBlocked && !statementsNeedingConfirmation.isEmpty }
    }

    static func assess(_ statements: [String]) -> BatchAssessment {
        BatchAssessment(classifications: classify(statements))
    }

    // MARK: - Keyword sets

    private static let schemaKeywords: Set<String> = [
        "CREATE", "ALTER", "DROP", "ATTACH", "DETACH"
    ]
    private static let dataKeywords: Set<String> = [
        "INSERT", "UPDATE", "DELETE", "REPLACE"
    ]
    private static let queryKeywords: Set<String> = [
        "SELECT", "EXPLAIN", "VALUES"
    ]
    private static let transactionKeywords: Set<String> = [
        "BEGIN", "COMMIT", "END", "ROLLBACK", "SAVEPOINT", "RELEASE"
    ]
    private static let maintenanceKeywords: Set<String> = [
        "VACUUM", "ANALYZE", "REINDEX"
    ]

    /// A PRAGMA with no `=` but whose call has a real side effect (not a plain
    /// read) — `wal_checkpoint`/`optimize`/`incremental_vacuum`/`shrink_memory`
    /// write to disk even with no assignment syntax.
    private static let sideEffectPragmasWithoutAssignment: Set<String> = [
        "WAL_CHECKPOINT", "OPTIMIZE", "INCREMENTAL_VACUUM", "SHRINK_MEMORY"
    ]

    private static func classification(forKeyword upper: String, in stripped: String) -> SQLStatementClassification {
        if schemaKeywords.contains(upper) {
            return SQLStatementClassification(kind: .schemaModification, keyword: upper, target: target(afterDDL: upper, in: stripped))
        }
        if dataKeywords.contains(upper) {
            return SQLStatementClassification(kind: .dataModification, keyword: upper, target: target(afterDML: upper, in: stripped))
        }
        if queryKeywords.contains(upper) {
            return SQLStatementClassification(kind: .query, keyword: upper, target: nil)
        }
        if transactionKeywords.contains(upper) {
            return SQLStatementClassification(kind: .transactionControl, keyword: upper, target: nil)
        }
        if maintenanceKeywords.contains(upper) {
            return SQLStatementClassification(kind: .maintenance, keyword: upper, target: nil)
        }
        if upper == "PRAGMA" {
            return classifyPragma(stripped)
        }
        return SQLStatementClassification(kind: .unrecognized, keyword: upper, target: nil)
    }

    private static func classifyPragma(_ stripped: String) -> SQLStatementClassification {
        // The pragma's name is the first word after "PRAGMA".
        let afterPragma = stripped.dropFirst("PRAGMA".count).trimmingCharacters(in: .whitespaces)
        let pragmaName = leadingKeyword(in: afterPragma)?.uppercased() ?? ""
        let hasAssignment = stripped.contains("=")
        let looksWriteish = hasAssignment || sideEffectPragmasWithoutAssignment.contains(pragmaName)
        return SQLStatementClassification(
            kind: looksWriteish ? .schemaModification : .query,
            keyword: "PRAGMA",
            target: pragmaName.isEmpty ? nil : pragmaName
        )
    }

    // MARK: - Target extraction (informatif uniquement)

    private static func target(afterDML upper: String, in text: String) -> String? {
        let pattern: String
        switch upper {
        case "INSERT", "REPLACE":
            pattern = #"(?:INSERT(?:\s+OR\s+\w+)?|REPLACE)\s+INTO\s+["`\[]?(\w+)"#
        case "UPDATE":
            pattern = #"UPDATE\s+["`\[]?(\w+)"#
        case "DELETE":
            pattern = #"DELETE\s+FROM\s+["`\[]?(\w+)"#
        default:
            return nil
        }
        return firstCapturedGroup(pattern, in: text)
    }

    private static func target(afterDDL upper: String, in text: String) -> String? {
        let pattern: String
        switch upper {
        case "CREATE":
            pattern = #"CREATE\s+(?:TEMP(?:ORARY)?\s+)?(?:TABLE|INDEX|TRIGGER|VIEW|UNIQUE\s+INDEX)\s+(?:IF\s+NOT\s+EXISTS\s+)?["`\[]?(\w+)"#
        case "ALTER":
            pattern = #"ALTER\s+TABLE\s+["`\[]?(\w+)"#
        case "DROP":
            pattern = #"DROP\s+(?:TABLE|INDEX|TRIGGER|VIEW)\s+(?:IF\s+EXISTS\s+)?["`\[]?(\w+)"#
        case "ATTACH", "DETACH":
            pattern = #"(?:ATTACH|DETACH)\s+(?:DATABASE\s+)?["'`\[]?([\w.]+)"#
        default:
            return nil
        }
        return firstCapturedGroup(pattern, in: text)
    }

    private static func firstCapturedGroup(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let match = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - CTE handling

    /// `WITH a AS (...), b AS (SELECT ...) DELETE FROM x WHERE ...` — the verb
    /// that decides the danger is the one following the last CTE
    /// definition, not "WITH" itself. We advance character by character counting
    /// parentheses to skip over the definitions, however nested
    /// they are, then read the first keyword found at depth 0.
    private static func keywordAfterCTE(in text: String) -> String? {
        var depth = 0
        var chars = Substring(text)
        // Skip "WITH" (and an optional "RECURSIVE").
        chars = chars.dropFirst(4).drop(while: { $0.isWhitespace })
        if chars.uppercased().hasPrefix("RECURSIVE") {
            chars = chars.dropFirst("RECURSIVE".count).drop(while: { $0.isWhitespace })
        }
        var i = chars.startIndex
        while i < chars.endIndex {
            let c = chars[i]
            if c == "(" { depth += 1 }
            else if c == ")" { depth -= 1 }
            else if depth == 0, c.isLetter {
                // First keyword found outside any parentheses: either the name
                // of a new CTE followed by AS (to ignore), or the real verb.
                let rest = chars[i...]
                guard let word = leadingKeyword(in: String(rest)) else { break }
                let upper = word.uppercased()
                if upper == "AS" {
                    i = chars.index(i, offsetBy: word.count)
                    continue
                }
                // A CTE identifier followed elsewhere by a "(" (its columns or its
                // body) rather than a known verb = this isn't yet the final
                // verb, keep advancing.
                if schemaKeywords.contains(upper) || dataKeywords.contains(upper) || queryKeywords.contains(upper) {
                    return upper
                }
                i = chars.index(i, offsetBy: word.count)
                continue
            }
            i = chars.index(after: i)
        }
        return nil
    }

    // MARK: - Tokenizing helpers

    private static func strippedOfCommentsAndWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count, chars[i] == "-", chars[i + 1] == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if i + 1 < chars.count, chars[i] == "/", chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First alphabetic token (letters/underscore) at the start of `text`
    /// (after an optional leading space). `nil` if `text` doesn't start with
    /// any letter (a parenthesis, a digit, punctuation, empty text…).
    private static func leadingKeyword(in text: String) -> String? {
        var word = ""
        for ch in text {
            if ch.isLetter || ch == "_" {
                word.append(ch)
            } else if word.isEmpty, ch.isWhitespace {
                continue
            } else {
                break
            }
        }
        return word.isEmpty ? nil : word
    }
}

// MARK: - Shared messages

/// FR text shown by both the SQL Console AND the AI assistant
/// (`SQLConsoleView`, `SQLAssistantSheet`) — a single place so the two
/// texts can't drift apart over successive tweaks (both answer the
/// same question: "what will this query do and why is it blocked/needs confirmation").
enum SQLGuardMessages {

    /// Message for the blocking alert (a schema change).
    static func blocked(_ statements: [SQLStatementClassification]) -> String {
        let items = statements.map { c -> String in
            let label = c.keyword.isEmpty ? "Instruction non reconnue" : c.keyword
            return c.target.map { "• \(label) — \($0)" } ?? "• \(label)"
        }
        let list = items.isEmpty ? "" : "\n\n" + items.joined(separator: "\n")
        return """
        Cette requête modifierait la STRUCTURE de la base de données (une table, une colonne, un index…), pas seulement son contenu.\(list)

        Nemoris gère son schéma exclusivement via ses propres migrations internes — l'exécuter ici rendrait très probablement vos données illisibles par l'app. Elle n'a pas été exécutée.

        Besoin réel d'une modification de structure ? Ça doit passer par une mise à jour de l'app.
        """
    }

    /// Message for the confirmation (a data change).
    static func confirmation(_ statements: [SQLStatementClassification]) -> String {
        var byKeywordAndTarget: [String: Set<String>] = [:]
        var countsWithoutTarget: [String: Int] = [:]
        for c in statements {
            let label = c.keyword.isEmpty ? "Instruction non reconnue" : c.keyword
            if let target = c.target {
                byKeywordAndTarget[label, default: []].insert(target)
            } else {
                countsWithoutTarget[label, default: 0] += 1
            }
        }
        var lines: [String] = []
        for keyword in byKeywordAndTarget.keys.sorted() {
            let targets = byKeywordAndTarget[keyword]!.sorted().joined(separator: ", ")
            lines.append("• \(keyword) sur \(targets)")
        }
        for keyword in countsWithoutTarget.keys.sorted() {
            let count = countsWithoutTarget[keyword]!
            lines.append("• \(keyword)" + (count > 1 ? " × \(count)" : ""))
        }
        let list = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
        return "\(list)Cette action modifie des lignes existantes et n'est pas annulable depuis l'app. Il est recommandé de créer une sauvegarde avant de continuer — tu pourras restaurer l'état actuel depuis Réglages › Sauvegarde en cas d'erreur."
    }
}
