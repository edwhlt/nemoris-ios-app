import SwiftUI

// MARK: - Helper

enum SQLConsoleHelper {
    private static let folderBookmarkKey = "sqlScriptsFolderBookmark"

    // MARK: - Folder management

    static func sqlDirectory() -> URL {
        resolveStoredFolder() ?? defaultSQLDirectory()
    }

    static var linkedFolderName: String? {
        resolveStoredFolder()?.lastPathComponent
    }

    /// Persists a security-scoped bookmark for the chosen folder.
    static func linkFolder(from pickerURL: URL) throws {
        let hasAccess = pickerURL.startAccessingSecurityScopedResource()
        defer { if hasAccess { pickerURL.stopAccessingSecurityScopedResource() } }
        let data = try pickerURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: folderBookmarkKey)
    }

    static func unlinkFolder() {
        UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
    }

    private static func resolveStoredFolder() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        if isStale {
            if let newData = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(newData, forKey: folderBookmarkKey)
            }
        }
        return url
    }

    private static func defaultSQLDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("SQLRequests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - File listing

    static func listSQLFiles() -> [URL] {
        let dir = sqlDirectory()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { $0.pathExtension == "sql" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
    @State private var files: [URL] = []
    @State private var showCreateAlert = false
    @State private var newFileName = ""
    @State private var selectedFile: URL?
    @State private var showEditor = false

    var body: some View {
        List {
            if files.isEmpty {
                ContentUnavailableView(
                    "Aucun fichier SQL",
                    systemImage: "doc.text",
                    description: Text("Appuyez sur + pour créer un fichier")
                )
            } else {
                ForEach(files, id: \.path) { file in
                    Button {
                        selectedFile = file
                        showEditor = true
                    } label: {
                        Label(file.deletingPathExtension().lastPathComponent, systemImage: "doc.text.fill")
                            .foregroundStyle(.primary)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteFile(file)
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .navigationTitle("Console SQL")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newFileName = ""
                    showCreateAlert = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .navigationDestination(isPresented: $showEditor) {
            if let file = selectedFile {
                SQLEditorView(fileURL: file)
            }
        }
        .alert("Nouveau fichier SQL", isPresented: $showCreateAlert) {
            TextField("nom_du_fichier", text: $newFileName)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Créer") { createFile() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Sans extension .sql")
        }
        .onAppear { reloadFiles() }
    }

    private func reloadFiles() {
        files = SQLConsoleHelper.listSQLFiles()
    }

    private func createFile() {
        var name = newFileName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "requete" }
        if !name.hasSuffix(".sql") { name += ".sql" }
        let url = SQLConsoleHelper.sqlDirectory().appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        reloadFiles()
        selectedFile = url
        showEditor = true
    }

    private func deleteFile(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        reloadFiles()
    }
}

// MARK: - Editor View

struct SQLEditorView: View {
    let fileURL: URL

    private let repository = TransactionRepository()
    @State private var sqlText: String = ""
    @State private var sections: [SQLQuerySection] = []
    @State private var isExecuting = false
    @State private var saveStatus: String? = nil

    private var fileName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        VStack(spacing: 0) {
            // Editor
            TextEditor(text: $sqlText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200, maxHeight: 280)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
                .padding(.horizontal)
                .padding(.top, 8)
                .onChange(of: sqlText) { _, _ in
                    autoSave()
                }

            if let status = saveStatus {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider()

            // Results
            if sections.isEmpty && !isExecuting {
                ContentUnavailableView(
                    "Aucun résultat",
                    systemImage: "play.circle",
                    description: Text("Appuyez sur Exécuter pour lancer la requête")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if isExecuting {
                            ProgressView("Exécution...")
                                .frame(maxWidth: .infinity)
                                .padding()
                        }
                        ForEach(sections) { section in
                            SQLResultSectionView(section: section)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    executeSQL()
                } label: {
                    Label("Exécuter", systemImage: "play.fill")
                }
                .disabled(isExecuting || sqlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear {
            loadFile()
        }
    }

    private func loadFile() {
        sqlText = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    private func autoSave() {
        try? sqlText.write(to: fileURL, atomically: true, encoding: .utf8)
        saveStatus = "Sauvegardé"
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            saveStatus = nil
        }
    }

    private func executeSQL() {
        isExecuting = true
        sections = []
        let queries = splitStatements(sqlText)
        let repo = repository
        Task.detached(priority: .userInitiated) {
            var results: [SQLQuerySection] = []
            for (i, query) in queries.enumerated() {
                let label = queries.count > 1 ? "Requête \(i + 1)" : "Résultat"
                let outcome = repo.executeSQL(query)
                switch outcome {
                case .success(let res):
                    results.append(SQLQuerySection(label: label, sql: query, result: res, error: nil))
                case .failure(let err):
                    results.append(SQLQuerySection(label: label, sql: query, result: nil, error: err.message))
                }
            }
            await MainActor.run {
                sections = results
                isExecuting = false
            }
        }
    }

    /// Split SQL text into individual statements, stripping line comments
    private func splitStatements(_ text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        let cleaned = lines.map { line -> String in
            if let range = line.range(of: "--") {
                return String(line[..<range.lowerBound])
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Section header
            HStack {
                Text(section.label)
                    .font(.headline)
                Spacer()
                if let result = section.result {
                    Text("\(result.rows.count) ligne(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // SQL preview
            Text(section.sql.prefix(120) + (section.sql.count > 120 ? "…" : ""))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let error = section.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
            } else if let result = section.result {
                if result.columns.isEmpty {
                    Label("Requête exécutée avec succès", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(6)
                } else {
                    // Horizontal scroll table
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            // Header row
                            HStack(spacing: 0) {
                                ForEach(result.columns, id: \.self) { col in
                                    Text(col)
                                        .font(.caption.bold())
                                        .frame(minWidth: 80, alignment: .leading)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color(.tertiarySystemBackground))
                                }
                            }
                            Divider()
                            // Data rows
                            ForEach(Array(result.rows.enumerated()), id: \.offset) { idx, row in
                                SQLTableRowView(columns: result.columns, row: row, isEven: idx % 2 == 0)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(8)
                }
            }
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 2)
    }
}

// MARK: - Table Row View

private struct SQLTableRowView: View {
    let columns: [String]
    let row: [String]
    let isEven: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { idx, col in
                let value = idx < row.count ? row[idx] : ""
                Text(value.isEmpty ? "NULL" : value)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minWidth: 80, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .foregroundStyle(value.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            }
        }
        .background(isEven ? Color.clear : Color(.secondarySystemBackground).opacity(0.5))
    }
}
