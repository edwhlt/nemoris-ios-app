import SwiftUI
import MapKit
import NemorisEngine

/// Per-row enrichment sheet.
///
/// For an unresolved `ImportSessionRow`, the user can:
///   - customize the search query (the rawLabel is rarely perfect)
///   - choose which sources to query (Sirene / Apple Maps / Foundation Models AI)
///   - see ALL candidates side by side (with a source badge) and pick one
///
/// The chosen result is passed via `onApply`, which sets it on the ViewModel's row
/// (`assignedPayeeName`, `assignedCategoryId`, etc.) and marks the row `.manuallySet`.
struct EnrichmentSheetView: View {
    @Environment(\.dismiss) private var dismiss

    let row: ImportSessionRow
    let onApply: (MerchantEnrichment) -> Void

    @State private var query: String
    @State private var postalCode: String = ""
    @State private var useSirene: Bool = true
    @State private var useMapKit: Bool = true
    @State private var useLLM: Bool = false   // off by default: sometimes generates noise
    @State private var isSearching: Bool = false
    @State private var hasSearched: Bool = false
    @State private var candidates: [SearchCandidate] = []
    @State private var selectedCandidateId: UUID? = nil
    @State private var cameraPosition: MapCameraPosition = .automatic
    /// Structured registry result: the plan, the attempts actually run, and
    /// ranked companies with their establishments. Kept separate from `candidates`, which
    /// stays the flat list of map and AI sources.
    @State private var searchResult: MerchantSearchResult? = nil
    /// Map pins derived from the registry's geolocated establishments
    /// (see `MerchantSearchResult.establishmentPins`, the path shared by all 3 screens).
    @State private var sireneGeoCandidates: [SearchCandidate] = []

    init(row: ImportSessionRow, onApply: @escaping (MerchantEnrichment) -> Void) {
        self.row = row
        self.onApply = onApply
        // Priority to the RAW LABEL — the engine's canonical form often loses the
        // geographic clues (e.g. "VNPAY HUNG RES PSC VN P HA GIANG" → "vnpay" with no VN or HA GIANG).
        _query = State(initialValue: row.rawLabel)
        _useLLM = State(initialValue: AIEnrichmentBackend.isAvailable(for: .merchantEnrichment))
    }

    var body: some View {
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
            // `.paneChrome` draws its own bars on macOS-sheet — the
            // native toolbar lets the user's desktop show
            // through. See the `macSheetChrome` comment
            // in AdaptivePane.swift.
            .paneChrome("Enrichir cette ligne", cancelLabel: "Fermer", onCancel: { dismiss() })
    }

    /// Candidates with GPS coordinates (usable on the map).
    private var geoCandidates: [SearchCandidate] {
        candidates.filter { $0.result.latitude != nil && $0.result.longitude != nil }
            + sireneGeoCandidates
    }

    /// Establishment pin currently selected on the map (nil if the
    /// selection is a MapKit/AI candidate, already covered by the list).
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

    /// Explains why the AI toggle is grayed out. `nil` when it's
    /// available (nothing to explain).
    ///
    /// The reason comes from the dispatch point, the only place that knows
    /// this feature's effective backend — duplicating it here would make it
    /// diverge as soon as a new backend is added (which just happened with cloud).
    private static var aiUnavailableFooter: String? {
        AIEnrichmentBackend.unavailabilityReason(for: .merchantEnrichment)
    }

    // MARK: Search plan and registry results

