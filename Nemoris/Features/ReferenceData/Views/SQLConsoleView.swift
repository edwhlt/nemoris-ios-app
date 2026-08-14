import SwiftUI
import Charts
#if canImport(UIKit)
import UIKit
#endif
import TipKit

// MARK: - Syntax Highlighting Editor

#if os(macOS)
/// Version macOS : NSTextView dans son scroll view. Même highlight partagé
/// que la version iOS (UIFont/UIColor → NSFont/NSColor via PlatformShims).
struct SyntaxHighlightingEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.delegate = context.coordinator
            tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticSpellingCorrectionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.allowsUndo = true
            tv.textContainerInset = NSSize(width: 8, height: 8)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        guard tv.string != text else { return }
        let sel = tv.selectedRange()
        tv.textStorage?.setAttributedString(sqlHighlight(text))
        let newLen = (tv.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(sel.location, newLen), length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: SyntaxHighlightingEditor
        init(_ p: SyntaxHighlightingEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let sel = tv.selectedRange()
            tv.textStorage?.setAttributedString(sqlHighlight(tv.string))
            tv.setSelectedRange(sel)
            parent.text = tv.string
        }
    }
}
#else
struct SyntaxHighlightingEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartDashesType = .no
        tv.smartQuotesType = .no
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        uiView.backgroundColor = UIColor.secondarySystemBackground
        guard uiView.text != text else { return }
        let sel = uiView.selectedRange
        uiView.attributedText = sqlHighlight(text)
        let newLen = (uiView.text as NSString).length
        uiView.selectedRange = NSRange(location: min(sel.location, newLen), length: 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextViewDelegate {
        let parent: SyntaxHighlightingEditor
        init(_ p: SyntaxHighlightingEditor) { parent = p }

        func textViewDidChange(_ tv: UITextView) {
            let sel = tv.selectedRange
            tv.attributedText = sqlHighlight(tv.text)
            tv.selectedRange = sel
            parent.text = tv.text
        }
    }
}
#endif

/// Highlight SQL partagé iOS/macOS (UIFont/UIColor typealiasés côté Mac).
private func sqlHighlight(_ text: String) -> NSAttributedString {
        let attr = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)

        attr.addAttribute(.font,            value: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: full)
        attr.addAttribute(.foregroundColor, value: UIColor.label, range: full)

        func apply(pattern: String, color: UIColor, options: NSRegularExpression.Options = [], bold: Bool = false) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            re.enumerateMatches(in: text, range: full) { m, _, _ in
                guard let r = m?.range else { return }
                attr.addAttribute(.foregroundColor, value: color, range: r)
                if bold { attr.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 13, weight: .bold), range: r) }
            }
        }

        // Keywords (blue)
        let kw = "SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|CROSS|ON|GROUP|ORDER|LIMIT|OFFSET|HAVING|DISTINCT|UNION|ALL|INSERT|INTO|VALUES|UPDATE|SET|DELETE|CREATE|DROP|ALTER|TABLE|INDEX|VIEW|TRIGGER|AS|AND|OR|NOT|NULL|IS|IN|LIKE|GLOB|BETWEEN|CASE|WHEN|THEN|ELSE|END|BY|ASC|DESC|EXISTS|REFERENCES|PRIMARY|KEY|AUTOINCREMENT|DEFAULT|UNIQUE|CHECK|FOREIGN|CASCADE|IF|PRAGMA|BEGIN|COMMIT|ROLLBACK|TRANSACTION|REPLACE|WITH|RECURSIVE"
        apply(pattern: "\\b(\(kw))\\b", color: .systemBlue, options: .caseInsensitive)

        // Built-in functions (teal) — must come after keywords so they override
        let fn = "COUNT|SUM|AVG|MAX|MIN|TOTAL|COALESCE|IFNULL|NULLIF|ABS|ROUND|CEIL|FLOOR|UPPER|LOWER|LENGTH|LTRIM|RTRIM|TRIM|SUBSTR|REPLACE|INSTR|PRINTF|FORMAT|STRFTIME|DATE|TIME|DATETIME|JULIANDAY|UNIXEPOCH|CAST|TYPEOF|LAST_INSERT_ROWID|CHANGES|RANDOM|HEX|QUOTE|ZEROBLOB|ROW_NUMBER|RANK|DENSE_RANK|LAG|LEAD"
        apply(pattern: "\\b(\(fn))\\s*\\(", color: .systemTeal, options: .caseInsensitive)

        // Numbers (purple)
        apply(pattern: "\\b\\d+(\\.\\d+)?\\b", color: .systemPurple)

        // Strings (red)
        apply(pattern: "'[^']*'", color: .systemRed)

        // Comments (green) — overrides keywords inside comments
        apply(pattern: "--[^\n]*", color: .systemGreen)

        // Section headers  -- Name --  (orange bold, overrides comment style)
        apply(pattern: "^--\\s*.+?\\s*--\\s*$", color: .systemOrange, options: .anchorsMatchLines, bold: true)

        // Variables {{name}} (orange bold)
        apply(pattern: "\\{\\{[^}]+\\}\\}", color: .systemOrange, bold: true)

        return attr
}

// MARK: - Variable Form
//
// Syntaxe des tokens : {{nom}} | {{nom:type}} | {{nom:type=défaut}} | {{nom=défaut}}.
// Un {{nom}} nu (sans ":") reste traité comme .text — les .sql déjà sauvegardés
// avec leurs propres guillemets autour de {{x}} continuent de marcher à l'identique.

/// Type déclaré pour une variable. `.text` est le défaut si omis.
enum SQLVariableType: String {
    case text     // chaîne libre — substituée entre guillemets SQL (échappés)
    case number   // nombre — substitué tel quel, sans guillemets
    case year     // année 4 chiffres — clavier numérique ; substituée ENTRE GUILLEMETS
                  // car comparée à strftime('%Y', ...), qui renvoie du texte, jamais un entier
    case date     // date — DatePicker natif ; substituée en 'yyyy-MM-dd'
}

struct SQLVariableSpec: Identifiable, Hashable {
    let name: String
    let type: SQLVariableType
    let defaultValue: String?
    var id: String { name }
}

