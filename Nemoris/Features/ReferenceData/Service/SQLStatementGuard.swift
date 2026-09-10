import Foundation

/// Classe une instruction SQL isolée par ce qu'elle ferait RÉELLEMENT à la base
/// (lecture / écriture de lignes / modification du schéma) — c'est le garde-fou
/// de la Console SQL et de l'assistant IA (les deux seuls chemins qui exécutent
/// du SQL tapé/généré librement, cf. `TransactionRepository.executeSQL`).
///
/// Deux dangers distincts, traités différemment :
/// - une modification de SCHÉMA (CREATE/ALTER/DROP…) désynchronise la base du
///   schéma que l'app attend (`DatabaseManager.migrateIfNeeded`, dont le
///   détecteur de drift traite déjà tout hand-edit "via la console SQL" comme
///   LE risque à surveiller — cf. CLAUDE.md §AXE L). Ce n'est pas récupérable
///   depuis l'app : bloqué, sans option de passage en force.
/// - une modification de DONNÉES (INSERT/UPDATE/DELETE/REPLACE) reste une
///   opération légitime d'un power user, mais irréversible depuis l'app —
///   demande confirmation explicite, avec une sauvegarde proposée avant.
///
/// Moteur PUR (aucun accès SQLite/réseau, ne connaît que le TEXTE de la
/// requête) — ne l'exécute jamais, se contente de la lire. Couvert par
/// `Tests/check_purity.sh` et `NemorisTests/SQLStatementGuardTests.swift`.
enum SQLStatementKind: Equatable {
    /// Lecture seule : SELECT, EXPLAIN, PRAGMA de lecture.
    case query
    /// Écrit des LIGNES sans toucher au schéma : INSERT / UPDATE / DELETE / REPLACE.
    case dataModification
    /// Modifie la STRUCTURE de la base : CREATE / ALTER / DROP / ATTACH / DETACH,
    /// ou un PRAGMA qui altère un réglage persistant (`user_version`,
    /// `journal_mode`…) — `user_version` en particulier est ce que
    /// `DatabaseManager` utilise pour savoir quelles migrations appliquer :
    /// le modifier à la main revient à mentir à l'app sur son propre schéma.
    case schemaModification
    /// BEGIN / COMMIT / ROLLBACK / SAVEPOINT / RELEASE — contrôle transactionnel,
    /// ni lecture ni écriture de contenu en soi.
    case transactionControl
    /// VACUUM / ANALYZE / REINDEX — réécrit le fichier ou des statistiques
    /// internes, mais ne change ni le schéma logique ni le contenu des tables.
    case maintenance
    /// Premier mot-clé non reconnu par ce classifieur. Jamais auto-approuvé :
    /// une requête qu'on ne sait pas nommer n'est pas une requête dont on peut
    /// garantir qu'elle ne modifie rien.
    case unrecognized

    /// Bloque l'exécution avant toute confirmation — casserait la compatibilité
    /// de la base avec l'app, pas de bouton "quand même" dans la console.
    var isBlockedBySchemaGuard: Bool { self == .schemaModification }

    /// Demande une confirmation explicite (avec proposition de sauvegarde)
    /// avant exécution — l'action reste possible, juste jamais silencieuse.
    var requiresDataModificationConfirmation: Bool {
        self == .dataModification || self == .unrecognized
    }
}

struct SQLStatementClassification: Equatable {
    let kind: SQLStatementKind
    /// Premier mot-clé significatif détecté, en majuscules (ex. "DROP", "DELETE").
    let keyword: String
    /// Cible détectée (nom de table/index/trigger) si le motif le permet —
    /// purement informatif pour l'affichage, jamais utilisé pour décider.
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
            // CTE : le verbe qui compte est celui qui suit `WITH x AS (...), y AS (...)`.
            guard let realKeyword = keywordAfterCTE(in: stripped) else {
                // CTE sans verbe détectable après ses parenthèses balancées : on ne
                // sait pas ce qui suit, donc on ne l'approuve pas silencieusement.
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

    /// Verdict sur un lot de statements (une console peut exécuter plusieurs
    /// requêtes séparées par `;` en une passe) : le plus sévère l'emporte.
    struct BatchAssessment {
        let classifications: [SQLStatementClassification]

        var blockedStatements: [SQLStatementClassification] {
            classifications.filter { $0.kind.isBlockedBySchemaGuard }
        }
        var isBlocked: Bool { !blockedStatements.isEmpty }

        var statementsNeedingConfirmation: [SQLStatementClassification] {
            classifications.filter { $0.kind.requiresDataModificationConfirmation }
        }
        /// Une confirmation n'a de sens que si RIEN n'est déjà bloquant — un lot
        /// bloqué ne s'exécute pas du tout, la question de confirmer une autre
        /// ligne du même lot ne se pose pas.
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

    /// PRAGMA sans `=` mais dont l'appel a un effet de bord réel (pas une simple
    /// lecture) — `wal_checkpoint`/`optimize`/`incremental_vacuum`/`shrink_memory`
    /// écrivent sur disque même sans syntaxe d'affectation.
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
        // Le nom du pragma est le premier mot après "PRAGMA".
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

    /// `WITH a AS (...), b AS (SELECT ...) DELETE FROM x WHERE ...` — le verbe
    /// qui décide du danger est celui qui suit la dernière définition de CTE,
    /// pas "WITH" lui-même. On avance caractère par caractère en comptant les
    /// parenthèses pour sauter par-dessus les définitions, aussi imbriquées
    /// soient-elles, puis on lit le premier mot-clé rencontré au niveau 0.
    private static func keywordAfterCTE(in text: String) -> String? {
        var depth = 0
        var chars = Substring(text)
        // Sauter "WITH" (et un éventuel "RECURSIVE").
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
                // Premier mot-clé rencontré hors de toute parenthèse : soit le nom
                // d'une nouvelle CTE suivi de AS (à ignorer), soit le vrai verbe.
                let rest = chars[i...]
                guard let word = leadingKeyword(in: String(rest)) else { break }
                let upper = word.uppercased()
                if upper == "AS" {
                    i = chars.index(i, offsetBy: word.count)
                    continue
                }
                // Un identifiant de CTE suivi ailleurs d'un "(" (ses colonnes ou son
                // corps) plutôt que d'un verbe connu = ce n'est pas encore le verbe
                // final, on continue d'avancer.
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

    /// Premier token alphabétique (lettres/underscore) en tête de `text`
    /// (après un éventuel espace initial). `nil` si `text` ne commence par
    /// aucune lettre (parenthèse, chiffre, ponctuation, texte vide…).
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

// MARK: - Messages partagés

/// Textes FR affichés par la Console SQL ET l'assistant IA (`SQLConsoleView`,
/// `SQLAssistantSheet`) — un seul endroit pour éviter que les deux textes
/// divergent au fil des retouches (les deux répondent à la même question :
/// "que va faire cette requête et pourquoi c'est bloqué/à confirmer").
enum SQLGuardMessages {

    /// Message de l'alerte de blocage (modification de schéma).
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

    /// Message de la confirmation (modification de données).
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
