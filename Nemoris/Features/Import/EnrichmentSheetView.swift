import SwiftUI
import MapKit
import NemorisEngine

/// Sheet d'enrichissement par ligne (AXE B affiné).
///
/// Pour une `ImportSessionRow` non résolue, l'utilisateur peut :
///   - personnaliser la requête de recherche (le rawLabel est rarement parfait)
///   - choisir quelles sources interroger (Sirene / Apple Maps / IA Foundation Models)
///   - voir TOUS les candidats côte à côte (avec badge source) et en choisir un
///
/// Le résultat choisi est passé via `onApply` qui le pose dans la row du ViewModel
/// (`assignedPayeeName`, `assignedCategoryId`, etc.) et marque la row `.manuallySet`.
struct EnrichmentSheetView: View {
    @Environment(\.dismiss) private var dismiss

    let row: ImportSessionRow
    let onApply: (MerchantEnrichment) -> Void

    @State private var query: String
    @State private var postalCode: String = ""
    @State private var useSirene: Bool = true
    @State private var useMapKit: Bool = true
    @State private var useLLM: Bool = false   // off par défaut : génère parfois du bruit
    @State private var isSearching: Bool = false
    @State private var hasSearched: Bool = false
    @State private var candidates: [Candidate] = []
    @State private var selectedCandidateId: UUID? = nil
    @State private var cameraPosition: MapCameraPosition = .automatic

    init(row: ImportSessionRow, onApply: @escaping (MerchantEnrichment) -> Void) {
        self.row = row
        self.onApply = onApply
        // Priorité au RAW LABEL — le canonical du moteur perd souvent les indices
        // géographiques (ex. "VNPAY HUNG RES PSC VN P HA GIANG" → "vnpay" sans VN ni HA GIANG).
        _query = State(initialValue: row.rawLabel)
        _useLLM = State(initialValue: Self.isFoundationModelsAvailable)
    }

