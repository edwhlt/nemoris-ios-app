import SwiftUI
import Charts
#if canImport(UIKit)
import UIKit
#endif
import TipKit

// MARK: - Syntax Highlighting Editor

#if os(macOS)
/// macOS version: an NSTextView in its scroll view. Same shared highlighting
/// as the iOS version (UIFont/UIColor → NSFont/NSColor via PlatformShims).
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

/// SQL highlighting shared between iOS/macOS (UIFont/UIColor typealiased on Mac).
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
// Token syntax: {{name}} | {{name:type}} | {{name:type=default}} | {{name=default}}.
// A bare {{name}} (no ":") is still treated as .text — .sql files already saved
// with their own quotes around {{x}} keep working identically.

/// Declared type for a variable. `.text` is the default if omitted.
enum SQLVariableType: String {
    case text     // a free-form string — substituted inside SQL quotes (escaped)
    case number   // a number — substituted as-is, no quotes
    case year     // a 4-digit year — numeric keyboard; substituted INSIDE QUOTES
                  // because it's compared against strftime('%Y', ...), which returns text, never an integer
    case date     // a date — native DatePicker; substituted as 'yyyy-MM-dd'
}

struct SQLVariableSpec: Identifiable, Hashable {
    let name: String
    let type: SQLVariableType
    let defaultValue: String?
    var id: String { name }
}

/// Grammar for `{{...}}` tokens, centralized so that detection
/// (the form), pre-filling, and substitution (execution) can never
/// diverge from one another.
enum SQLVariableParsing {
    private static let tokenRegex = try? NSRegularExpression(pattern: "\\{\\{([^}]+)\\}\\}")

    /// Parses a single token's content (the text already extracted from `{{ }}`).
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

    /// Variables detected in an SQL text, deduplicated by name (keeps the
    /// first occurrence if the same name is annotated differently elsewhere —
    /// an edge case, but the form field must stay unique per name).
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

    /// Encodes a raw value typed by the user into an SQL literal according to the
    /// declared type. Only `.number` stays unquoted — everything else (including
    /// `.year`) is quoted and escaped to be a valid SQL literal without the
    /// user having to type their own quotes in the query body.
    static func sqlLiteral(_ rawValue: String, type: SQLVariableType) -> String {
        switch type {
        case .number:
            return rawValue.trimmingCharacters(in: .whitespaces)
        case .text, .year, .date:
            let escaped = rawValue.replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)'"
        }
    }

    /// Substitutes each `{{...}}` with its SQL literal. Re-parses EACH
    /// occurrence independently (rather than a global name→text replacement)
    /// to stay correct even if the same name appears with different
    /// annotations in several places in the file.
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
        // Under App Sandbox, a bookmark created without .withSecurityScope resolves
        // to a "plain" URL — startAccessingSecurityScopedResource() fails on
        // the next launch and access to the folder is silently lost.
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

    /// An entry in the SQL browser: either a folder or a .sql file.
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

    /// Lists a directory's entries. `nil` = root (`sqlDirectory()`).
    /// Folders first (alpha-sorted), then .sql files (alpha-sorted).
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

    /// A node in the browser's tree. Loaded EAGERLY and recursively — the
    /// user's SQL directory is small (a few dozen entries), so the cost of a
    /// full scan is negligible next to the simplicity it buys.
    struct TreeNode: Identifiable {
        let entry: Entry
        let depth: Int
        var children: [TreeNode]
        var id: String { entry.id }   // = url.path: a stable key for the expansion Set
    }

    /// Builds the full tree from the root (or `root`).
    /// Relies on `listEntries(in:)` at every level — the "folders
    /// first, alpha sort" order is therefore preserved at every depth.
    static func buildTree(rootedAt root: URL? = nil, depth: Int = 0) -> [TreeNode] {
        listEntries(in: root ?? sqlDirectory()).map { entry in
            TreeNode(
                entry: entry,
                depth: depth,
                children: entry.isFolder ? buildTree(rootedAt: entry.url, depth: depth + 1) : []
            )
        }
    }

    /// Every folder recursively, root included. Used by the "Move to…" picker.
    /// Returns pairs (a displayable, indented label, and a URL).
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

    /// Creates an empty .sql file in `directory` (or the root if nil).
    /// Returns the created file's URL, or nil on failure / a name collision.
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

    /// Creates a subfolder in `directory` (or the root if nil).
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

    /// Renames a file or a folder. For a .sql file, the extension is
    /// re-added automatically if missing from the new name.
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

    /// Moves `url` into the `destinationFolder` folder (keeping its name).
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

    /// Deletes a file or a folder (recursively).
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

