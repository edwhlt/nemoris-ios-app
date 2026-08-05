import SwiftUI

/// Section « Métadonnées » d'une fiche transaction — remplace le picker
/// « moyen de paiement ».
///
/// ─── Ce qui change, et pourquoi ────────────────────────────────────────────
///
/// `transactions.payment_type_id` était le seul attribut libre posable sur une
/// transaction en dehors de tiers/catégorie/tags, et il imposait sa sémantique à
/// tout le monde. Il devient une métadonnée parmi d'autres, définies par
/// l'utilisateur : « Projet », « Pro / Perso », « Compte joint »… ou rien du
/// tout.
///
/// ⚠️ Une base NEUVE n'a AUCUNE clé. Cette section affiche alors une invitation
/// à en créer, pas un champ vide — sinon elle ressemblerait à une fonctionnalité
/// cassée.
struct TransactionMetadataSection: View {

    /// `nil` tant que la transaction n'existe pas en base (création) : on ne
    /// peut pas rattacher une valeur à une ligne qui n'a pas d'id.
    let transactionId: Int?

    @State private var keys: [TransactionMetadataKey] = []
    @State private var values: [Int: String] = [:]        // keyId → valeur
    @State private var suggestions: [Int: [String]] = [:] // keyId → valeurs déjà vues
    @State private var showKeyManager = false

    private let repository = TransactionMetadataRepository()

    var body: some View {
        Section {
            if keys.isEmpty {
                emptyState
            } else {
                ForEach(keys) { key in
                    metadataRow(key)
                }
            }
            Button {
                showKeyManager = true
            } label: {
                Label(keys.isEmpty ? "Créer une métadonnée" : "Gérer les métadonnées",
                      systemImage: keys.isEmpty ? "plus.circle" : "slider.horizontal.3")
                    .font(.callout)
            }
        } header: {
            Text("Métadonnées")
        } footer: {
            if transactionId == nil {
                Text("Enregistre d'abord la transaction pour lui poser des métadonnées.")
            } else if !keys.isEmpty {
                Text("Texte libre. Laisse un champ vide pour retirer la métadonnée de cette transaction.")
            }
        }
        .adaptivePane(isPresented: $showKeyManager) {
            MetadataKeyManagerView(onChange: load)
        }
        .task { load() }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Aucune métadonnée définie")
                .font(.subheadline.weight(.medium))
            Text("Les métadonnées sont des étiquettes que tu définis toi-même — « Projet », « Pro / Perso », « Mode de paiement »… — pour classer tes transactions comme tu l'entends.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func metadataRow(_ key: TransactionMetadataKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(key.name, systemImage: key.displayIcon)
                    .font(.subheadline)
                Spacer()
                TextField("Valeur", text: Binding(
                    get: { values[key.id] ?? "" },
                    set: { newValue in
                        values[key.id] = newValue
                        commit(key: key, value: newValue)
                    }
                ))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(transactionId == nil)
            }

            // Suggestions : ce qui a DÉJÀ été saisi pour cette clé, du plus
            // fréquent au moins fréquent.
            //
            // ⚠️ Suggestions seulement — aucune contrainte en base. Les figer en
            // liste fermée recréerait une table de référence, exactement ce
            // qu'on vient de retirer.
            let proposals = (suggestions[key.id] ?? []).filter { $0 != (values[key.id] ?? "") }
            if !proposals.isEmpty, transactionId != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(proposals.prefix(6), id: \.self) { proposal in
                            Button {
                                values[key.id] = proposal
                                commit(key: key, value: proposal)
                            } label: {
                                Text(proposal)
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(AppTheme.Colors.accent.opacity(0.12), in: Capsule())
                                    .foregroundStyle(AppTheme.Colors.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Données

    private func load() {
        keys = repository.fetchKeys()
        suggestions = Dictionary(uniqueKeysWithValues: keys.map {
            ($0.id, repository.distinctValues(keyId: $0.id))
        })
        guard let transactionId else { values = [:]; return }
        values = Dictionary(uniqueKeysWithValues:
            repository.fetchValues(transactionId: transactionId).map { ($0.keyId, $0.value) })
    }

    /// Écriture IMMÉDIATE, sans bouton « enregistrer ».
    ///
    /// Cohérent avec les tags, qui s'appliquent aussi à la volée : une
    /// métadonnée est une étiquette, pas un champ du formulaire principal. Une
    /// valeur vidée retire la ligne (cf. `setValue`).
    private func commit(key: TransactionMetadataKey, value: String) {
        guard let transactionId else { return }
        repository.setValue(value, keyId: key.id, transactionId: transactionId)
    }
}

/// Création, renommage et suppression des clés de métadonnées.
///
/// Volontairement séparé de `ReferenceDataView` : c'est un référentiel léger,
/// créé au fil de l'eau depuis la fiche transaction, là où catégories et tiers
/// se gèrent en masse.
struct MetadataKeyManagerView: View {
    @Environment(\.paneDismiss) private var dismiss
    var onChange: () -> Void = {}

    @State private var keys: [TransactionMetadataKey] = []
    @State private var newName = ""
    @State private var newIcon = "tag"
    @State private var fillsFromImport = false
    @State private var errorMessage: String?

    private let repository = TransactionMetadataRepository()

    /// Quelques symboles courants — saisir un nom de SF Symbol à la main n'a
    /// aucun sens pour un utilisateur.
    private let iconChoices = ["tag", "creditcard", "briefcase", "folder", "person.2",
                               "building.2", "airplane", "car", "house", "star"]

    var body: some View {
        Form {
            Section {
                ForEach(keys) { key in
                    HStack(spacing: 10) {
                        Image(systemName: key.displayIcon)
                            .foregroundStyle(AppTheme.Colors.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name)
                            if let role = key.role {
                                Text(LocalizedStringKey(role.displayName))
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) {
                            repository.deleteKey(id: key.id)
                            reload()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.Colors.danger)
                    }
                }
                if keys.isEmpty {
                    Text("Aucune métadonnée pour l'instant.")
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                }
            } header: {
                Text("Métadonnées existantes")
            } footer: {
                // ⚠️ Le CASCADE est réel : le dire avant, pas après.
                Text("Supprimer une métadonnée efface aussi toutes les valeurs posées sur les transactions.")
            }

            Section {
                TextField("Nom (ex. Projet, Pro / Perso)", text: $newName)
                Picker("Icône", selection: $newIcon) {
                    ForEach(iconChoices, id: \.self) { icon in
                        Label(icon, systemImage: icon).tag(icon)
                    }
                }
                Toggle("Renseignée par l'import", isOn: $fillsFromImport)
                Button {
                    create()
                } label: {
                    Label("Créer", systemImage: "plus.circle.fill")
                }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.danger)
                }
            } header: {
                Text("Nouvelle métadonnée")
            } footer: {
                Text("« Renseignée par l'import » fait remplir cette métadonnée automatiquement avec le moyen de paiement déduit du libellé bancaire (CB, virement, prélèvement…). Une seule métadonnée peut jouer ce rôle.")
            }
        }
        .nemorisFormStyle()
        .scrollContentBackground(.hidden)
        .background(AppTheme.Colors.background.ignoresSafeArea())
        // Convention : toute vue présentée en panneau pose son propre tint.
        .tint(AppTheme.Colors.accent)
        .paneChrome("Métadonnées", cancelLabel: "Fermer", onCancel: { dismiss() })
        .task { reload() }
    }

    private func create() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository.addKey(name: trimmed, icon: newIcon,
                                role: fillsFromImport ? .paymentMethod : nil) != nil else {
            errorMessage = "Ce nom est déjà utilisé."
            return
        }
        newName = ""
        fillsFromImport = false
        errorMessage = nil
        reload()
    }

    private func reload() {
        keys = repository.fetchKeys()
        onChange()
    }
}

/// Contenu de l'onglet « Métadonnées » de l'écran Données.
///
/// ⚠️ Vue à part, et pas un `case` de plus dans le `switch` de
/// `ReferenceDataView` : celui-ci atteignait déjà la limite de type-check du
/// compilateur (« unable to type-check this expression in reasonable time »).
struct MetadataKeysTabContent: View {
    let searchText: String