/// Grammaire des tokens `{{...}}`, centralisée pour que la détection
/// (formulaire), le pré-remplissage et la substitution (exécution) ne
/// puissent jamais diverger entre eux.
enum SQLVariableParsing {
    private static let tokenRegex = try? NSRegularExpression(pattern: "\\{\\{([^}]+)\\}\\}")

    /// Parse le contenu d'un seul token (le texte déjà extrait des `{{ }}`).
    static func parse(_ raw: String) -> SQLVariableSpec {
        var namePart = raw
        var defaultValue: String?
        if let eq = raw.firstIndex(of: "=") {
            namePart = String(raw[raw.startIndex..<eq])
            let def = String(raw[raw.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            defaultValue = def.isEmpty ? nil : def
        }
        var name = namePart.trimmingCharacters(in: .whitespaces)
        var type = SQLVariableType.text
        if let colon = namePart.firstIndex(of: ":") {
            name = String(namePart[namePart.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let typeStr = String(namePart[namePart.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces).lowercased()
            type = SQLVariableType(rawValue: typeStr) ?? .text
        }
        return SQLVariableSpec(name: name, type: type, defaultValue: defaultValue)
    }

    /// Variables détectées dans un texte SQL, dédupliquées par nom (garde la
    /// première occurrence si le même nom est annoté différemment ailleurs —
    /// cas limite, mais le champ du formulaire doit rester unique par nom).
    static func extract(from sql: String) -> [SQLVariableSpec] {
        guard let re = tokenRegex else { return [] }
        let range = NSRange(sql.startIndex..., in: sql)
        var seen = Set<String>()
        var result: [SQLVariableSpec] = []
        re.enumerateMatches(in: sql, range: range) { m, _, _ in
            guard let r = m?.range(at: 1), let sr = Range(r, in: sql) else { return }
            let spec = parse(String(sql[sr]).trimmingCharacters(in: .whitespaces))
            if seen.insert(spec.name).inserted { result.append(spec) }
        }
        return result
    }

    /// Encode une valeur brute tapée par l'utilisateur en littéral SQL selon le type
    /// déclaré. Seul `.number` reste non guillemété — tout le reste (y compris
    /// `.year`) est quoté et échappé pour être un littéral SQL valide sans que
    /// l'utilisateur ait à retaper ses propres guillemets dans le corps de la requête.
    static func sqlLiteral(_ rawValue: String, type: SQLVariableType) -> String {
        switch type {
        case .number:
            return rawValue.trimmingCharacters(in: .whitespaces)
        case .text, .year, .date:
            let escaped = rawValue.replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)'"
        }
    }

    /// Substitue chaque `{{...}}` par son littéral SQL. Reparse CHAQUE
    /// occurrence indépendamment (plutôt qu'un remplacement nom→texte global)
    /// pour rester correct même si un même nom apparaît avec des annotations
    /// différentes à plusieurs endroits du fichier.
    static func substitute(_ sql: String, values: [String: String]) -> String {
        guard let re = tokenRegex else { return sql }
        let ns = sql as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result = ""
        var lastEnd = 0
        for m in re.matches(in: sql, range: full) {
            result += ns.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            let spec = parse(ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces))
            let raw = values[spec.name] ?? spec.defaultValue ?? ""
            result += sqlLiteral(raw, type: spec.type)
            lastEnd = m.range.location + m.range.length
        }
        result += ns.substring(from: lastEnd)
        return result
    }

    static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

private struct VariableFormView: View {
    @Binding var variables: [String: String]
    let specs: [SQLVariableSpec]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text("Variables").font(.caption.bold())
            }
            .foregroundStyle(AppTheme.Colors.warning)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(specs) { spec in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("{{\(spec.name)}}")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(AppTheme.Colors.warning)
                            field(for: spec)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(Color(.tertiarySystemBackground))
    }

    @ViewBuilder
    private func field(for spec: SQLVariableSpec) -> some View {
        let textBinding = Binding<String>(
            get: { variables[spec.name] ?? "" },
            set: { variables[spec.name] = $0 }
        )
        switch spec.type {
        case .date:
            DatePicker("", selection: Binding<Date>(
                get: { SQLVariableParsing.isoDateFormatter.date(from: variables[spec.name] ?? "") ?? Date() },
                set: { variables[spec.name] = SQLVariableParsing.isoDateFormatter.string(from: $0) }
            ), displayedComponents: .date)
            .datePickerStyle(.compact)
            .labelsHidden()
            .frame(minWidth: 110, maxWidth: 160)
        case .year:
            TextField("aaaa", text: textBinding)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 70, maxWidth: 90)
                .keyboardType(.numberPad)
                .font(.system(.caption, design: .monospaced))
        case .number:
            TextField("valeur", text: textBinding)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 80, maxWidth: 140)
                .keyboardType(.decimalPad)
                .font(.system(.caption, design: .monospaced))
        case .text:
            TextField("valeur", text: textBinding)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100, maxWidth: 200)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - Helper

enum SQLConsoleHelper {
    private static let folderBookmarkKey = "sqlScriptsFolderBookmark"

    static func sqlDirectory() -> URL {
        resolveStoredFolder() ?? defaultSQLDirectory()
    }

    static var linkedFolderName: String? {
        resolveStoredFolder()?.lastPathComponent
    }

    static func linkFolder(from pickerURL: URL) throws {
        let hasAccess = pickerURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { pickerURL.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        // Sous App Sandbox, une bookmark créée sans .withSecurityScope se résout
        // en URL "plate" — startAccessingSecurityScopedResource() échoue au
        // prochain lancement et l'accès au dossier est silencieusement perdu.
        let data = try pickerURL.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let data = try pickerURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        UserDefaults.standard.set(data, forKey: folderBookmarkKey)
    }

    static func unlinkFolder() {
        UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
    }

    private static func resolveStoredFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else { return nil }
        var isStale = false
        #if os(macOS)
        let resolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI, .withSecurityScope]
        #else
        let resolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI]
        #endif
        guard let url = try? URL(resolvingBookmarkData: data, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        #if os(macOS)
        if isStale, let newData = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(newData, forKey: folderBookmarkKey)
        }
        #else
        if isStale, let newData = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(newData, forKey: folderBookmarkKey)
        }
        #endif
        return url
    }

    private static func defaultSQLDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("SQLRequests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func listSQLFiles() -> [URL] {
        listEntries(in: nil).compactMap { e in
            if case .file(let url) = e { return url }
            return nil
        }
    }