    /// What the planner stripped from the name, and what it actually tried.
    @ViewBuilder
    private var planSection: some View {
        if let searchResult, !isSearching {
            Section {
                DroppedTokenChips(extraction: searchResult.plan.extraction) { token in
                    // Re-injects the token into the query and re-runs: this is the
                    // visible correction loop, preferable to an opaque AI step.
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

    /// Companies found, expandable into their establishments.
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
                // `matching_etablissements` only returns branches whose name matches
                // the query. Saying so avoids implying an exhaustive list.
                Text("Déplie une entreprise pour voir les établissements correspondant au nom recherché. C'est l'adresse qui distingue la bonne boutique.")
            }
        }
    }

    private func apply(_ enrichment: MerchantEnrichment) {
        var result = enrichment
        // This view doesn't have the category reference data at hand: we pass the
        // category NAME inferred from the NAF code, and the orchestrator resolves it into a
        // `category_id` (same `categoryHint` mechanism as for the AI-proposed category).
        if result.categoryId == nil, let naf = result.nafCode,
           let category = NAFCategoryMapper.shared.lookup(naf) {
            result.categoryHint = category.category
        }
        onApply(result)
        dismiss()
    }

    /// Interactive map: pins for each geolocatable candidate, tap = select.
    /// Selecting scrolls the list to the matching candidate.
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

            // An ESTABLISHMENT pin has no row in the list (companies
            // live in companiesSection) — and `apply` closes the sheet, so no
            // auto-apply on tap: the choice goes through this explicit button.
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

    private func establishmentBadge(_ label: LocalizedStringKey, color: Color) -> some View {
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
                // Full address: this is the main distinguisher when 2 results
                // share the same displayName (e.g. 2 different "Bakery X" locations).
                if let addr = c.result.address, !addr.isEmpty {
                    Text(addr)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.textSecondary)
                        .lineLimit(2)
                }
                // City/country only if not already in the address, to avoid redundancy.
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

    /// Tertiary line "City · FR" if not already present in the main address.
    private func locationSummary(for r: MerchantEnrichment) -> String? {
        var parts: [String] = []
        let addr = (r.address ?? "").lowercased()
        if let c = r.city, !c.isEmpty, !addr.contains(c.lowercased()) {
            parts.append(c)
        }
        if let cc = r.country, !cc.isEmpty { parts.append(cc.uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func style(for s: MerchantEnrichmentSource) -> (LocalizedStringKey, String, Color) {
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
            // goes through the planner + the cascade executor.
            //
            // Previously, the whole query (so the raw label with its city and its
            // codes) went into the registry's `q=`. But the API matches `q` against
            // the company name and trade names, NEVER against the address: putting the
            // city in doesn't restrict the search, it makes it fail.
            //
            // `userQueryOverride` is only set if the user REALLY edited
            // the field. Otherwise we let the planner split the raw label, which it
            // does far better than a string copied as-is.
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
            // No resolveCategory here: this view doesn't have the category
            // reference data — `apply()` passes the NAF as `categoryHint`.
            sireneGeoCandidates = result.establishmentPins()
        }

        if useMapKit {
            // MapKit: no region constraint, the user can search anywhere in the world.
            // If the query contains "HA GIANG", it will find POIs there.
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
            // IMPORTANT: we give the LLM the ORIGINAL RAW LABEL (row.rawLabel) as
            // the source of truth — it carries the geographic clues (country codes, cities)
            // that the custom query or the engine's canonical form may have lost.
            // The custom query (if changed) is passed as "canonicalName" = a hypothesis.
            let userHasEdited = trimmedQuery != row.rawLabel
            let context = MerchantEnrichmentContext(
                rawLabel: row.rawLabel,
                canonicalName: userHasEdited ? trimmedQuery : nil,
                amount: row.amount,
                city: nil,    // definitely no bias: we want the LLM to find it from the label
                country: nil,
                engineMerchantId: nil
            )
            if let llm = await AIEnrichmentBackend.identify(context: context) {
                var fixed = llm
                fixed.displayName = (fixed.displayName ?? trimmedQuery).titleCased
                collected.append(SearchCandidate(source: llm.source, result: fixed))
            }
        }

        // Sorted by decreasing confidence, then by source (Sirene first on a tie).
        collected.sort { lhs, rhs in
            if lhs.result.confidence != rhs.result.confidence {
                return lhs.result.confidence > rhs.result.confidence
            }
            return Self.sourceRank(lhs.source) < Self.sourceRank(rhs.source)
        }
        candidates = collected
        // Recenters the map on the new pins (if we have coordinates).
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