    @State private var keys: [TransactionMetadataKey] = []
    @State private var usage: [Int: Int] = [:]
    @State private var showManager = false

    private let repository = TransactionMetadataRepository()

    private var filtered: [TransactionMetadataKey] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return keys }
        return keys.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        Group {
            if keys.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Aucune métadonnée")
                        .font(.subheadline.weight(.medium))
                    Text("Définis tes propres étiquettes — « Projet », « Pro / Perso », « Mode de paiement »… — pour classer tes transactions comme tu l'entends.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
                .listRowBackground(AppTheme.Colors.surface)
            } else {
                ForEach(filtered) { key in
                    HStack(spacing: 10) {
                        Image(systemName: key.displayIcon)
                            .foregroundStyle(AppTheme.Colors.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.name)
                            if let role = key.role {
                                Text(LocalizedStringKey(role.displayName))
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                            }
                        }
                        Spacer()
                        Text("\(usage[key.id] ?? 0)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                    .listRowBackground(AppTheme.Colors.surface)
                }
            }

            Button {
                showManager = true
            } label: {
                Label("Gérer les métadonnées", systemImage: "slider.horizontal.3")
            }
            .listRowBackground(AppTheme.Colors.surface)
        }
        .adaptivePane(isPresented: $showManager) {
            MetadataKeyManagerView(onChange: load)
        }
        .task { load() }
    }

    private func load() {
        keys = repository.fetchKeys()
        usage = Dictionary(uniqueKeysWithValues: keys.map {
            ($0.id, repository.transactionIds(keyId: $0.id, value: nil).count)
        })
    }
}
