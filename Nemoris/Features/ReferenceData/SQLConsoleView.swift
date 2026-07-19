import SwiftUI
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

private struct VariableFormView: View {
    @Binding var variables: [String: String]
    let names: [String]

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
                    ForEach(names, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("{{\(name)}}")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(AppTheme.Colors.warning)
                            TextField("valeur", text: Binding(
                                get: { variables[name] ?? "" },
                                set: { variables[name] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 100, maxWidth: 200)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(.caption, design: .monospaced))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .background(Color(.tertiarySystemBackground))
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
        let data = try pickerURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: folderBookmarkKey)
    }

    static func unlinkFolder() {
        UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
    }

    private static func resolveStoredFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if isStale, let newData = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(newData, forKey: folderBookmarkKey)
        }
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

// MARK: - Files List View

struct SQLFilesListView: View {
    /// `nil` = racine (`SQLConsoleHelper.sqlDirectory()`).
    /// Sinon = sous-dossier à afficher.
    let directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory
    }

    @Environment(PurchaseManager.self) private var store
    @State private var entries: [SQLConsoleHelper.Entry] = []
    @State private var showCreateFileAlert = false
    @State private var showCreateFolderAlert = false
    @State private var newName = ""
    @State private var selectedFile: URL?
    @State private var showEditor = false
    @State private var renamingEntry: SQLConsoleHelper.Entry?
    @State private var movingEntry: SQLConsoleHelper.Entry?
    @State private var renameInput = ""
    @State private var errorMessage: String?
    private let consoleTip = SQLConsoleTip()

    private var currentDir: URL {
        directory ?? SQLConsoleHelper.sqlDirectory()
    }

    private var navTitle: String {
        directory?.lastPathComponent ?? "Console SQL"
    }

    var body: some View {
        List {
            if directory == nil {
                TipView(consoleTip, arrowEdge: .none)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if entries.isEmpty {
                ContentUnavailableView(
                    "Aucun fichier SQL",
                    systemImage: "doc.text",
                    description: Text("Appuyez sur + pour créer un fichier ou un dossier.")
                )
            } else {
                ForEach(entries) { entry in
                    entryRow(entry)
                }
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .paywallOverlay(for: .sqlConsole)
        .toolbar {
            if directory == nil {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        DatabaseSchemaView()
                    } label: {
                        Label("Schéma", systemImage: "tablecells")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newName = ""
                        showCreateFileAlert = true
                    } label: {
                        Label("Nouveau fichier .sql", systemImage: "doc.badge.plus")
                    }
                    Button {
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
        .navigationDestination(isPresented: $showEditor) {
            if let file = selectedFile { SQLEditorView(fileURL: file) }
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
        .sheet(item: $movingEntry) { entry in
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

    @ViewBuilder
    private func entryRow(_ entry: SQLConsoleHelper.Entry) -> some View {
        switch entry {
        case .folder(let folderURL):
            NavigationLink {
                SQLFilesListView(directory: folderURL)
            } label: {
                Label(entry.displayName, systemImage: "folder.fill")
                    .foregroundStyle(AppTheme.Colors.accent)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    handleDelete(entry)
                } label: { Label("Supprimer", systemImage: "trash") }
                Button {
                    movingEntry = entry
                } label: { Label("Déplacer", systemImage: "folder") }
                    .tint(AppTheme.Colors.accentSecondary)
                Button {
                    renameInput = entry.displayName
                    renamingEntry = entry
                } label: { Label("Renommer", systemImage: "pencil") }
                    .tint(AppTheme.Colors.accent)
            }
        case .file(let fileURL):
            Button {
                selectedFile = fileURL
                showEditor = true
            } label: {
                Label(entry.displayName, systemImage: "doc.text.fill")
                    .foregroundStyle(AppTheme.Colors.textPrimary)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    handleDelete(entry)
                } label: { Label("Supprimer", systemImage: "trash") }
                Button {
                    movingEntry = entry
                } label: { Label("Déplacer", systemImage: "folder") }
                    .tint(AppTheme.Colors.accentSecondary)
                Button {
                    renameInput = entry.displayName
                    renamingEntry = entry
                } label: { Label("Renommer", systemImage: "pencil") }
                    .tint(AppTheme.Colors.accent)
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        entries = SQLConsoleHelper.listEntries(in: directory)
    }

    private func handleCreateFile() {
        guard let url = SQLConsoleHelper.createFile(name: newName, in: directory) else {
            errorMessage = "Impossible de créer ce fichier (nom invalide ou déjà existant)."
            return
        }
        reload()
        selectedFile = url
        showEditor = true
    }

    private func handleCreateFolder() {
        guard SQLConsoleHelper.createFolder(name: newName, in: directory) != nil else {
            errorMessage = "Impossible de créer ce dossier (nom invalide ou déjà existant)."
            return
        }
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

    @Environment(\.dismiss) private var dismiss

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
    @State private var detectedVars: [String] = []
    @State private var variables: [String: String] = [:]
    @State private var currentPage: Int = 0   // 0 = results, 1 = editor
    @State private var showAssistant: Bool = false

    private var fileName: String { fileURL.deletingPathExtension().lastPathComponent }
    private var hasUnfilledVars: Bool { detectedVars.contains { (variables[$0] ?? "").isEmpty } }

    var body: some View {
        TabView(selection: $currentPage) {

            // ── Page 0: Results ──────────────────────────────────────────
            VStack(spacing: 0) {
                if !detectedVars.isEmpty {
                    VariableFormView(variables: $variables, names: detectedVars)
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

                // Swipe hint
                swipeHint(label: "Glisser pour éditer", icon: "chevron.right")
            }
            .tag(0)

            // ── Page 1: Editor ───────────────────────────────────────────
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

                // Swipe hint
                swipeHint(label: "Glisser pour les résultats", icon: "chevron.left")
            }
            .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAssistant = true } label: {
                    Image(systemName: "sparkles")
                }
                .accessibilityLabel("Assistant IA")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { runAndGoToResults() } label: { Label("Exécuter", systemImage: "play.fill") }
                    .disabled(isExecuting || sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .sheet(isPresented: $showAssistant) {
            SQLAssistantSheet { generatedSQL in
                // Si l'éditeur a déjà du contenu, on append (avec un saut de section
                // SQL pour que le parseur de queries nommées le voie comme un nouveau bloc).
                if sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sqlText = generatedSQL
                } else {
                    sqlText += "\n\n-- Assistant IA --\n" + generatedSQL
                }
                autoSave()
                refreshVariables(sqlText)
                currentPage = 1  // bascule vers l'éditeur pour montrer l'insertion
            }
        }
        .onAppear { loadFile() }
    }

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

    // MARK: - File I/O

    private func loadFile() {
        sqlText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        refreshVariables(sqlText)
        // Auto-run if file has content and no variables to fill
        let trimmed = sqlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && detectedVars.isEmpty {
            executeSQL()          // run immediately, stay on results page
        } else if !detectedVars.isEmpty {
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
        let found = extractVariables(from: sql)
        var updated: [String: String] = [:]
        for v in found { updated[v] = variables[v] ?? "" }
        detectedVars = found
        variables = updated
    }

    private func extractVariables(from sql: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\\{\\{([^}]+)\\}\\}") else { return [] }
        let range = NSRange(sql.startIndex..., in: sql)
        var seen = Set<String>(); var result: [String] = []
        re.enumerateMatches(in: sql, range: range) { m, _, _ in
            if let r = m?.range(at: 1), let sr = Range(r, in: sql) {
                let name = String(sql[sr]).trimmingCharacters(in: .whitespaces)
                if seen.insert(name).inserted { result.append(name) }
            }
        }
        return result
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
            func sub(_ sql: String) -> String {
                vars.reduce(sql) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
            }
            var results: [SQLQuerySection] = []
            for q in queries {
                let sql = vars.isEmpty ? q.sql : sub(q.sql)
                let outcome = repo.executeSQL(sql)
                switch outcome {
                case .success(let res): results.append(SQLQuerySection(label: q.name, sql: sql, result: res, error: nil))
                case .failure(let err): results.append(SQLQuerySection(label: q.name, sql: sql, result: nil, error: err.message))
                }
            }
            await MainActor.run { sections = results; isExecuting = false }
        }
    }

    private func substituteVariables(_ sql: String, values: [String: String]) -> String {
        values.reduce(sql) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
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
