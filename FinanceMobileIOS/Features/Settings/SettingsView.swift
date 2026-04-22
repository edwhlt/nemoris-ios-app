import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - UIDocumentPickerViewController wrapper (fiable dans les sheets)

struct DocumentPickerView: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showDBFilePicker = false
    @State private var showSQLFolderPicker = false
    @State private var linkedDBFileName: String? = DatabaseManager.shared.externalFileName
    @State private var linkedSQLFolderName: String? = SQLConsoleHelper.linkedFolderName
    @State private var dbErrorMessage: String?
    @State private var sqlFolderErrorMessage: String?
    @State private var connectionStatus: String? = nil

    var body: some View {
        @Bindable var appState = appState
        NavigationStack {
            Form {
                // MARK: Apparence
                Section("Apparence") {
                    Picker("Thème", selection: $appState.colorSchemeRaw) {
                        Text("Système").tag("system")
                        Text("Clair").tag("light")
                        Text("Sombre").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                // MARK: Base de données
                Section {
                    if let name = linkedDBFileName {
                        LabeledContent("Fichier actif") {
                            Text(name)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }

                        if let status = connectionStatus {
                            LabeledContent("Statut") {
                                Text(status)
                                    .foregroundStyle(status.hasPrefix("Connexion OK") ? .green : .red)
                                    .multilineTextAlignment(.trailing)
                                    .font(.caption)
                            }
                        }

                        Button("Tester la connexion") {
                            connectionStatus = DatabaseManager.shared.connectionStatus()
                        }

                        Button("Supprimer le lien", role: .destructive) {
                            DatabaseManager.shared.unlinkExternalFile()
                            linkedDBFileName = nil
                            connectionStatus = nil
                            dbErrorMessage = nil
                            appState.dataRefreshToken = UUID()
                        }
                    } else {
                        Text("Aucun fichier lié. Sélectionnez un fichier .sqlite pour commencer.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    Button("Sélectionner un fichier SQLite…") {
                        showDBFilePicker = true
                    }

                    if let err = dbErrorMessage {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                } header: {
                    Text("Base de données")
                } footer: {
                    if linkedDBFileName != nil {
                        Text("Les modifications sont écrites directement dans ce fichier.")
                    }
                }

                // MARK: Scripts SQL
                Section {
                    if let name = linkedSQLFolderName {
                        LabeledContent("Dossier actif") {
                            Text(name)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        Button("Réinitialiser le dossier", role: .destructive) {
                            SQLConsoleHelper.unlinkFolder()
                            linkedSQLFolderName = nil
                            sqlFolderErrorMessage = nil
                        }
                    } else {
                        Text("Dossier par défaut : Documents/SQLRequests/")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }

                    Button("Changer le dossier…") {
                        showSQLFolderPicker = true
                    }

                    if let err = sqlFolderErrorMessage {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                } header: {
                    Text("Scripts SQL")
                } footer: {
                    if linkedSQLFolderName != nil {
                        Text("Les fichiers .sql seront lus et créés dans ce dossier.")
                    }
                }
            }
            .navigationTitle("Paramètres")
            .sheet(isPresented: $showDBFilePicker) {
                DocumentPickerView(contentTypes: [.item]) { url in
                    showDBFilePicker = false
                    handleDBPick(url)
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showSQLFolderPicker) {
                DocumentPickerView(contentTypes: [.folder]) { url in
                    showSQLFolderPicker = false
                    handleSQLFolderPick(url)
                }
                .ignoresSafeArea()
            }
        }
    }

    // MARK: - Handlers

    private func handleDBPick(_ url: URL) {
        do {
            try DatabaseManager.shared.linkExternalFile(from: url)
            linkedDBFileName = DatabaseManager.shared.externalFileName
            connectionStatus = DatabaseManager.shared.connectionStatus()
            dbErrorMessage = nil
            appState.dataRefreshToken = UUID()
        } catch {
            dbErrorMessage = error.localizedDescription
            connectionStatus = nil
        }
    }

    private func handleSQLFolderPick(_ url: URL) {
        do {
            try SQLConsoleHelper.linkFolder(from: url)
            linkedSQLFolderName = SQLConsoleHelper.linkedFolderName
            sqlFolderErrorMessage = nil
        } catch {
            sqlFolderErrorMessage = error.localizedDescription
        }
    }
}