    // MARK: - Hierarchical browsing (folders + files)

    /// Une entrée dans le browser SQL : soit un dossier, soit un fichier .sql.
    enum Entry: Identifiable, Hashable {
        case folder(URL)
        case file(URL)

        var id: String {
            switch self {
            case .folder(let u), .file(let u): return u.path
            }
        }

        var url: URL {
            switch self {
            case .folder(let u), .file(let u): return u
            }
        }

        var isFolder: Bool {
            if case .folder = self { return true }
            return false
        }

        var displayName: String {
            switch self {
            case .folder(let u): return u.lastPathComponent
            case .file(let u):   return u.deletingPathExtension().lastPathComponent
            }
        }
    }

    /// Liste les entrées d'un répertoire. `nil` = racine (`sqlDirectory()`).
    /// Dossiers en premier (triés alpha), puis fichiers .sql (triés alpha).
    static func listEntries(in directory: URL?) -> [Entry] {
        let dir = directory ?? sqlDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        var folders: [URL] = []
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                folders.append(u)
            } else if u.pathExtension == "sql" {
                files.append(u)
            }
        }
        folders.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        files.sort { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        return folders.map { .folder($0) } + files.map { .file($0) }
    }

    /// Nœud de l'arborescence du browser. Chargement EAGER récursif — le
    /// répertoire SQL de l'utilisateur est petit (quelques dizaines d'entrées),
    /// le coût d'un scan complet est négligeable devant la simplicité gagnée.
    struct TreeNode: Identifiable {
        let entry: Entry
        let depth: Int
        var children: [TreeNode]
        var id: String { entry.id }   // = url.path : clé stable pour le Set d'expansion
    }

    /// Construit l'arborescence complète depuis la racine (ou `root`).
    /// S'appuie sur `listEntries(in:)` à chaque niveau — l'ordre « dossiers
    /// d'abord, tri alpha » est donc conservé à chaque profondeur.
    static func buildTree(rootedAt root: URL? = nil, depth: Int = 0) -> [TreeNode] {
        listEntries(in: root ?? sqlDirectory()).map { entry in
            TreeNode(
                entry: entry,
                depth: depth,
                children: entry.isFolder ? buildTree(rootedAt: entry.url, depth: depth + 1) : []
            )
        }
    }

    /// Tous les dossiers récursivement, racine incluse. Utilisé par le picker "Déplacer vers…".
    /// Renvoie des paires (label affichable avec indentation, URL).
    static func listAllFoldersRecursive(rootedAt root: URL? = nil, depth: Int = 0) -> [(label: String, url: URL)] {
        let dir = root ?? sqlDirectory()
        var result: [(String, URL)] = []
        let indent = String(repeating: "  ", count: depth)
        let label = depth == 0 ? "📁 \(dir.lastPathComponent) (racine)" : "\(indent)📁 \(dir.lastPathComponent)"
        result.append((label, dir))
        let entries = listEntries(in: dir)
        for case .folder(let sub) in entries {
            result.append(contentsOf: listAllFoldersRecursive(rootedAt: sub, depth: depth + 1))
        }
        return result
    }

    /// Crée un fichier .sql vide dans `directory` (ou la racine si nil).
    /// Renvoie l'URL du fichier créé, ou nil en cas d'échec / collision.
    @discardableResult
    static func createFile(name: String, in directory: URL?) -> URL? {
        let dir = directory ?? sqlDirectory()
        var cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { cleaned = "requete" }
        if !cleaned.hasSuffix(".sql") { cleaned += ".sql" }
        let url = dir.appendingPathComponent(cleaned)
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    /// Crée un sous-dossier dans `directory` (ou la racine si nil).
    @discardableResult
    static func createFolder(name: String, in directory: URL?) -> URL? {
        let dir = directory ?? sqlDirectory()
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let url = dir.appendingPathComponent(cleaned, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        } catch {
            return nil
        }
    }

    /// Renomme un fichier ou un dossier. Pour un fichier .sql, l'extension est
    /// re-ajoutée automatiquement si absente du nouveau nom.
    @discardableResult
    static func rename(_ url: URL, to newName: String) -> URL? {
        let cleaned = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        var target = cleaned
        if !isDir.boolValue && !target.hasSuffix(".sql") { target += ".sql" }
        let newURL = url.deletingLastPathComponent().appendingPathComponent(target)
        guard !FileManager.default.fileExists(atPath: newURL.path) else { return nil }
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            return newURL
        } catch {
            return nil
        }
    }

    /// Déplace `url` à l'intérieur du dossier `destinationFolder` (en gardant son nom).
    @discardableResult
    static func move(_ url: URL, toFolder destinationFolder: URL) -> URL? {
        let target = destinationFolder.appendingPathComponent(url.lastPathComponent)
        guard target.path != url.path else { return url }
        guard !FileManager.default.fileExists(atPath: target.path) else { return nil }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    /// Supprime un fichier ou un dossier (récursif).
    @discardableResult
    static func delete(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Query Section Model

struct SQLQuerySection: Identifiable {
    let id = UUID()
    let label: String
    let sql: String
    var result: SQLQueryResult?
    var error: String?
}

// MARK: - Chart detection (heuristic)

/// Détecte si un résultat a une forme "graphable" : EXACTEMENT une colonne
/// label + 1 à 4 colonnes numériques. Volontairement conservateur — pas de
/// tentative de tout visualiser, seulement le cas le plus courant d'une
/// requête d'agrégat (GROUP BY + SUM/COUNT/AVG), qui couvre la plupart des
/// recettes de `DatabaseSchemaView` (total par catégorie, évolution par mois,
/// répartition par métadonnée…). Un résultat qui ne matche pas reste un
/// tableau, sans message d'erreur — c'est un bonus, pas une fonctionnalité
/// qui peut "rater".
struct SQLResultChartPlan {
    let labelIndex: Int
    let seriesIndices: [Int]
    /// Ligne (LineMark) si le label ressemble à une date/mois (« 2026-01 »,
    /// « 2026-01-15 ») — sinon barres (BarMark) pour une répartition catégorielle.
    let isTimeSeries: Bool

    static func detect(from result: SQLQueryResult) -> SQLResultChartPlan? {
        // Cap de lignes : au-delà, un bar chart devient illisible et une requête
        // de ce volume n'est presque jamais la forme "1 label + N numériques"
        // qu'on cible ici (elle a déjà échoué la règle des colonnes en pratique).
        guard !result.rows.isEmpty, result.columns.count >= 2, result.rows.count <= 60 else { return nil }

        var labelIndices: [Int] = []
        var numericIndices: [Int] = []
        for (idx, name) in result.columns.enumerated() {
            // Les colonnes d'identifiant (id, foo_id) sont numériques mais ne
            // portent aucune magnitude à représenter — ce sont des clés, pas
            // des grandeurs. Les ignorer évite un bar chart de "id" absurde.
            let lower = name.lowercased()
            if lower == "id" || lower.hasSuffix("_id") { continue }

            let values = result.rows.compactMap { idx < $0.count ? $0[idx] : nil }.filter { !$0.isEmpty }
            if !values.isEmpty, values.allSatisfy({ Double($0) != nil }) {
                numericIndices.append(idx)
            } else {
                labelIndices.append(idx)
            }
        }

        guard labelIndices.count == 1, (1...4).contains(numericIndices.count) else { return nil }
        let labelIndex = labelIndices[0]
        let looksLikeDate = result.rows.allSatisfy { row in
            guard labelIndex < row.count, !row[labelIndex].isEmpty else { return true }
            return row[labelIndex].range(of: #"^\d{4}-\d{2}(-\d{2})?"#, options: .regularExpression) != nil
        }
        return SQLResultChartPlan(labelIndex: labelIndex, seriesIndices: numericIndices, isTimeSeries: looksLikeDate)
    }
}

enum SQLResultViewMode {
    case table, chart
}

// MARK: - Files List View

struct SQLFilesListView: View {

    @Environment(PurchaseManager.self) private var store
    /// Arborescence COMPLÈTE (eager) — les dossiers ne sont plus des vues
    /// poussées mais des nœuds pliables/dépliables dans une même liste.
    @State private var tree: [SQLConsoleHelper.TreeNode] = []
    /// Paths (= `TreeNode.id`) des dossiers actuellement dépliés. `@State`
    /// suffit : re-déplier après un aller-retour coûte un tap, et persister
    /// l'expansion en AppStorage serait du bruit pour un répertoire user petit.
    @State private var expandedPaths: Set<String> = []
    /// Dossier cible des alertes de création. `nil` = racine (toolbar « + ») ;
    /// posé par le menu contextuel « Nouveau … ici » d'une row dossier.
    @State private var creationDir: URL?
    @State private var showCreateFileAlert = false
    @State private var showCreateFolderAlert = false
    @State private var newName = ""
    @State private var selectedFile: URL?
    @State private var showEditor = false
    /// Doc du schéma en panneau (cf. `.adaptivePane` dans le body) plutôt qu'en push.
    @State private var showSchema = false
    @State private var renamingEntry: SQLConsoleHelper.Entry?
    @State private var movingEntry: SQLConsoleHelper.Entry?
    @State private var renameInput = ""
    @State private var errorMessage: String?
    private let consoleTip = SQLConsoleTip()

    private var navTitle: String {
        #if os(macOS)
        if let file = selectedFile { return file.deletingPathExtension().lastPathComponent }
        return "Console SQL"
        #else
        "Console SQL"
        #endif
    }

    /// Aplatissement préfixe de l'arbre : on ne descend dans `children` que si
    /// le dossier est déplié. Les paths périmés de `expandedPaths` (dossier
    /// supprimé/déplacé) sont simplement ignorés par le parcours.
    private var visibleRows: [SQLConsoleHelper.TreeNode] {
        var rows: [SQLConsoleHelper.TreeNode] = []
        func walk(_ nodes: [SQLConsoleHelper.TreeNode]) {
            for node in nodes {
                rows.append(node)
                if node.entry.isFolder, expandedPaths.contains(node.id) {
                    walk(node.children)
                }
            }
        }
        walk(tree)
        return rows
    }

    var body: some View {
        #if os(macOS)
        // ⚠️ Sur macOS, le fichier n'est PAS ouvert par un push (même via
        // `.navigationDestination(isPresented:)`, la forme "sûre"). Constaté
        // sur device : dès qu'une vue est poussée dans CETTE
        // NavigationStack, tout `.adaptivePane` ouvert depuis elle (le panneau
        // latéral desktop de `MainTabView`, cf. `AdaptivePane.swift`) se peint
        // SOUS le contenu poussé au lieu d'à côté — repro à 100% en ouvrant
        // l'assistant IA depuis l'éditeur ; redevient visible dès qu'on revient
        // (pop) à la racine. Root cause côté AppKit/NavigationStack (macOS 27
        // beta). Remède : zéro push, swap de contenu conditionnel par @State
        // (`selectedFile`) pour que la NavigationStack du module reste TOUJOURS
        // à sa racine. Les dossiers, eux, ne naviguent plus DU TOUT depuis la
        // refonte en arborescence : ils se plient/déplient sur place.
        Group {
            if let file = selectedFile {
                SQLEditorView(fileURL: file)
            } else {
                fileListBody
            }
        }
        .navigationTitle(navTitle)
        .toolbar {
            if selectedFile != nil {
                ToolbarItem(placement: .navigation) {
                    Button {
                        selectedFile = nil
                    } label: {
                        Label("Retour", systemImage: "chevron.left")
                    }
                }
            }
        }
        // Fond de l'app posé explicitement — sans lui la colonne « content » de
        // la NavigationSplitView macOS montre son matériau vibrant par défaut
        // au lieu du fond neutre AppTheme (). Couvre les deux
        // branches (liste de fichiers ET éditeur, swap par @State).
        .background(AppTheme.Colors.background.ignoresSafeArea())
        #else
        fileListBody
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showEditor) {
                if let file = selectedFile { SQLEditorView(fileURL: file) }
            }
        #endif
    }

    // MARK: - File list (contenu partagé, jamais lui-même poussé sur macOS)

    @ViewBuilder
    private var fileListBody: some View {
        // L'état vide est rendu HORS de la `List` : dans une row il hérite de la
        // largeur de la row et se retrouve calé à gauche sur une fenêtre large
        // (au lieu d'être centré dans la vue). En overlay il occupe toute la
        // surface disponible et se centre naturellement.
        List {
            TipView(consoleTip, arrowEdge: .none)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            ForEach(visibleRows) { node in
                entryRow(node)
            }
        }
        #if os(macOS)
        // Décolle la 1ère carte du délimiteur natif macOS (barre d'outils ↔
        // contenu scrollé) — même correctif que TransactionsView.
        .contentMargins(.top, AppTheme.Spacing.md, for: .scrollContent)
        #endif
        .scrollContentBackground(.hidden)
        .overlay {
            if tree.isEmpty {
                EmptyStateView(
                    icon: "doc.text",
                    title: "Aucun fichier SQL",
                    message: "Appuyez sur + pour créer un fichier ou un dossier."
                )
            }
        }
        .paywallOverlay(for: .sqlConsole)
        // Doc du schéma : contenu de RÉFÉRENCE (une feuille qu'on consulte à côté
        // de sa requête) → panneau, pas un push. Un push depuis un module empile
        // une vue dans sa NavigationStack, ce qui pose les problèmes de bascule
        // de module déjà rencontrés sur Tricount/Investissements (et, depuis,
        // le masquage du panneau documenté dans `body` ci-dessus).
        .adaptivePane(isPresented: $showSchema) {
            DatabaseSchemaView()
                .paneChrome("Schéma de la base",
                            cancelLabel: "Fermer", onCancel: { showSchema = false })
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ToolbarPaywallGate(feature: .sqlConsole) {
                    PaneToggleButton(label: "Schéma", systemImage: "tablecells", isOn: $showSchema)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                ToolbarPaywallGate(feature: .sqlConsole) {
                    Menu {
                        Button {
                            creationDir = nil
                            newName = ""
                            showCreateFileAlert = true
                        } label: {
                            Label("Nouveau fichier .sql", systemImage: "doc.badge.plus")
                        }
                        Button {
                            creationDir = nil
                            newName = ""
                            showCreateFolderAlert = true
                        } label: {
                            Label("Nouveau dossier", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .alert("Nouveau fichier SQL", isPresented: $showCreateFileAlert) {
            TextField("nom_du_fichier", text: $newName)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Créer") { handleCreateFile() }
            Button("Annuler", role: .cancel) {}
        } message: { Text("Sans extension .sql") }
        .alert("Nouveau dossier", isPresented: $showCreateFolderAlert) {
            TextField("nom_du_dossier", text: $newName)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Créer") { handleCreateFolder() }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Renommer", isPresented: Binding(
            get: { renamingEntry != nil },
            set: { if !$0 { renamingEntry = nil } }
        )) {
            TextField("nouveau_nom", text: $renameInput)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            Button("Renommer") { handleRename() }
            Button("Annuler", role: .cancel) { renamingEntry = nil }
        }
        .adaptivePane(item: $movingEntry) { entry in
            FolderPickerSheet(
                title: "Déplacer « \(entry.displayName) » vers…",
                excludingFolder: entry.isFolder ? entry.url : nil
            ) { destination in
                handleMove(entry: entry, to: destination)
            }
        }
        .alert("Erreur", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear { reload() }
    }

    /// Row de l'arbre — indentation MANUELLE + chevron animé, PAS de
    /// `DisclosureGroup` : les rows restent des `Button` plats, ce qui garantit
    /// par construction la compatibilité avec `rowActions` (swipe iOS / clic
    /// droit macOS) et évite de composer notre indentation avec celle,
    /// automatique, du DisclosureGroup.
    @ViewBuilder
    private func entryRow(_ node: SQLConsoleHelper.TreeNode) -> some View {
        let entry = node.entry
        switch entry {
        case .folder(let folderURL):
            Button {
                withAnimation(.snappy) {
                    if expandedPaths.contains(node.id) {
                        expandedPaths.remove(node.id)
                    } else {
                        expandedPaths.insert(node.id)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .rotationEffect(.degrees(expandedPaths.contains(node.id) ? 90 : 0))
                        .frame(width: 14)
                    Label(entry.displayName, systemImage: "folder.fill")
                        .foregroundStyle(AppTheme.Colors.accent)
                    Spacer()
                }
                .padding(.leading, CGFloat(node.depth) * 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    creationDir = folderURL
                    newName = ""
                    showCreateFileAlert = true
                } label: {
                    Label("Nouveau fichier ici", systemImage: "doc.badge.plus")
                }
                Button {
                    creationDir = folderURL
                    newName = ""
                    showCreateFolderAlert = true
                } label: {
                    Label("Nouveau dossier ici", systemImage: "folder.badge.plus")
                }
            }
            .rowActions(trailing: [
                RowAction("Supprimer", systemImage: "trash", role: .destructive) { handleDelete(entry) },
                RowAction("Déplacer", systemImage: "folder", tint: AppTheme.Colors.accentSecondary) { movingEntry = entry },
                RowAction("Renommer", systemImage: "pencil", tint: AppTheme.Colors.accent) {
                    renameInput = entry.displayName
                    renamingEntry = entry
                }
            ], trailingFullSwipe: false)
        case .file(let fileURL):
            Button {
                selectedFile = fileURL
                #if !os(macOS)
                showEditor = true
                #endif
            } label: {
                HStack(spacing: 6) {
                    // Réserve la largeur du chevron des dossiers : fichiers et
                    // dossiers d'une même profondeur restent alignés.
                    Color.clear.frame(width: 14, height: 1)
                    Label(entry.displayName, systemImage: "doc.text.fill")
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Spacer()
                }
                .padding(.leading, CGFloat(node.depth) * 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rowActions(trailing: [
                RowAction("Supprimer", systemImage: "trash", role: .destructive) { handleDelete(entry) },
                RowAction("Déplacer", systemImage: "folder", tint: AppTheme.Colors.accentSecondary) { movingEntry = entry },
                RowAction("Renommer", systemImage: "pencil", tint: AppTheme.Colors.accent) {
                    renameInput = entry.displayName
                    renamingEntry = entry
                }
            ], trailingFullSwipe: false)
        }
    }

    // MARK: - Actions

    private func reload() {
        tree = SQLConsoleHelper.buildTree()
    }

    /// Rend visible ce qu'on vient de créer/déplacer : déplie le dossier cible.
    /// Ses ancêtres sont forcément déjà dépliés quand la cible vient d'un menu
    /// contextuel (la row était visible) ; après un « Déplacer vers… », on
    /// déplie toute la chaîne d'ancêtres sous la racine SQL.
    private func revealFolder(_ folder: URL?) {
        guard let folder else { return }
        let rootPath = SQLConsoleHelper.sqlDirectory().path
        var current = folder
        while current.path.hasPrefix(rootPath), current.path != rootPath {
            expandedPaths.insert(current.path)
            current = current.deletingLastPathComponent()
        }
    }

    private func handleCreateFile() {
        guard let url = SQLConsoleHelper.createFile(name: newName, in: creationDir) else {
            errorMessage = "Impossible de créer ce fichier (nom invalide ou déjà existant)."
            return
        }
        revealFolder(creationDir)
        reload()
        selectedFile = url
        #if !os(macOS)
        showEditor = true
        #endif
    }

    private func handleCreateFolder() {
        guard SQLConsoleHelper.createFolder(name: newName, in: creationDir) != nil else {
            errorMessage = "Impossible de créer ce dossier (nom invalide ou déjà existant)."
            return
        }
        revealFolder(creationDir)
        reload()
    }

    private func handleRename() {
        guard let entry = renamingEntry else { return }
        renamingEntry = nil
        guard SQLConsoleHelper.rename(entry.url, to: renameInput) != nil else {
            errorMessage = "Impossible de renommer (nom déjà utilisé ?)."
            return
        }
        reload()
    }

    private func handleMove(entry: SQLConsoleHelper.Entry, to destination: URL) {
        guard SQLConsoleHelper.move(entry.url, toFolder: destination) != nil else {
            errorMessage = "Déplacement impossible (un élément du même nom existe déjà)."
            return
        }
        revealFolder(destination)
        reload()
    }

    private func handleDelete(_ entry: SQLConsoleHelper.Entry) {
        _ = SQLConsoleHelper.delete(entry.url)
        reload()
    }
}

// MARK: - Folder picker sheet

private struct FolderPickerSheet: View {
    let title: String
    /// Si non-nil, ce dossier (et ses sous-dossiers) sont exclus pour éviter
    /// de déplacer un dossier dans lui-même.
    let excludingFolder: URL?
    let onSelect: (URL) -> Void

    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    private var folders: [(label: String, url: URL)] {
        let all = SQLConsoleHelper.listAllFoldersRecursive()
        guard let excl = excludingFolder else { return all }
        return all.filter { !$0.url.path.hasPrefix(excl.path) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
                Section {
                    ForEach(folders, id: \.url) { folder in
                        Button {
                            onSelect(folder.url)
                            dismiss()
                        } label: {
                            Text(folder.label)
                                .foregroundStyle(AppTheme.Colors.textPrimary)
                        }
                    }
                }
            }
            .navigationTitle("Choisir un dossier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Editor View
//
// Layout: two horizontal pages (swipe left/right)
//   Page 0 — Results  (default, auto-run on open when no unfilled variables)
//   Page 1 — Editor   (full-height syntax-highlighted editor)

struct SQLEditorView: View {
    let fileURL: URL

    private let repository = TransactionRepository()
    @State private var sqlText: String = ""
    @State private var sections: [SQLQuerySection] = []
    @State private var isExecuting = false
    @State private var saveStatus: String? = nil
    @State private var detectedVarSpecs: [SQLVariableSpec] = []
    @State private var variables: [String: String] = [:]
    @State private var currentPage: Int = 0   // 0 = results, 1 = editor
    @State private var showAssistant: Bool = false
    /// Doc du schéma, accessible SANS quitter le fichier — avant cet ajout,
    /// seule `SQLFilesListView` (l'écran de liste) l'exposait, obligeant un
    /// aller-retour pour vérifier une colonne pendant qu'on écrit une requête.
    @State private var showSchema: Bool = false

    private var fileName: String { fileURL.deletingPathExtension().lastPathComponent }
    private var hasUnfilledVars: Bool { detectedVarSpecs.contains { (variables[$0.name] ?? "").isEmpty } }

    var body: some View {
        Group {
            #if os(macOS)
            // Le swipe entre pages n'existe pas au trackpad de la même façon,
            // et `.tabViewStyle(.page(...))` est shimmé vers le TabView natif
            // macOS (PlatformShims.swift) qui, sans `.tabItem`, dessine deux
            // boutons de bascule VIERGES (le "pilule transparente" observée) —
            // seule issue : le picker segmenté explicite ci-dessous.
            if currentPage == 0 { resultsPage } else { editorPage }
            #else
            TabView(selection: $currentPage) {
                resultsPage.tag(0)
                editorPage.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .principal) {
                Picker("Page", selection: $currentPage) {
                    Text("Résultats").tag(0)
                    Text("Éditeur").tag(1)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            #endif
            ToolbarItem(placement: .topBarLeading) {
                ToolbarPaywallGate(feature: .sqlConsole) {
                    PaneToggleButton(label: "Schéma", systemImage: "tablecells", isOn: $showSchema)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                PaneToggleButton(label: "Assistant IA", systemImage: "sparkles", isOn: $showAssistant)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { runAndGoToResults() } label: { Label("Exécuter", systemImage: "play.fill") }
                    .disabled(isExecuting || sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .adaptivePane(isPresented: $showAssistant) {
            SQLAssistantSheet { title, generatedSQL in
                // Section nommée par le titre confirmé dans l'alerte de l'assistant
                // (au lieu du générique "-- Assistant IA --" d'avant, qui rendait
                // toutes les requêtes insérées indiscernables dans la liste des
                // résultats dès qu'il y en avait plusieurs dans le même fichier).
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let block = cleanTitle.isEmpty ? generatedSQL : "-- \(cleanTitle) --\n" + generatedSQL
                if sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sqlText = block
                } else {
                    sqlText += "\n\n" + block
                }
                autoSave()
                refreshVariables(sqlText)
                currentPage = 1  // bascule vers l'éditeur pour montrer l'insertion
            }
        }
        .adaptivePane(isPresented: $showSchema) {
            DatabaseSchemaView()
                .paneChrome("Schéma de la base",
                            cancelLabel: "Fermer", onCancel: { showSchema = false })
        }
        .onAppear { loadFile() }
    }

    // ── Page 0: Results ──────────────────────────────────────────────────
    @ViewBuilder
    private var resultsPage: some View {
        VStack(spacing: 0) {
            if !detectedVarSpecs.isEmpty {
                VariableFormView(variables: $variables, specs: detectedVarSpecs)
            }

            if isExecuting {
                Spacer()
                ProgressView("Exécution…").frame(maxWidth: .infinity)
                Spacer()
            } else if sections.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 56)).foregroundStyle(AppTheme.Colors.textSecondary)
                    Text("Appuyez sur Exécuter pour lancer la requête")
                        .foregroundStyle(AppTheme.Colors.textSecondary).multilineTextAlignment(.center)
                    Button("Exécuter") { runAndStay() }
                        .buttonStyle(.borderedProminent)
                        .disabled(sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasUnfilledVars)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(sections) { SQLResultSectionView(section: $0) }
                    }
                    .padding()
                }
            }

            #if !os(macOS)
            swipeHint(label: "Glisser pour éditer", icon: "chevron.right")
            #endif
        }
    }

    // ── Page 1: Editor ───────────────────────────────────────────────────
    @ViewBuilder
    private var editorPage: some View {
        VStack(spacing: 0) {
            SyntaxHighlightingEditor(text: $sqlText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
                .onChange(of: sqlText) { _, new in
                    autoSave()
                    refreshVariables(new)
                }

            if let status = saveStatus {
                Text(status)
                    .font(.caption2).foregroundStyle(AppTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 12).padding(.bottom, 2)
            }

            #if !os(macOS)
            swipeHint(label: "Glisser pour les résultats", icon: "chevron.left")
            #endif
        }
    }

    #if !os(macOS)
    @ViewBuilder
    private func swipeHint(label: String, icon: String) -> some View {
        HStack(spacing: 4) {
            if icon == "chevron.left" { Image(systemName: icon).font(.caption2) }
            Text(label).font(.caption2)
            if icon == "chevron.right" { Image(systemName: icon).font(.caption2) }
        }
        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
        .padding(.vertical, 6)
    }
    #endif

    // MARK: - File I/O

    private func loadFile() {
        sqlText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        refreshVariables(sqlText)
        // Auto-run if file has content and no variables to fill
        let trimmed = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && detectedVarSpecs.isEmpty {
            executeSQL()          // run immediately, stay on results page
        } else if !detectedVarSpecs.isEmpty {
            currentPage = 1       // go to editor so user can fill in variables
        }
    }

    private func autoSave() {
        try? sqlText.write(to: fileURL, atomically: true, encoding: .utf8)
        saveStatus = "Sauvegardé"
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { saveStatus = nil }
        }
    }

    // MARK: - Variables

    private func refreshVariables(_ sql: String) {
        let found = SQLVariableParsing.extract(from: sql)
        var updated: [String: String] = [:]
        for spec in found { updated[spec.name] = variables[spec.name] ?? spec.defaultValue ?? "" }
        detectedVarSpecs = found
        variables = updated
    }

    // MARK: - Execution

    /// Run and switch to the results page (called from toolbar / editor page).
    private func runAndGoToResults() {
        executeSQL()
        currentPage = 0
    }

    /// Run without changing page (called from the results page "Exécuter" button).
    private func runAndStay() {
        executeSQL()
    }

    private func executeSQL() {
        isExecuting = true
        sections = []
        let queries = parseNamedQueries(sqlText)
        let repo = repository
        let vars = variables
        Task.detached(priority: .userInitiated) { [vars] in
            var results: [SQLQuerySection] = []
            for q in queries {
                let sql = vars.isEmpty ? q.sql : SQLVariableParsing.substitute(q.sql, values: vars)
                let outcome = repo.executeSQL(sql)
                switch outcome {
                case .success(let res): results.append(SQLQuerySection(label: q.name, sql: sql, result: res, error: nil))
                case .failure(let err): results.append(SQLQuerySection(label: q.name, sql: sql, result: nil, error: err.message))
                }
            }
            await MainActor.run { sections = results; isExecuting = false }
        }
    }

    // MARK: - Query Parsing
    //
    // Format supported:
    //   -- Section name --      ← named section header (must start & end with --)
    //   SELECT ...;
    //
    // Falls back to semicolon-split if no headers are found.

    private func parseNamedQueries(_ text: String) -> [(name: String, sql: String)] {
        guard let headerRe = try? NSRegularExpression(pattern: #"^--\s*(.+?)\s*--\s*$"#, options: .anchorsMatchLines) else {
            return fallbackSplit(text)
        }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = headerRe.matches(in: text, range: full)
        guard !matches.isEmpty else { return fallbackSplit(text) }

        var queries: [(name: String, sql: String)] = []
        for (i, match) in matches.enumerated() {
            let name = match.range(at: 1).location != NSNotFound
                ? ns.substring(with: match.range(at: 1))
                : "Requête \(i + 1)"
            let sqlStart = match.range.upperBound
            let sqlEnd = i + 1 < matches.count ? matches[i + 1].range.lowerBound : ns.length
            guard sqlStart < sqlEnd else { continue }
            let block = ns.substring(with: NSRange(location: sqlStart, length: sqlEnd - sqlStart))
            let stmts = splitStatements(block, stripHeaders: false)
            for (j, stmt) in stmts.enumerated() {
                queries.append((name: stmts.count > 1 ? "\(name) (\(j+1))" : name, sql: stmt))
            }
        }
        return queries.filter { !$0.sql.isEmpty }
    }

    private func fallbackSplit(_ text: String) -> [(name: String, sql: String)] {
        let stmts = splitStatements(text, stripHeaders: true)
        return stmts.enumerated().map { i, s in
            (name: stmts.count > 1 ? "Requête \(i + 1)" : "Résultat", sql: s)
        }
    }

    /// Splits SQL block by semicolons, optionally stripping `-- comment` suffixes.
    private func splitStatements(_ text: String, stripHeaders: Bool) -> [String] {
        let headerRe = try? NSRegularExpression(pattern: #"^--\s*.+?\s*--\s*$"#, options: .anchorsMatchLines)
        let cleaned = text.components(separatedBy: .newlines).map { line -> String in
            // Remove inline comment suffix but keep standalone comment lines (for context)
            if let hr = headerRe, hr.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                return "" // strip section header lines from SQL content
            }
            if stripHeaders, let r = line.range(of: "--") {
                return String(line[..<r.lowerBound])
            }
            return line
        }.joined(separator: "\n")

        return cleaned
            .components(separatedBy: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Result Section View

struct SQLResultSectionView: View {
    let section: SQLQuerySection
    @State private var isExpanded: Bool = true
    @State private var viewMode: SQLResultViewMode = .table

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header tappable pour collapse/expand
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(section.label)
                        .font(.headline)
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Spacer()
                    if let result = section.result {
                        Text("\(result.rows.count) ligne\(result.rows.count > 1 ? "s" : "")")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } else if section.error != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.danger)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(section.sql.prefix(120) + (section.sql.count > 120 ? "…" : ""))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .transition(.opacity)

                if let error = section.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.danger)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.Colors.danger.opacity(0.1))
                        .cornerRadius(6)
                } else if let result = section.result {
                    if result.columns.isEmpty {
                        Label("Requête exécutée avec succès", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.success)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.Colors.success.opacity(0.1))
                            .cornerRadius(6)
                    } else if let plan = SQLResultChartPlan.detect(from: result) {
                        HStack {
                            Spacer()
                            Picker("Affichage", selection: $viewMode) {
                                Image(systemName: "tablecells").tag(SQLResultViewMode.table)
                                Image(systemName: "chart.bar.fill").tag(SQLResultViewMode.chart)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 90)
                        }
                        if viewMode == .chart {
                            SQLResultChart(result: result, plan: plan)
                        } else {
                            SQLResultTable(columns: result.columns, rows: result.rows)
                        }
                    } else {
                        SQLResultTable(columns: result.columns, rows: result.rows)
                    }
                }
            }
        }
        .padding(12)
        .background(AppTheme.Colors.surface)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Aligned table

/// Tableau dont les colonnes restent alignées entre header et lignes, peu importe
/// la longueur du contenu. On calcule la largeur de chaque colonne (max sur
/// header + cellules) avec un peu de padding, puis on l'applique uniformément.
/// Scroll horizontal si la somme dépasse la largeur disponible.
private struct SQLResultTable: View {
    let columns: [String]
    let rows: [[String]]

    /// Largeur calculée par colonne. Index = colonne.
    private var columnWidths: [CGFloat] {
        columns.enumerated().map { (idx, header) in
            // Compte les caractères du header et de chaque cellule pour estimer
            // la largeur nécessaire en monospace ~7pt/char. Cap min/max pour rester lisible.
            var maxChars = header.count
            for row in rows {
                if idx < row.count {
                    maxChars = max(maxChars, row[idx].count)
                }
            }
            // Approx : ~7pt per char en .caption monospaced + 16pt padding
            let computed = CGFloat(maxChars) * 7.2 + 16
            return min(max(computed, 60), 240) // min 60pt, max 240pt par colonne
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { idx, col in
                        Text(col)
                            .font(.caption.bold())
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: columnWidths[idx], alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(AppTheme.Colors.surfaceSecondary)
                    }
                }
                Divider()
                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { colIdx, _ in
                            let value = colIdx < row.count ? row[colIdx] : ""
                            Text(value.isEmpty ? "NULL" : value)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                                .frame(width: columnWidths[colIdx], alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .foregroundStyle(value.isEmpty
                                    ? AnyShapeStyle(AppTheme.Colors.textSecondary.opacity(0.6))
                                    : AnyShapeStyle(AppTheme.Colors.textPrimary))
                        }
                    }
                    .background(rowIdx % 2 == 0
                                ? AppTheme.Colors.surface
                                : AppTheme.Colors.surfaceSecondary.opacity(0.4))
                }
            }
        }
        .background(AppTheme.Colors.surfaceSecondary.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Result Chart

/// Rendu graphique d'un résultat "graphable" (cf. `SQLResultChartPlan`).
/// Barres pour une répartition catégorielle, ligne pour une série temporelle.
private struct SQLResultChart: View {
    let result: SQLQueryResult
    let plan: SQLResultChartPlan

    /// Palette stable, dérivée de l'accent — même esprit que
    /// `AllocationDonutChart` (Investissements), en plus court : 4 séries max.
    private static let palette: [Color] = [
        AppTheme.Colors.accent,
        AppTheme.Colors.accentSecondary,
        AppTheme.Colors.success,
        AppTheme.Colors.warning,
    ]

    private struct Point: Identifiable {
        let id = UUID()
        let label: String
        let series: String
        let value: Double
    }

    private var points: [Point] {
        var out: [Point] = []
        for row in result.rows {
            guard plan.labelIndex < row.count else { continue }
            let label = row[plan.labelIndex]
            for seriesIndex in plan.seriesIndices {
                guard seriesIndex < row.count, let value = Double(row[seriesIndex]) else { continue }
                out.append(Point(label: label, series: result.columns[seriesIndex], value: value))
            }
        }
        return out
    }

    private var seriesNames: [String] { plan.seriesIndices.map { result.columns[$0] } }

    /// Labels dans l'ordre où SQL les a renvoyés — souvent un ORDER BY
    /// intentionnel (ex. un "Top 10" trié par montant). Sans domaine explicite,
    /// Swift Charts trie un axe String par ordre alphabétique et détruirait ce tri.
    private var orderedLabels: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for row in result.rows where plan.labelIndex < row.count {
            let label = row[plan.labelIndex]
            if seen.insert(label).inserted { out.append(label) }
        }
        return out
    }

    var body: some View {
        Chart {
            ForEach(points) { point in
                if plan.isTimeSeries {
                    LineMark(x: .value("X", point.label), y: .value(point.series, point.value))
                        .foregroundStyle(by: .value("Série", point.series))
                        .symbol(by: .value("Série", point.series))
                        .interpolationMethod(.monotone)
                } else {
                    BarMark(x: .value("X", point.label), y: .value(point.series, point.value))
                        .foregroundStyle(by: .value("Série", point.series))
                        .position(by: .value("Série", point.series))
                }
            }
        }
        .chartForegroundStyleScale(domain: seriesNames, range: seriesNames.indices.map { Self.palette[$0 % Self.palette.count] })
        .chartLegend(seriesNames.count > 1 ? .visible : .hidden)
        .chartXScale(domain: orderedLabels)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(6, orderedLabels.count))) { _ in
                AxisValueLabel()
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
                    .font(.system(size: 9))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel()
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.55))
                    .font(.system(size: 9))
            }
        }
        .frame(height: 200)
        .padding(.top, 4)
        .padding(.trailing, 4)
    }
}