/// Detects whether a result has a "chartable" shape: EXACTLY one label
/// column + 1 to 4 numeric columns. Deliberately conservative — no
/// attempt to visualize everything, just the most common case of an
/// aggregate query (GROUP BY + SUM/COUNT/AVG), which covers most of
/// `DatabaseSchemaView`'s recipes (total per category, evolution per month,
/// breakdown per metadata field…). A result that doesn't match stays a
/// table, with no error message — it's a bonus, not a feature that
/// can "fail".
struct SQLResultChartPlan {
    let labelIndex: Int
    let seriesIndices: [Int]
    /// A line (LineMark) if the label looks like a date/month ("2026-01",
    /// "2026-01-15") — otherwise bars (BarMark) for a categorical breakdown.
    let isTimeSeries: Bool

    static func detect(from result: SQLQueryResult) -> SQLResultChartPlan? {
        // Row cap: beyond that, a bar chart becomes unreadable and a query
        // of that size is almost never the "1 label + N numerics" shape
        // targeted here (it would already have failed the column rule in practice).
        guard !result.rows.isEmpty, result.columns.count >= 2, result.rows.count <= 60 else { return nil }

        var labelIndices: [Int] = []
        var numericIndices: [Int] = []
        for (idx, name) in result.columns.enumerated() {
            // Identifier columns (id, foo_id) are numeric but carry no
            // magnitude worth representing — they're keys, not
            // quantities. Ignoring them avoids an absurd bar chart of "id".
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
    /// The FULL tree (eager) — folders are no longer pushed views
    /// but foldable/unfoldable nodes in the same list.
    @State private var tree: [SQLConsoleHelper.TreeNode] = []
    /// Paths (= `TreeNode.id`) of the folders currently expanded. `@State`
    /// is enough: re-expanding after navigating away and back costs one tap,
    /// and persisting expansion in AppStorage would be noise for a small
    /// user directory.
    @State private var expandedPaths: Set<String> = []
    /// Target folder for the creation alerts. `nil` = root (toolbar "+");
    /// set by a folder row's "New … here" context menu.
    @State private var creationDir: URL?
    @State private var showCreateFileAlert = false
    @State private var showCreateFolderAlert = false
    @State private var newName = ""
    @State private var selectedFile: URL?
    @State private var showEditor = false
    /// True ONLY when `selectedFile` was opened via the "Run" action
    /// (iOS swipe / macOS right-click) — in every other case (tapping the row,
    /// creating a file), opening a file shows the editor WITHOUT running it.
    @State private var autoRunOnOpen = false
    /// Schema docs as a pane (see `.adaptivePane` in the body) rather than a push.
    @State private var showSchema = false
    @State private var renamingEntry: SQLConsoleHelper.Entry?
    @State private var movingEntry: SQLConsoleHelper.Entry?
    @State private var renameInput = ""
    @State private var errorMessage: String?
    private let consoleTip = SQLConsoleTip()

    /// Rendered by `.localizedNavigationTitle`, which resolves the KEY against the
    /// app's chosen language bundle and refreshes on a language change (see
    /// `AppLocalization`). We therefore return the source key as-is, never an
    /// already-resolved string.
    ///
    /// ⚠️ A user's file name isn't a translation key — but routing it through
    /// the same path is SAFE: a key missing from the table falls back to the
    /// source text, i.e. to the file name itself (verified). This avoids having
    /// two competing modifiers on the same view.
    private var navTitle: String {
        #if os(macOS)
        if let file = selectedFile { return file.deletingPathExtension().lastPathComponent }
        return "Console SQL"
        #else
        "Console SQL"
        #endif
    }

    /// Prefix flattening of the tree: we only descend into `children` if
    /// the folder is expanded. Stale paths in `expandedPaths` (a folder that
    /// was deleted/moved) are simply ignored by the traversal.
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
        // ⚠️ On macOS, the file is NOT opened by a push (even via
        // `.navigationDestination(isPresented:)`, the "safe" form). Observed
        // on device: as soon as a view is pushed in THIS
        // NavigationStack, any `.adaptivePane` opened from it (the desktop
        // side pane of `MainTabView`, see `AdaptivePane.swift`) gets painted
        // UNDER the pushed content instead of beside it — reproduces 100% of
        // the time by opening the AI assistant from the editor; becomes visible
        // again once popping back to the root. Root cause is on the AppKit/
        // NavigationStack side (macOS 27 beta). Fix: zero push, conditional
        // content swap via @State (`selectedFile`) so the module's
        // NavigationStack ALWAYS stays at its root. Folders themselves no
        // longer navigate AT ALL since the tree redesign: they fold/unfold
        // in place.
        Group {
            if let file = selectedFile {
                SQLEditorView(fileURL: file, autoRunOnOpen: autoRunOnOpen)
            } else {
                fileListBody
            }
        }
        .localizedNavigationTitle(navTitle)
        .toolbar {
            if selectedFile != nil {
                ToolbarItem(placement: .navigation) {
                    Button {
                        selectedFile = nil
                        autoRunOnOpen = false
                    } label: {
                        Label("Retour", systemImage: "chevron.left")
                    }
                }
            }
        }
        // The app's background is set explicitly — without it, the macOS
        // NavigationSplitView's "content" column shows its vibrant material by
        // default instead of the neutral AppTheme background. Covers both
        // branches (the file list AND the editor, swapped via @State).
        .background(AppTheme.Colors.background.ignoresSafeArea())
        #else
        fileListBody
            .localizedNavigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showEditor) {
                if let file = selectedFile { SQLEditorView(fileURL: file, autoRunOnOpen: autoRunOnOpen) }
            }
        #endif
    }

