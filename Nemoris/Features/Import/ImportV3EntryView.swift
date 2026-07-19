import SwiftUI
import UniformTypeIdentifiers

/// Point d'entrée du nouveau parcours d'import (AXE D). Remplace `ImportView` legacy.
///
/// Flux :
///   1. Sélection du compte cible + sélection d'un fichier CSV.
///   2. Parse du CSV → si signature du header connue → preview + confirm → session créée.
///   3. Sinon → push vers ColumnMappingView pour mapper date/montant/libellé.
struct ImportV3EntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var accounts: [Account] = []
    @State private var selectedAccountId: Int? = nil
    @State private var showFilePicker = false
    @State private var parseError: String?

    @State private var parsedCSV: CSVParserV3.Parsed?
    @State private var pendingFileName: String?
    @State private var showMapping = false
    @State private var existingActiveSession: ImportSessionSummary?
    @State private var showResumeAlert = false
    @State private var isParsing = false

    private let repository = TransactionRepository()
    private let sessionRepo = ImportSessionRepository()

    var body: some View {
        NavigationStack {
            Form {
                Section("Compte cible") {
                    if accounts.isEmpty {
                        Text("Aucun compte disponible — créez-en un d'abord.")
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    } else {
                        Picker("Compte", selection: $selectedAccountId) {
                            Text("Choisir…").tag(Int?.none)
                            ForEach(accounts) { a in
                                Text(a.name).tag(Int?.some(a.id))
                            }
                        }
                    }
                }

                Section("Fichier CSV") {
                    Button {
                        showFilePicker = true
                    } label: {
                        if isParsing {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Analyse du fichier…")
                            }
                        } else {
                            Label("Choisir un fichier CSV", systemImage: "doc.badge.plus")
                        }
                    }
                    .disabled(selectedAccountId == nil || isParsing)

                    if let parseError {
                        Text(parseError)
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.danger)
                    }
                }

                Section {
                    Text("Une fois le fichier choisi, vous mapperez les colonnes (date / montant / libellé). Le mapping est mémorisé pour les prochains imports du même format.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                } header: { Text("À savoir") }
            }
            .navigationTitle("Importer un CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .utf8PlainText, .text, .data, .item],
                allowsMultipleSelection: false
            ) { result in
                handleFileResult(result)
            }
            .navigationDestination(isPresented: $showMapping) {
                if let parsed = parsedCSV, let accountId = selectedAccountId {
                    ColumnMappingView(
                        parsed: parsed,
                        accountId: accountId,
                        sourceFile: pendingFileName,
                        onSessionCreated: { newSummary in
                            appState.activeImportSession = newSummary
                            appState.showImportSessionSheet = true
                            dismiss()
                        }
                    )
                }
            }
            .alert("Une session d'import est déjà en cours",
                   isPresented: $showResumeAlert, presenting: existingActiveSession) { _ in
                Button("Reprendre") {
                    appState.showImportSessionSheet = true
                    dismiss()
                }
                Button("Annuler la précédente", role: .destructive) {
                    if let id = existingActiveSession?.id {
                        sessionRepo.deleteSession(id: id)
                        ImportNotificationService.cancelReminder(forSessionId: id)
                        appState.reloadActiveImportSession()
                        existingActiveSession = nil
                    }
                }
                Button("Fermer", role: .cancel) { dismiss() }
            } message: { _ in
                Text("Vous devez d'abord la terminer ou l'annuler avant d'en démarrer une nouvelle.")
            }
            .task { loadInitialState() }
        }
    }

    // MARK: - Logic

    private func loadInitialState() {
        accounts = repository.fetchAccounts()
        if selectedAccountId == nil {
            let preferred = appState.defaultAccountId > 0 ? appState.defaultAccountId : (appState.selectedAccountId ?? 0)
            selectedAccountId = accounts.first(where: { $0.id == preferred })?.id ?? accounts.first?.id
        }
        if let active = sessionRepo.fetchActiveSummary() {
            existingActiveSession = active
            showResumeAlert = true
        }
    }

    private func handleFileResult(_ result: Result<[URL], Error>) {
        parseError = nil
        switch result {
        case .failure(let err):
            parseError = err.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // Lecture + parse en background : un CSV de 1000 lignes peut bloquer le main
            // thread plusieurs centaines de millisecondes.
            isParsing = true
            Task {
                let outcome: (Data, String)? = {
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    guard let d = try? Data(contentsOf: url) else { return nil }
                    return (d, url.lastPathComponent)
                }()
                guard let (data, name) = outcome else {
                    await MainActor.run {
                        isParsing = false
                        parseError = "Lecture impossible : \(url.lastPathComponent)"
                    }
                    return
                }
                let parsed = await Task.detached(priority: .userInitiated) { () -> CSVParserV3.Parsed? in
                    let content = Self.decodeText(from: data)
                    return CSVParserV3.parse(content: content)
                }.value

                await MainActor.run {
                    isParsing = false
                    guard let parsed, !parsed.rows.isEmpty else {
                        parseError = "Aucune ligne trouvée dans \(name)."
                        return
                    }
                    self.parsedCSV = parsed
                    self.pendingFileName = name
                    self.showMapping = true
                }
            }
        }
    }

    /// Décodage permissif (BOM UTF-8, UTF-16, Windows-1252, ISO Latin-1).
    /// `nonisolated static` pour pouvoir être appelée depuis `Task.detached`.
    nonisolated static func decodeText(from data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]),
           let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]), let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return ""
    }
}
