import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Environment(AppState.self) private var appState
    private let repository = TransactionRepository()

    // Fichier CSV chargé
    @State private var csvHeaders: [String] = []
    @State private var csvRows: [[String]] = []
    @State private var showFilePicker = false
    @State private var fileError: String?

    // Mapping de colonnes
    @State private var libelleColumn = ""
    @State private var amountColumn = ""
    @State private var dateColumn = ""
    @State private var selectedAccountId: Int = 0

    // Données de référence
    @State private var accounts: [Account] = []
    @State private var allTiers: [Tiers] = []
    @State private var allMdps: [PaymentType] = []

    // Résultats analyse
    @State private var parsedTransactions: [PendingTransaction] = []
    @State private var isAnalyzed = false
    @State private var importMessage: String?
    @State private var isImporting = false

    // Sélection tiers dans l'aperçu
    @State private var editingTiersIdx: Int? = nil
    @State private var showTiersPicker = false

    private var isFileLoaded: Bool { !csvHeaders.isEmpty }
    private var isMappingReady: Bool {
        isFileLoaded && !libelleColumn.isEmpty && !amountColumn.isEmpty && !dateColumn.isEmpty && selectedAccountId != 0
    }
    private var matchedCount: Int { parsedTransactions.filter { $0.tiersId != nil }.count }
    private var unmatchedCount: Int { parsedTransactions.filter { $0.tiersId == nil }.count }

    var body: some View {
        NavigationStack {
            Form {
                // ── Fichier ──────────────────────────────────────────
                Section("Fichier CSV") {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Choisir un fichier CSV", systemImage: "doc.badge.plus")
                    }

                    if let err = fileError {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }

                    if isFileLoaded {
                        LabeledContent("Lignes détectées", value: "\(csvRows.count)")
                        LabeledContent("Colonnes", value: csvHeaders.joined(separator: ", "))
                            .font(.caption)
                    }
                }

                // ── Mapping ───────────────────────────────────────────
                if isFileLoaded {
                    Section("Paramètres d'import") {
                        if accounts.isEmpty {
                            Text("Aucun compte disponible — importe d'abord un fichier finance.sqlite dans Paramètres.")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        } else {
                            Picker("Compte", selection: $selectedAccountId) {
                                ForEach(accounts) { a in
                                    Text(a.name).tag(a.id)
                                }
                            }
                        }

                        Picker("Colonne libellé", selection: $libelleColumn) {
                            ForEach(csvHeaders, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Colonne montant", selection: $amountColumn) {
                            ForEach(csvHeaders, id: \.self) { Text($0).tag($0) }
                        }
                        Picker("Colonne date", selection: $dateColumn) {
                            ForEach(csvHeaders, id: \.self) { Text($0).tag($0) }
                        }

                        Button("Analyser") { analyze() }
                            .disabled(!isMappingReady)
                    }
                }

                // ── Résultats ─────────────────────────────────────────
                if isAnalyzed {
                    Section("Résultats de l'analyse") {
                        LabeledContent("Transactions", value: "\(parsedTransactions.count)")
                        LabeledContent("Tiers identifiés", value: "\(matchedCount)")
                            .foregroundStyle(matchedCount == parsedTransactions.count ? Color.primary : Color.orange)
                        if unmatchedCount > 0 {
                            LabeledContent("Sans tiers", value: "\(unmatchedCount)")
                                .foregroundStyle(Color.orange)
                        }

                        if isImporting {
                            HStack {
                                ProgressView()
                                Text("Import en cours…").foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Importer \(parsedTransactions.count) transactions") {
                                importTransactions()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(parsedTransactions.isEmpty)
                        }

                        if let msg = importMessage {
                            Text(msg).foregroundStyle(.secondary).font(.caption)
                        }
                    }

                    // ── Aperçu complet — tiers tappables ───────────────
                    Section("Transactions (\(parsedTransactions.count)) — toucher le tiers pour l'assigner") {
                        ForEach(Array(parsedTransactions.enumerated()), id: \.element.id) { idx, tx in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(tx.information)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(tx.amount, format: .currency(code: "EUR"))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                                HStack {
                                    Text(tx.date, style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    // Badge tiers tappable
                                    Button {
                                        editingTiersIdx = idx
                                        showTiersPicker = true
                                    } label: {
                                        HStack(spacing: 3) {
                                            Image(systemName: tx.tiersName.isEmpty ? "person.badge.plus" : "person.fill")
                                            Text(tx.tiersName.isEmpty ? "Assigner" : tx.tiersName)
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(tx.tiersName.isEmpty ? Color.orange : Color.green)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("Import CSV")
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [UTType.commaSeparatedText, UTType.plainText, UTType.data],
                allowsMultipleSelection: false
            ) { result in
                handleFileResult(result)
            }
            .sheet(isPresented: $showTiersPicker) {
                let capturedIdx = editingTiersIdx
                let capturedLibelle = capturedIdx.map { parsedTransactions[$0].information } ?? ""
                TiersPickerSheet(allTiers: allTiers, repository: repository, libelle: capturedLibelle) { selectedTiers in
                    if let idx = capturedIdx {
                        parsedTransactions[idx].tiersId = selectedTiers.id
                        parsedTransactions[idx].tiersName = selectedTiers.name
                    }
                    allTiers = repository.fetchTiers()
                }
            }
            .task(id: appState.dataRefreshToken) {
                loadReferenceData()
            }
        }
    }

    // MARK: - Chargement données de référence

    private func loadReferenceData() {
        accounts = repository.fetchAccounts()
        allTiers = repository.fetchTiers()
        allMdps = repository.fetchPaymentTypes()

        if selectedAccountId == 0, let first = accounts.first {
            selectedAccountId = first.id
        }
    }

    // MARK: - Lecture du fichier CSV

    private func handleFileResult(_ result: Result<[URL], Error>) {
        fileError = nil
        guard case .success(let urls) = result, let url = urls.first else { return }

        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        // Essaie UTF-8, puis Windows-1252 (exports bancaires courants), puis ISO-Latin-1
        guard let rawContent = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .windowsCP1252))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) else {
            fileError = "Impossible de lire le fichier (encodage non supporté)"
            return
        }
        // Supprime le BOM UTF-8 éventuel (fichiers Excel)
        let content = rawContent.hasPrefix("\u{FEFF}") ? String(rawContent.dropFirst()) : rawContent

        let lines = content
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let headerLine = lines.first else {
            fileError = "Fichier vide"
            return
        }

        csvHeaders = headerLine.components(separatedBy: ";")
        csvRows = lines.dropFirst().map { $0.components(separatedBy: ";") }

        // Détection intelligente des colonnes
        libelleColumn = csvHeaders.first(where: {
            let l = $0.lowercased()
            return l.contains("libel") || l.contains("intit") || l.contains("label") || l.contains("descri")
        }) ?? csvHeaders.first ?? ""

        // "valeur" exclu intentionnellement : "Date de valeur" ne doit pas matcher
        amountColumn = csvHeaders.first(where: {
            let l = $0.lowercased()
            return l.contains("montant") || l.contains("amount") || l.contains("debit") || l.contains("crédit")
        }) ?? csvHeaders.first(where: { $0.lowercased().contains("mont") }) ?? ""

        // Préfère la colonne exactement "Date" plutôt que "Date de valeur"
        dateColumn = csvHeaders.first(where: { $0.lowercased() == "date" })
            ?? csvHeaders.first(where: { $0.lowercased().hasPrefix("date") && !$0.lowercased().contains("valeur") })
            ?? csvHeaders.first(where: { $0.lowercased().contains("date") })
            ?? ""

        isAnalyzed = false
        parsedTransactions = []
        importMessage = nil
    }

    // MARK: - Analyse et matching regex

    private func analyze() {
        guard let libelleIdx = csvHeaders.firstIndex(of: libelleColumn),
              let amountIdx = csvHeaders.firstIndex(of: amountColumn),
              let dateIdx = csvHeaders.firstIndex(of: dateColumn) else { return }

        // Formats de date supportés (ordre = priorité)
        let dateFormatters: [DateFormatter] = [
            "dd/MM/yyyy", "yyyy-MM-dd", "dd.MM.yyyy", "dd-MM-yyyy",
            "dd/MM/yy",   "dd.MM.yy",  "MM/dd/yyyy", "yyyy/MM/dd"
        ].map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = $0
            return f
        }

        func parseDate(_ raw: String) -> Date? {
            let s = raw.trimmingCharacters(in: .whitespaces)
            for f in dateFormatters { if let d = f.date(from: s) { return d } }
            return nil
        }

        // Gère : "1234.56", "1234,56", "1.234,56" (EU), "1,234.56" (US)
        func parseAmount(_ raw: String) -> Double? {
            var s = raw
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\u{00A0}", with: "") // espace insécable
                .replacingOccurrences(of: " ", with: "")
            let hasComma = s.contains(",")
            let hasDot   = s.contains(".")
            if hasComma && hasDot {
                // Détermine le rôle des séparateurs selon leur position
                let lastCommaIdx = s.lastIndex(of: ",")!
                let lastDotIdx   = s.lastIndex(of: ".")!
                if lastCommaIdx > lastDotIdx {
                    // Format européen : 1.234,56 → 1234.56
                    s = s.replacingOccurrences(of: ".", with: "")
                    s = s.replacingOccurrences(of: ",", with: ".")
                } else {
                    // Format US : 1,234.56 → 1234.56
                    s = s.replacingOccurrences(of: ",", with: "")
                }
            } else if hasComma {
                // Décimale virgule seule : 1234,56 → 1234.56
                s = s.replacingOccurrences(of: ",", with: ".")
            }
            return Double(s)
        }

        parsedTransactions = csvRows.compactMap { row in
            guard row.count > max(libelleIdx, amountIdx, dateIdx) else { return nil }

            let libelle = row[libelleIdx].trimmingCharacters(in: .whitespaces)

            guard let amount = parseAmount(row[amountIdx]) else { return nil }
            guard let date   = parseDate(row[dateIdx])     else { return nil }

            let (tiersId, tiersName) = matchTiers(for: libelle)
            let (mdpId, mdpName) = matchMdp(for: libelle)

            return PendingTransaction(
                accountId: selectedAccountId,
                tiersId: tiersId,
                mdpId: mdpId,
                information: libelle,
                amount: amount,
                date: date,
                tiersName: tiersName,
                mdpName: mdpName
            )
        }

        isAnalyzed = true
        importMessage = nil
    }

    private func matchTiers(for text: String) -> (Int?, String) {
        for t in allTiers {
            guard let pattern = t.regex, !pattern.isEmpty else { continue }
            if matchesRegex(pattern, in: text) { return (t.id, t.name) }
        }
        return (nil, "")
    }

    private func matchMdp(for text: String) -> (Int?, String) {
        for m in allMdps {
            guard let pattern = m.regex, !pattern.isEmpty else { continue }
            if matchesRegex(pattern, in: text) { return (m.id, m.name) }
        }
        return (nil, "")
    }

    private func matchesRegex(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    // MARK: - Import en base

    private func importTransactions() {
        isImporting = true
        let count = repository.insertTransactions(parsedTransactions)
        isImporting = false
        importMessage = "\(count) transaction(s) importée(s) avec succès."
        appState.dataRefreshToken = UUID()
    }
}

// MARK: - Sélecteur / créateur de tiers

struct TiersPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let allTiers: [Tiers]
    let repository: TransactionRepository
    let libelle: String          // libellé de la transaction, pré-remplit la regex
    let onSelect: (Tiers) -> Void

    @State private var search = ""
    @State private var showCreateForm = false
    @State private var newName = ""
    @State private var newRegex = ""

    private var filtered: [Tiers] {
        guard !search.isEmpty else { return allTiers }
        return allTiers.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                // Formulaire de création inline
                if showCreateForm {
                    Section("Nouveau tiers") {
                        TextField("Nom", text: $newName)
                            .autocorrectionDisabled()
                        TextField("Regex de détection (optionnel)", text: $newRegex)
                            .autocorrectionDisabled()
                            .autocapitalization(.none)
                        Button("Créer et sélectionner") {
                            createAndSelect()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section(filtered.isEmpty ? "Aucun résultat" : "Tiers existants (\(filtered.count))") {
                    ForEach(filtered) { t in
                        Button {
                            onSelect(t)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).foregroundStyle(.primary)
                                if let r = t.regex, !r.isEmpty {
                                    Text(r).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Rechercher…")
            .navigationTitle("Choisir un tiers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        newName = search
                        showCreateForm = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private func createAndSelect() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let regex = newRegex.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let newId = repository.addTiersAndGetId(name: name, regex: regex) {
            onSelect(Tiers(id: newId, name: name, regex: regex.isEmpty ? nil : regex))
            dismiss()
        }
    }
}