    // MARK: - File list (shared content, never itself pushed on macOS)

    @ViewBuilder
    private var fileListBody: some View {
        // The empty state is rendered OUTSIDE the `List`: inside a row it inherits
        // the row's width and ends up pinned to the left on a wide window
        // (instead of being centered in the view). As an overlay it takes up the
        // whole available surface and centers naturally.
        List {
            TipView(consoleTip, arrowEdge: .none)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            ForEach(visibleRows) { node in
                entryRow(node)
                    .macGroupedRow(first: node.id == visibleRows.first?.id, last: node.id == visibleRows.last?.id)
            }
        }
        #if os(macOS)
        // Same policy as TricountListView/TransactionsView: .plain =
        // a neutral base for the custom cards drawn by macGroupedRow.
        .listStyle(.plain)
        // Detaches the 1st card from the native macOS separator (toolbar ↔
        // scrolled content) — same fix as TransactionsView.
        .macGroupedListTopGap()
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
        // Schema docs: REFERENCE content (a sheet you consult next to
        // your query) → a pane, not a push. A push from a module stacks
        // a view onto its NavigationStack, which raises the module-switch
        // issues already seen on Tricount/Investments (and, since,
        // the pane-masking issue documented in `body` above).
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

    /// Tree row — MANUAL indentation + an animated chevron, NO
    /// `DisclosureGroup`: rows stay plain `Button`s, which guarantees
    /// compatibility with `rowActions` (iOS swipe / macOS right-click) by
    /// construction and avoids composing our own indentation with
    /// `DisclosureGroup`'s automatic one.
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
                RowAction("Supprimer", systemImage: "trash", role: .destructive, iconOnly: true) { handleDelete(entry) },
                RowAction("Déplacer", systemImage: "folder", tint: AppTheme.Colors.accentSecondary, iconOnly: true) { movingEntry = entry },
                RowAction("Renommer", systemImage: "pencil", tint: AppTheme.Colors.accent, iconOnly: true) {
                    renameInput = entry.displayName
                    renamingEntry = entry
                }
            ], trailingFullSwipe: false)
        case .file(let fileURL):
            Button {
                openFile(fileURL, autoRun: false)
            } label: {
                HStack(spacing: 6) {
                    // Reserve the folder chevron's width: files and
                    // folders at the same depth stay aligned.
                    Color.clear.frame(width: 14, height: 1)
                    Label(entry.displayName, systemImage: "doc.text.fill")
                        .foregroundStyle(AppTheme.Colors.textPrimary)
                    Spacer()
                }
                .padding(.leading, CGFloat(node.depth) * 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rowActions(
                leading: [
                    // The only way to run WITHOUT seeing the editor first: swipe
                    // (iOS) or right-click (macOS, `rowActions` renders `leading` in
                    // the context menu). A normal tap on the row always opens
                    // the editor WITHOUT running (see `openFile`).
                    RowAction("Exécuter", systemImage: "play.fill", tint: AppTheme.Colors.accent, iconOnly: true) {
                        openFile(fileURL, autoRun: true)
                    }
                ],
                trailing: [
                    RowAction("Supprimer", systemImage: "trash", role: .destructive, iconOnly: true) { handleDelete(entry) },
                    RowAction("Déplacer", systemImage: "folder", tint: AppTheme.Colors.accentSecondary, iconOnly: true) { movingEntry = entry },
                    RowAction("Renommer", systemImage: "pencil", tint: AppTheme.Colors.accent, iconOnly: true) {
                        renameInput = entry.displayName
                        renamingEntry = entry
                    }
                ],
                trailingFullSwipe: false
            )
        }
    }

    // MARK: - Actions

    /// SINGLE point where a file gets opened — `autoRun` distinguishes a normal
    /// tap (editor only) from the "Run" action (iOS swipe / macOS right-click).
    private func openFile(_ url: URL, autoRun: Bool) {
        selectedFile = url
        autoRunOnOpen = autoRun
        #if !os(macOS)
        showEditor = true
        #endif
    }

    private func reload() {
        tree = SQLConsoleHelper.buildTree()
    }

    /// Makes what was just created/moved visible: expands the target folder.
    /// Its ancestors are necessarily already expanded when the target comes
    /// from a context menu (the row was visible); after a "Move to…", the
    /// whole chain of ancestors under the SQL root is expanded.
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
        openFile(url, autoRun: false)
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
    let title: LocalizedStringKey
    /// If non-nil, this folder (and its subfolders) is excluded to avoid
    /// moving a folder into itself.
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
                        .macGroupedRow(first: folder.url == folders.first?.url, last: folder.url == folders.last?.url)
                    }
                }
            }
            #if os(macOS)
            // Same policy as TricountListView/TransactionsView: .plain =
            // a neutral base for the custom cards drawn by macGroupedRow.
            .listStyle(.plain)
            // `List` paints ITS OWN system background on macOS ON TOP OF
            // the host pane's — without this modifier, the user's
            // desktop shows through.
            .scrollContentBackground(.hidden)
            #endif
            // `.paneChrome` draws its own bars on macOS-sheet — the
            // earlier attempt (`.toolbarBackground(for: .windowToolbar)`)
            // compiled but had NO visual effect at all, confirmed by a live
            // screenshot. See the `macSheetChrome` comment in AdaptivePane.swift.
            .paneChrome("Choisir un dossier", cancelLabel: "Annuler", onCancel: { dismiss() })
    }
}