    var body: some View {
        NavigationStack {
            Form {
                contextSection
                querySection
                sourcesSection
                if hasSearched {
                    if !geoCandidates.isEmpty {
                        mapSection
                    }
                    resultsSection
                }
            }
            .navigationTitle("Enrichir cette ligne")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }

    /// Candidats ayant des coordonnées GPS (utilisable sur la map).
    private var geoCandidates: [Candidate] {
        candidates.filter { $0.result.latitude != nil && $0.result.longitude != nil }
    }

    // MARK: Sections

    private var contextSection: some View {
        Section("Transaction") {
            LabeledContent("Libellé bancaire") {
                Text(row.rawLabel)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Montant") {
                Text(row.amount, format: .currency(code: "EUR"))
                    .foregroundStyle(row.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
            }
            LabeledContent("Date") {
                Text(row.date, format: .dateTime.day().month(.wide).year())
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
        }
    }

    private var querySection: some View {
        Section {
            TextField("Texte à rechercher", text: $query, axis: .vertical)
                .lineLimit(1...3)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.none)
            TextField("Code postal (optionnel)", text: $postalCode)
                .keyboardType(.numberPad)
            if query != row.rawLabel {
                Button {
                    query = row.rawLabel
                } label: {
                    Label("Rétablir le libellé brut", systemImage: "arrow.uturn.backward")
                        .font(.caption)
                }
            }
        } header: { Text("Recherche personnalisée") }
        footer: {
            Text("La recherche utilise le libellé bancaire tel quel (les codes pays et noms de ville aident l'IA). Tu peux l'affiner si nécessaire.")
        }
    }

    private var sourcesSection: some View {
        Section {
            Toggle("Sources entreprises (registres)", isOn: $useSirene)
            Toggle("Apple Maps (POI)", isOn: $useMapKit)
            Toggle("Foundation Models (IA on-device)", isOn: $useLLM)
                .disabled(!Self.isFoundationModelsAvailable)
            Button {
                Task { await runSearch() }
            } label: {
                if isSearching {
                    HStack { ProgressView().controlSize(.small); Text("Recherche en cours…") }
                } else {
                    Label("Chercher", systemImage: "magnifyingglass")
                }
            }
            .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty
                      || (!useSirene && !useMapKit && !useLLM))
        } header: { Text("Sources") }
        footer: {
            if !Self.isFoundationModelsAvailable {
                Text("Foundation Models requiert iOS 26+. Sur cet appareil, IA on-device indisponible.")
            }
        }
    }

    /// Map interactive : pins pour chaque candidat geo-localisable, tap = sélection.
    /// La sélection scrolle la liste vers le candidat correspondant.
    private var mapSection: some View {
        Section {
            Map(position: $cameraPosition, selection: $selectedCandidateId) {
                ForEach(geoCandidates) { candidate in
                    if let lat = candidate.result.latitude,
                       let lon = candidate.result.longitude {
                        Marker(
                            candidate.result.displayName ?? "?",
                            systemImage: Self.markerIcon(for: candidate.source),
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        )
                        .tint(Self.markerColor(for: candidate.source))
                        .tag(candidate.id)
                    }
                }
            }
            .frame(height: 220)
            .cornerRadius(8)
        } header: {
            Text("Carte (\(geoCandidates.count) lieux)")
        } footer: {
            Text("Tape un pin pour mettre en surbrillance le candidat dans la liste ci-dessous.")
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        if isSearching {
            Section("Recherche en cours…") {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonCandidateRow()
                }
            }
        } else if candidates.isEmpty {
            Section {
                ContentUnavailableView(
                    "Aucun résultat",
                    systemImage: "magnifyingglass",
                    description: Text("Aucune source n'a trouvé de correspondance. Essaie de simplifier la recherche.")
                )
            }
        } else {
            Section("Résultats (\(candidates.count))") {
                ForEach(candidates) { candidate in
                    Button {
                        onApply(candidate.result)
                        dismiss()
                    } label: {
                        candidateRow(candidate)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        candidate.id == selectedCandidateId
                        ? AppTheme.Colors.accent.opacity(0.12)
                        : Color.clear
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ c: Candidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            sourceBadge(c.source)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.result.displayName ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                // Adresse complète : c'est le distinguisher principal quand 2 résultats
                // partagent le même displayName (ex. 2 Boulangerie X à des endroits différents).
                if let addr = c.result.address, !addr.isEmpty {
                    Text(addr)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
                // Ville/pays uniquement si pas déjà dans l'adresse, pour éviter la redondance.
                if let locality = locationSummary(for: c.result) {
                    Text(locality)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
                if let siret = c.result.siret {
                    Text("SIRET \(siret)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
            }
            Spacer()
            Text("\(Int(c.result.confidence * 100))%")
                .font(.caption2.bold())
                .foregroundStyle(AppTheme.Colors.textSecondary)
        }
        .padding(.vertical, 4)
    }

    private func sourceBadge(_ s: MerchantEnrichmentSource) -> some View {
        let (label, icon, color) = Self.style(for: s)
        return VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
            Text(label)
                .font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(width: 56)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(color)
    }

    // MARK: Helpers

    /// Ligne tertiaire "Ville · FR" si non déjà présente dans l'adresse principale.
    private func locationSummary(for r: MerchantEnrichment) -> String? {
        var parts: [String] = []
        let addr = (r.address ?? "").lowercased()
        if let c = r.city, !c.isEmpty, !addr.contains(c.lowercased()) {
            parts.append(c)
        }
        if let cc = r.country, !cc.isEmpty { parts.append(cc.uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static var isFoundationModelsAvailable: Bool {
        EnrichmentLLMService.shared.isAvailable
    }

    private static func style(for s: MerchantEnrichmentSource) -> (String, String, Color) {
        switch s {
        case .sirene:  return ("SIRENE", "building.2.fill", .blue)
        case .mapkit:  return ("MAPS",   "map.fill",        .green)
        case .llm:     return ("IA",     "sparkles",        .purple)
        case .merged:  return ("FUSION", "circle.grid.cross.fill", AppTheme.Colors.accent)
        case .manual:  return ("MANUEL", "hand.point.up.fill", .orange)
        }
    }

    private static func markerIcon(for s: MerchantEnrichmentSource) -> String {
        switch s {
        case .sirene:  return "building.2.fill"
        case .mapkit:  return "mappin.circle.fill"
        case .llm:     return "sparkles"
        default:       return "mappin"
        }
    }

    private static func markerColor(for s: MerchantEnrichmentSource) -> Color {
        switch s {
        case .sirene:  return .blue
        case .mapkit:  return .green
        case .llm:     return .purple
        default:       return .red
        }
    }

    // MARK: Search

    private func runSearch() async {
        isSearching = true
        defer {
            isSearching = false
            hasSearched = true
        }
        candidates.removeAll()
        selectedCandidateId = nil

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pc = postalCode.trimmingCharacters(in: .whitespaces)

        var collected: [Candidate] = []

        if useSirene {
            // Dispatch sur toutes les sources d'entreprises actives.
            // Le registry filtre par pays automatiquement ; ici on passe nil (l'enrichment
            // sheet est utilisée hors contexte form, donc on essaie toutes les sources
            // globales — Sirene apparaitra si pays FR détecté ou non filtré).
            let results = await CompanyDataSourcesRegistry.shared.search(
                query: trimmedQuery,
                country: nil,
                postalCode: pc.count == 5 ? pc : nil
            )
            for enrichment in results {
                collected.append(Candidate(source: enrichment.source, result: enrichment))
            }
        }

        if useMapKit {
            // MapKit : pas de region constraint, le user peut chercher partout dans le monde.
            // Si la query contient "HA GIANG", il trouvera les POI là-bas.
            let mapResults = await MapKitSearchService.searchAll(
                query: trimmedQuery, near: nil, limit: 8
            )
            for map in mapResults {
                var fixed = map
                fixed.displayName = (fixed.displayName ?? trimmedQuery).titleCased
                collected.append(Candidate(source: .mapkit, result: fixed))
            }
        }

        if useLLM {
            // IMPORTANT : on donne au LLM le LIBELLÉ BRUT ORIGINAL (row.rawLabel) comme
            // source de vérité — il contient les indices géographiques (codes pays, villes)
            // que la query custom ou le canonical du moteur ont pu perdre.
            // La query custom (si modifiée) est passée comme "canonicalName" = hypothèse.
            let userHasEdited = trimmedQuery != row.rawLabel
            let context = MerchantEnrichmentContext(
                rawLabel: row.rawLabel,
                canonicalName: userHasEdited ? trimmedQuery : nil,
                amount: row.amount,
                city: nil,    // surtout pas de bias : on veut que le LLM trouve depuis le libellé
                country: nil,
                engineMerchantId: nil
            )
            if let llm = await EnrichmentLLMService.shared.identify(context: context) {
                var fixed = llm
                fixed.displayName = (fixed.displayName ?? trimmedQuery).titleCased
                collected.append(Candidate(source: .llm, result: fixed))
            }
        }

        // Tri par confidence décroissante, puis par source (Sirene en premier en cas d'égalité).
        collected.sort { lhs, rhs in
            if lhs.result.confidence != rhs.result.confidence {
                return lhs.result.confidence > rhs.result.confidence
            }
            return Self.sourceRank(lhs.source) < Self.sourceRank(rhs.source)
        }
        candidates = collected
        // Recadre la map sur les nouveaux pins (si on a des coords).
        if !geoCandidates.isEmpty {
            cameraPosition = .automatic
        }
    }

    private static func sourceRank(_ s: MerchantEnrichmentSource) -> Int {
        switch s {
        case .sirene: return 0
        case .mapkit: return 1
        case .llm:    return 2
        default:      return 3
        }
    }

    // MARK: Model

    private struct Candidate: Identifiable {
        let id = UUID()
        let source: MerchantEnrichmentSource
        let result: MerchantEnrichment
    }
}
