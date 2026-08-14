import SwiftUI
import MapKit
import NemorisEngine

/// Sheet d'enrichissement par ligne.
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
    @State private var candidates: [SearchCandidate] = []
    @State private var selectedCandidateId: UUID? = nil
    @State private var cameraPosition: MapCameraPosition = .automatic
    /// résultat structuré du registre : plan, tentatives réellement exécutées,
    /// entreprises classées avec leurs établissements. Séparé de `candidates`, qui reste
    /// la liste plate des sources cartographiques et IA.
    @State private var searchResult: MerchantSearchResult? = nil
    /// Pins de carte dérivés des établissements géolocalisés du registre
    /// (cf. `MerchantSearchResult.establishmentPins`, chemin partagé des 3 écrans).
    @State private var sireneGeoCandidates: [SearchCandidate] = []

    init(row: ImportSessionRow, onApply: @escaping (MerchantEnrichment) -> Void) {
        self.row = row
        self.onApply = onApply
        // Priorité au RAW LABEL — le canonical du moteur perd souvent les indices
        // géographiques (ex. "VNPAY HUNG RES PSC VN P HA GIANG" → "vnpay" sans VN ni HA GIANG).
        _query = State(initialValue: row.rawLabel)
        _useLLM = State(initialValue: AIEnrichmentBackend.isAvailable(for: .merchantEnrichment))
    }

    var body: some View {
        NavigationStack {
            Form {
                contextSection
                querySection
                sourcesSection
                if hasSearched {
                    planSection
                    companiesSection
                    if !geoCandidates.isEmpty {
                        mapSection
                    }
                    resultsSection
                }
            }
            .nemorisFormStyle()
            .navigationTitle("Enrichir cette ligne")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label("Fermer", systemImage: "xmark")
                    }
                }
            }
        }
    }

    /// Candidats ayant des coordonnées GPS (utilisable sur la map).
    private var geoCandidates: [SearchCandidate] {
        candidates.filter { $0.result.latitude != nil && $0.result.longitude != nil }
            + sireneGeoCandidates
    }

    /// Pin établissement actuellement sélectionné sur la carte (nil si la
    /// sélection est un candidat MapKit/IA, déjà couvert par la liste).
    private var selectedEstablishmentPin: SearchCandidate? {
        guard let selectedCandidateId else { return nil }
        return sireneGeoCandidates.first { $0.id == selectedCandidateId }
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
            Toggle("Intelligence artificielle", isOn: $useLLM)
                .disabled(!AIEnrichmentBackend.isAvailable(for: .merchantEnrichment))
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
            if let message = Self.aiUnavailableFooter {
                Text(message)
            }
        }
    }

    /// Explique pourquoi le toggle IA est grisé. `nil` quand elle est
    /// disponible (rien à expliquer).
    ///
    /// Le motif vient du point de dispatch, qui est le seul à connaître le
    /// backend effectif de cette fonctionnalité — le dupliquer ici le ferait
    /// diverger dès l'ajout d'un backend (ce qui vient d'arriver avec le cloud).
    private static var aiUnavailableFooter: String? {
        AIEnrichmentBackend.unavailabilityReason(for: .merchantEnrichment)
    }

    // MARK: Plan de recherche et résultats du registre

    /// Ce que le planificateur a retiré du nom, et ce qu'il a réellement tenté.
    @ViewBuilder
    private var planSection: some View {
        if let searchResult, !isSearching {
            Section {
                DroppedTokenChips(extraction: searchResult.plan.extraction) { token in
                    // Réinjecte le jeton dans la requête et relance : c'est la boucle de
                    // correction visible, préférable à une étape IA opaque.
                    let base = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    query = base.isEmpty ? token : "\(base) \(token)"
                    Task { await runSearch() }
                }
                SearchDetailsDisclosure(result: searchResult)
            } header: {
                Text("Plan de recherche")
            }
        }
    }

    /// Entreprises trouvées, dépliables vers leurs établissements.
    @ViewBuilder
    private var companiesSection: some View {
        if let searchResult, !searchResult.companies.isEmpty, !isSearching {
            Section {
                ForEach(searchResult.companies) { ranked in
                    CompanyMatchRow(
                        ranked: ranked,
                        initiallyExpanded: ranked.id == searchResult.companies.first?.id,
                        onPickCompany: { match in
                            apply(match.enrichment(for: nil, confidence: ranked.score))
                        },
                        onPickEstablishment: { match, establishment in
                            apply(match.enrichment(for: establishment, confidence: ranked.score))
                        }
                    )
                }
            } header: {
                Text("Entreprises (\(searchResult.companies.count))")
            } footer: {
                // `matching_etablissements` ne renvoie que les branches dont le nom matche
                // la requête. Le dire évite de laisser croire à une liste exhaustive.
                Text("Déplie une entreprise pour voir les établissements correspondant au nom recherché. C'est l'adresse qui distingue la bonne boutique.")
            }
        }
    }

    private func apply(_ enrichment: MerchantEnrichment) {
        var result = enrichment
        // Cette vue n'a pas le référentiel de catégories sous la main : on transmet le NOM
        // de catégorie déduit du code NAF, et l'orchestrateur le résout en `category_id`
        // (même mécanisme `categoryHint` que pour la catégorie proposée par l'IA).
        if result.categoryId == nil, let naf = result.nafCode,
           let category = NAFCategoryMapper.shared.lookup(naf) {
            result.categoryHint = category.category
        }
        onApply(result)
        dismiss()
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

            // Un pin ÉTABLISSEMENT n'a pas de row dans la liste (les entreprises
            // vivent dans companiesSection) — et `apply` ferme la sheet, donc pas
            // d'auto-apply au tap : le choix passe par ce bouton explicite.
            if let pin = selectedEstablishmentPin {
                Button {
                    apply(pin.result)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "storefront.fill")
                            .foregroundStyle(AppTheme.Colors.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Utiliser cet établissement")
                                    .font(.subheadline.weight(.semibold))
                                if pin.establishment?.isHeadquarters == true {
                                    establishmentBadge("Siège", color: AppTheme.Colors.accent)
                                }
                                if pin.establishment?.isActive == false {
                                    establishmentBadge("Fermé", color: AppTheme.Colors.danger)
                                }
                            }
                            if let addr = pin.result.address, !addr.isEmpty {
                                Text(addr)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.textSecondary)
                                    .lineLimit(2)
                            }
                            if let siret = pin.result.siret {
                                Text("SIRET \(siret)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Carte (\(geoCandidates.count) lieux)")
        } footer: {
            Text("Tape un pin pour le sélectionner — un établissement propose un bouton d'application, un candidat Maps/IA est mis en surbrillance dans la liste.")
        }
    }

    private func establishmentBadge(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private var resultsSection: some View {
        if isSearching {
            Section("Recherche en cours…") {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonCandidateRow()
                }
            }
        } else if candidates.isEmpty && (searchResult?.companies.isEmpty ?? true) {
            Section {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Aucun résultat",
                    message: "Aucune source n'a trouvé de correspondance. Déplie « Détails de la recherche » pour voir ce qui a été tenté, ou réintègre un élément retiré du nom."
                )
            }
        } else if candidates.isEmpty {
            EmptyView()
        } else {
            Section("Autres sources (\(candidates.count))") {
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
    private func candidateRow(_ c: SearchCandidate) -> some View {
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

    private static func style(for s: MerchantEnrichmentSource) -> (String, String, Color) {
        switch s {
        case .sirene:   return ("SIRENE", "building.2.fill", .blue)
        case .mapkit:   return ("MAPS",   "map.fill",        .green)
        case .llm:      return ("IA",     "sparkles",        .purple)
        case .localLLM: return ("LOCAL",  "server.rack",     .teal)
        case .cloudLLM: return ("CLOUD", "cloud", .indigo)
        case .merged:   return ("FUSION", "circle.grid.cross.fill", AppTheme.Colors.accent)
        case .manual:   return ("MANUEL", "hand.point.up.fill", .orange)
        }
    }

    private static func markerIcon(for s: MerchantEnrichmentSource) -> String {
        switch s {
        case .sirene:   return "building.2.fill"
        case .mapkit:   return "mappin.circle.fill"
        case .llm:      return "sparkles"
        case .localLLM: return "server.rack"
        case .cloudLLM: return "cloud"
        default:        return "mappin"
        }
    }

    private static func markerColor(for s: MerchantEnrichmentSource) -> Color {
        switch s {
        case .sirene:   return .blue
        case .mapkit:   return .green
        case .llm:      return .purple
        case .localLLM: return .teal
        default:        return .red
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
        searchResult = nil
        sireneGeoCandidates = []
        selectedCandidateId = nil

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pc = postalCode.trimmingCharacters(in: .whitespaces)

        var collected: [SearchCandidate] = []

        if useSirene {
            // passe par le planificateur + l'exécuteur de cascade.
            //
            // Avant, la requête entière (donc le libellé brut avec sa ville et ses codes)
            // partait dans le `q=` du registre. Or l'API matche `q` contre la raison
            // sociale et les enseignes, JAMAIS contre l'adresse : y mettre la ville ne
            // restreint pas la recherche, elle la fait échouer.
            //
            // `userQueryOverride` n'est renseigné que si l'utilisateur a RÉELLEMENT édité
            // le champ. Sinon on laisse le planificateur découper le libellé brut, ce
            // qu'il fait bien mieux qu'une chaîne recopiée telle quelle.
            let userEdited = trimmedQuery != row.rawLabel
            let input = MerchantQueryPlanner.Input(
                rawLabel: row.rawLabel,
                userPostalCode: pc.count == 5 ? pc : nil,
                userQueryOverride: userEdited ? trimmedQuery : nil
            )
            let result = await MerchantQueryExecutor.shared.search(
                input: input,
                budget: .interactive,
                knownNafPrefixes: NAFCategoryMapper.shared.knownPrefixes
            )
            searchResult = result
            // Pas de resolveCategory ici : cette vue n'a pas le référentiel de
            // catégories — `apply()` transmet le NAF en `categoryHint`.
            sireneGeoCandidates = result.establishmentPins()
        }

        if useMapKit {
            // MapKit : pas de region constraint, l'utilisateur peut chercher partout dans le monde.
            // Si la query contient "HA GIANG", il trouvera les POI là-bas.
            let mapResults = await MapKitSearchService.searchAll(
                query: trimmedQuery, near: nil, limit: 8
            )
            for map in mapResults {
                var fixed = map
                fixed.displayName = (fixed.displayName ?? trimmedQuery).titleCased
                collected.append(SearchCandidate(source: .mapkit, result: fixed))
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
            if let llm = await AIEnrichmentBackend.identify(context: context) {
                var fixed = llm
                fixed.displayName = (fixed.displayName ?? trimmedQuery).titleCased
                collected.append(SearchCandidate(source: llm.source, result: fixed))
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
        case .sirene:            return 0
        case .mapkit:            return 1
        case .llm, .localLLM:    return 2
        default:                 return 3
        }
    }

}