// MARK: - Editor View
//
// Layout: two horizontal pages (swipe left/right)
//   Page 0 — Results  (only shown first if opened via the explicit « Exécuter »
//                       action — swipe iOS / clic droit macOS — with no unfilled
//                       variables; auto-runs in that case only)
//   Page 1 — Editor   (full-height syntax-highlighted editor — the DEFAULT page
//                       on open, no execution happens just from opening a file)

struct SQLEditorView: View {
    let fileURL: URL
    /// True ONLY when this file was opened via the "Run" action
    /// (iOS swipe / macOS right-click on `SQLFilesListView`) — in that case, and
    /// only in that case, the file runs automatically on open and lands
    /// on the Results page. By default (a normal tap, this view's own
    /// "Run" toolbar button): opening shows the editor WITHOUT
    /// running it, running staying an explicit user gesture.
    var autoRunOnOpen: Bool = false

    private let repository = TransactionRepository()
    @State private var sqlText: String = ""
    @State private var sections: [SQLQuerySection] = []
    @State private var isExecuting = false
    @State private var saveStatus: String? = nil
    @State private var detectedVarSpecs: [SQLVariableSpec] = []
    @State private var variables: [String: String] = [:]
    @State private var currentPage: Int = 0   // 0 = results, 1 = editor
    @State private var showAssistant: Bool = false
    /// Schema docs, reachable WITHOUT leaving the file — before this addition,
    /// only `SQLFilesListView` (the list screen) exposed it, forcing a
    /// round trip to check a column while writing a query.
    @State private var showSchema: Bool = false
    /// The content read from disk (`loadFile`) is no longer synchronous on the
    /// main thread — until it comes back, a light spinner is shown
    /// instead of freezing the app for the duration of the read (opening
    /// a file "sometimes took a while" with the UI frozen in the meantime).
    @State private var isLoadingFile = true

