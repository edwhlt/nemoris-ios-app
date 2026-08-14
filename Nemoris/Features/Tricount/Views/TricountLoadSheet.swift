import SwiftUI
import TipKit

struct TricountLoadSheet: View {
    let onSaved: () -> Void
    // paneDismiss : fermeture uniforme sheet iOS / panneau macOS (adaptivePane).
    @Environment(\.paneDismiss) private var dismiss

    private enum LoadState { case input, loading, selectMember(TricountFetchResult), error(String) }

    @State private var state: LoadState = .input
    @State private var urlInput = ""
    @State private var selectedMember = ""
    private let repo = TricountRepository()
    private let client = TricountAPIClient()

    var body: some View {
            Group {
                switch state {
                case .input:
                    Form {
                        Section {
                            TextField("https://tricount.com/fr/XXXXXX", text: $urlInput)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                        } header: { Text("Lien ou code Tricount") } footer: {
                            Text("Collez le lien de partage du Tricount.")
                        }
                        Section {
                            Button("Charger") { load() }
                                .disabled(urlInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .nemorisFormStyle()

                case .loading:
                    VStack(spacing: 16) {
                        ProgressView("Chargement…")
                        Text("Authentification RSA en cours").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)

                case .selectMember(let result):
                    Form {
                        Section("Tricount chargé") {
                            LabeledContent("Titre", value: result.title)
                            LabeledContent("Entrées", value: "\(result.entries.count)")
                            LabeledContent("Dépenses") {
                                Text(
                                    result.entries
                                        .filter { $0.typeTransaction.uppercased() == "NORMAL" && $0.total > 0 }
                                        .reduce(0.0) { $0 + $1.total },
                                    format: .currency(code: result.currency)
                                )
                            }
                            LabeledContent("Devise", value: result.currency)
                        }
                        Section {
                            ForEach(result.members, id: \.self) { member in
                                HStack {
                                    Text(member)
                                    Spacer()
                                    if selectedMember == member {
                                        Image(systemName: "checkmark").foregroundStyle(AppTheme.Colors.accent)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { selectedMember = member }
                            }
                        } header: { Text("Je suis…") } footer: {
                            Text("Sélectionnez votre nom pour calculer vos parts.")
                        }
                        Section {
                            Button("Enregistrer") { save(result: result) }
                                .disabled(selectedMember.isEmpty)
                        }
                    }
                    .nemorisFormStyle()

                case .error(let msg):
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle).foregroundStyle(AppTheme.Colors.danger)
                        Text(msg).multilineTextAlignment(.center).padding(.horizontal)
                        Button("Réessayer") { state = .input }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .paneChrome("Charger un Tricount", cancelLabel: "Annuler", onCancel: { dismiss() })
    }

    private func load() {
        let key = extractKey(urlInput.trimmingCharacters(in: .whitespaces))
        state = .loading
        Task {
            do {
                let result = try await client.fetch(key: key)
                await MainActor.run {
                    selectedMember = result.members.first ?? ""
                    state = .selectMember(result)
                }
            } catch {
                await MainActor.run { state = .error(error.localizedDescription) }
            }
        }
    }

    private func save(result: TricountFetchResult) {
        let key = extractKey(urlInput.trimmingCharacters(in: .whitespaces))
        guard DatabaseManager.shared.hasDatabase() else {
            state = .error("Aucune base de données configurée. Importez d'abord un fichier SQLite.")
            return
        }
        DatabaseManager.shared.migrateIfNeeded()
        let myEntries = result.entries.filter { entry in
            entry.whoPaid == selectedMember ||
            entry.shares.contains { $0.memberName == selectedMember }
        }
        let savedId = repo.saveGroup(key: key, title: result.title, currency: result.currency,
                                     myName: selectedMember, entries: myEntries)
        if let gid = savedId {
            Task { await CurrencyRateService.syncRates(groupId: gid) }
            onSaved()
            dismiss()
        } else {
            state = .error("Impossible d'enregistrer le Tricount. Vérifiez que la base de données est accessible en écriture.")
        }
    }

    private func extractKey(_ input: String) -> String {
        if let range = input.range(of: #"tricount\.com/(?:[a-z]{1,3}/)?([^/?#\s]+)"#, options: .regularExpression) {
            return String(input[range]).components(separatedBy: "/").last ?? input
        }
        return input.components(separatedBy: "/").last?.components(separatedBy: "?").first ?? input
    }
}