    /// Blocked instructions (a SCHEMA change) — never executed,
    /// see `SQLStatementGuard`. Non-nil ⇒ the blocking alert is shown.
    @State private var blockedStatements: [SQLStatementClassification]? = nil
    /// A batch awaiting confirmation (a DATA change) — captured as-is
    /// (variables already substituted) to be replayed after confirmation
    /// with no reclassification or resubstitution.
    @State private var pendingConfirmation: (queries: [(name: String, sql: String)], summary: [SQLStatementClassification])? = nil
    /// Failure of the backup offered before a data change —
    /// the user then chooses to run anyway or to cancel.
    @State private var backupFailure: (queries: [(name: String, sql: String)], message: String)? = nil

    private var fileName: String { fileURL.deletingPathExtension().lastPathComponent }
    private var hasUnfilledVars: Bool { detectedVarSpecs.contains { (variables[$0.name] ?? "").isEmpty } }

    var body: some View {
        Group {
            if isLoadingFile {
                loadingPlaceholder
            } else {
                #if os(macOS)
                // Swiping between pages doesn't work the same way on a trackpad,
                // and `.tabViewStyle(.page(...))` is shimmed to the native macOS
                // TabView (PlatformShims.swift), which, with no `.tabItem`, draws two
                // BLANK toggle buttons (the "transparent pill" observed) —
                // the only fix: the explicit segmented picker below.
                if currentPage == 0 { resultsPage } else { editorPage }
                #else
                TabView(selection: $currentPage) {
                    resultsPage.tag(0)
                    editorPage.tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
            }
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
                // Section named after the title confirmed in the assistant's alert
                // (instead of the earlier generic "-- AI Assistant --", which made
                // every inserted query indistinguishable in the results
                // list as soon as there were several in the same file).
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let block = cleanTitle.isEmpty ? generatedSQL : "-- \(cleanTitle) --\n" + generatedSQL
                if sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sqlText = block
                } else {
                    sqlText += "\n\n" + block
                }
                autoSave()
                refreshVariables(sqlText)
                currentPage = 1  // switches to the editor to show the insertion
            }
        }
        .adaptivePane(isPresented: $showSchema) {
            DatabaseSchemaView()
                .paneChrome("Schéma de la base",
                            cancelLabel: "Fermer", onCancel: { showSchema = false })
        }
        .alert(
            "Modification de schéma bloquée",
            isPresented: Binding(get: { blockedStatements != nil }, set: { if !$0 { blockedStatements = nil } })
        ) {
            Button("Compris", role: .cancel) { blockedStatements = nil }
        } message: {
            Text(SQLGuardMessages.blocked(blockedStatements ?? []))
        }
        .confirmationDialog(
            "Cette requête modifie des données",
            isPresented: Binding(get: { pendingConfirmation != nil }, set: { if !$0 { pendingConfirmation = nil } }),
            titleVisibility: .visible
        ) {
            Button("Sauvegarder puis exécuter") {
                guard let pending = pendingConfirmation else { return }
                pendingConfirmation = nil
                backupThenRun(pending.queries)
            }
            Button("Exécuter sans sauvegarder", role: .destructive) {
                guard let pending = pendingConfirmation else { return }
                pendingConfirmation = nil
                performExecution(pending.queries)
            }
            Button("Annuler", role: .cancel) { pendingConfirmation = nil }
        } message: {
            Text(SQLGuardMessages.confirmation(pendingConfirmation?.summary ?? []))
        }
        .alert(
            "La sauvegarde a échoué",
            isPresented: Binding(get: { backupFailure != nil }, set: { if !$0 { backupFailure = nil } })
        ) {
            Button("Exécuter quand même", role: .destructive) {
                guard let failure = backupFailure else { return }
                backupFailure = nil
                performExecution(failure.queries)
            }
            Button("Annuler", role: .cancel) { backupFailure = nil }
        } message: {
            Text((backupFailure?.message ?? "") + "\n\nExécuter quand même la requête sans sauvegarde préalable ?")
        }
        .task { await loadFile() }
    }

    @ViewBuilder
    private var loadingPlaceholder: some View {
        VStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    private func swipeHint(label: LocalizedStringKey, icon: String) -> some View {
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

    private func loadFile() async {
        // Read off the main thread: on a large file or a slow disk,
        // a synchronous `String(contentsOf:)` on the main actor froze
        // the app for the whole duration of the read.
        let url = fileURL
        let text = await Task.detached(priority: .userInitiated) {
            (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }.value
        sqlText = text
        isLoadingFile = false
        refreshVariables(sqlText)
        // Opening a file NEVER runs it by default — only the explicit
        // "Run" action (iOS swipe / macOS right-click on the file list)
        // triggers auto-run here, and only if every
        // variable is already filled in (otherwise the user must fill them
        // in the editor, as before).
        let trimmed = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if autoRunOnOpen && !trimmed.isEmpty && detectedVarSpecs.isEmpty {
            executeSQL()          // run immediately, stay on results page
            currentPage = 0
        } else {
            currentPage = 1       // always the editor by default
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

    /// Run without changing page (called from the results page "Run" button).
    private func runAndStay() {
        executeSQL()
    }

    private func executeSQL() {
        let vars = variables
        let queries = parseNamedQueries(sqlText).map { q in
            (name: q.name, sql: vars.isEmpty ? q.sql : SQLVariableParsing.substitute(q.sql, values: vars))
        }
        runGuarded(queries)
    }

    /// Classifies every instruction in the batch (variables already substituted) and,
    /// based on the most severe verdict: blocks (schema), asks for confirmation
    /// (data), or runs directly (read-only / maintenance).
    private func runGuarded(_ queries: [(name: String, sql: String)]) {
        let assessment = SQLStatementGuard.assess(queries.map(\.sql))
        if assessment.isBlocked {
            blockedStatements = assessment.blockedStatements
            return
        }
        if assessment.needsConfirmation {
            pendingConfirmation = (queries: queries, summary: assessment.statementsNeedingConfirmation)
            return
        }
        performExecution(queries)
    }

    /// Creates a manual backup before running a batch the user has already
    /// confirmed — the same mechanism as "Back up now" in
    /// Settings › Backup (`BackupService.createSnapshot`), synchronous.
    private func backupThenRun(_ queries: [(name: String, sql: String)]) {
        do {
            try BackupService.shared.createSnapshot()
            performExecution(queries)
        } catch {
            backupFailure = (queries: queries, message: "Impossible de créer la sauvegarde : \(error.localizedDescription)")
        }
    }

    private func performExecution(_ queries: [(name: String, sql: String)]) {
        isExecuting = true
        sections = []
        let repo = repository
        Task.detached(priority: .userInitiated) {
            var results: [SQLQuerySection] = []
            for q in queries {
                let outcome = repo.executeSQL(q.sql)
                switch outcome {
                case .success(let res): results.append(SQLQuerySection(label: q.name, sql: q.sql, result: res, error: nil))
                case .failure(let err): results.append(SQLQuerySection(label: q.name, sql: q.sql, result: nil, error: err.message))
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
            // Tappable header to collapse/expand
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

/// A table whose columns stay aligned between the header and the rows, no matter
/// the content's length. Each column's width is computed (max of the
/// header + cells) with a bit of padding, then applied uniformly.
/// Scrolls horizontally if the sum exceeds the available width.
private struct SQLResultTable: View {
    let columns: [String]
    let rows: [[String]]

    /// Width computed per column. Index = column.
    private var columnWidths: [CGFloat] {
        columns.enumerated().map { (idx, header) in
            // Counts the characters of the header and each cell to estimate
            // the needed width at monospace ~7pt/char. Min/max cap to stay readable.
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

/// Chart rendering for a "chartable" result (see `SQLResultChartPlan`).
/// Bars for a categorical breakdown, a line for a time series.
private struct SQLResultChart: View {
    let result: SQLQueryResult
    let plan: SQLResultChartPlan

    /// A stable palette, derived from the accent color — same spirit as
    /// `AllocationDonutChart` (Investments), shorter: 4 series max.
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

    /// Labels in the order SQL returned them — often an intentional ORDER BY
    /// (e.g. a "Top 10" sorted by amount). With no explicit domain,
    /// Swift Charts sorts a String axis alphabetically and would destroy that order.
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
