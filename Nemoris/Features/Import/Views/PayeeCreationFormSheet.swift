import SwiftUI
import MapKit
import NemorisEngine

/// Fiche de création complète d'un nouveau tier depuis une row d'import.
///
/// Tous les champs sont éditables d'entrée. La section **"Aide à l'identification"**
/// est repliable en bas — si l'utilisateur ne se souvient pas du marchand, il peut
/// chercher dans Sirene / Apple Maps / IA on-device et tap un candidat pour pré-remplir
/// les champs au-dessus (sans appliquer aveuglément).
///
/// Carte interactive avec bouton plein écran (`EnrichmentMapFullscreenSheet`) qui
/// permet de pan/zoom et de relancer une recherche depuis la zone visible.
struct PayeeCreationFormSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Row d'import source — nil quand le formulaire est utilisé hors import (ex: création
    /// de tiers depuis TransactionEditSheet / TransactionCreateSheet / ReferenceDataView).
    let row: ImportSessionRow?
    let allCategories: [Category]
    let onCreate: (Tiers) -> Void   // tier prêt à insérer (id=0 placeholder)

    // Form fields
    @State private var name: String
    @State private var regex: String
    @State private var domain: String
    @State private var city: String
    @State private var country: String
    @State private var address: String
    @State private var engineMerchantId: String
    @State private var categoryId: Int?
    @State private var groupId: Int?
    @State private var custom: Bool = false
    @State private var note: String = ""

    // Search helper (collapsed by default)
    @State private var showSearchHelper: Bool = false
    @State private var searchQuery: String
    @State private var searchPostalCode: String = ""
    @State private var useSirene: Bool = true
    @State private var useMapKit: Bool = true
    @State private var useLLM: Bool = false
    @State private var isSearching: Bool = false
    @State private var hasSearched: Bool = false
    @State private var candidates: [SearchCandidate] = []
    /// résultat structuré du registre (plan + entreprises + établissements),
    /// distinct de `candidates` qui reste la liste plate des sources carto et IA.
    @State private var searchResult: MerchantSearchResult? = nil
    /// Pins de carte dérivés des établissements géolocalisés du registre.
    /// Séparés de `candidates` : les y injecter dupliquerait `companiesList`
    /// dans la liste des résultats — ils n'existent que pour la carte.
    @State private var sireneGeoCandidates: [SearchCandidate] = []
    @State private var selectedCandidateId: UUID? = nil
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showFullscreenMap: Bool = false

    // Groups (pour picker)
    @State private var payeeGroups: [PayeeGroup] = []
    @State private var showGroupPicker = false

    /// Toast affiché brièvement quand l'IA / Sirene applique automatiquement
    /// des métadonnées sur le formulaire (ville/pays/catégorie).
    @State private var autoApplyFeedback: String? = nil

    private let repository = TransactionRepository()

    // MARK: - Init depuis import (avec row)

    init(row: ImportSessionRow,
         allCategories: [Category],
         onCreate: @escaping (Tiers) -> Void) {
        self.row = row
        self.allCategories = allCategories
        self.onCreate = onCreate
        let cand = InitialCandidate(row: row)
        _name             = State(initialValue: cand.name)
        _regex            = State(initialValue: cand.regex)
        _domain           = State(initialValue: cand.domain)
        _city             = State(initialValue: cand.city)
        _country          = State(initialValue: cand.country)
        _address          = State(initialValue: "")
        _engineMerchantId = State(initialValue: cand.engineMerchantId)
        _categoryId       = State(initialValue: cand.categoryId)
        _searchQuery      = State(initialValue: row.rawLabel)
        _useLLM           = State(initialValue: AIEnrichmentBackend.isAvailable(for: .merchantEnrichment))
    }

    // MARK: - Init standalone (sans import)

    /// Init simplifié pour la création de tiers hors contexte d'import.
    /// Utilisé par TransactionEditSheet, TransactionCreateSheet, ReferenceDataView, etc.
    init(prefilledName: String = "",
         prefilledCategoryId: Int? = nil,
         allCategories: [Category],
         onCreate: @escaping (Tiers) -> Void) {
        self.row = nil
        self.allCategories = allCategories
        self.onCreate = onCreate
        _name             = State(initialValue: prefilledName)
        _regex            = State(initialValue: "")
        _domain           = State(initialValue: "")
        _city             = State(initialValue: "")
        _country          = State(initialValue: "")
        _address          = State(initialValue: "")
        _engineMerchantId = State(initialValue: "")
        _categoryId       = State(initialValue: prefilledCategoryId)
        _searchQuery      = State(initialValue: prefilledName)
        _useLLM           = State(initialValue: AIEnrichmentBackend.isAvailable(for: .merchantEnrichment))
    }

    var body: some View {
            Form {
                contextSection
                identitySection
                classificationSection
                localizationSection
                advancedSection
                searchHelperSection
            }
            .nemorisFormStyle()
            // `.paneChrome` dessine ses propres barres sur macOS-sheet — un
            // `NavigationStack`+`.toolbar` natif laisse le bureau de
            // l'utilisateur transparaître au travers du titre ET des boutons
            // (retour d'usage 2026-08-21, capture "New Payee"). Cf. le
            // commentaire de `macSheetChrome` dans AdaptivePane.swift.
            .paneChrome(
                "Nouveau tier",
                cancelLabel: "Annuler", onCancel: { dismiss() },
                confirmLabel: "Créer", confirmIcon: "plus",
                confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty,
                onConfirm: {
                    onCreate(buildPayee())
                    dismiss()
                }
            )
            // Cf. CLAUDE.md §5 : ré-injection \.locale obligatoire pour toute
            // `.sheet()` niveau 2+ atteignable sur macOS. `\.paneHostContext`
            // itou : cette fiche est elle-même atteinte via un `.sheet()`
            // ouvert depuis l'inspecteur (`ImportSessionView`), donc hérite
            // `.inspector` — sans reset à `.modal`, le `.paneChrome` de la
            // vue présentée ici publierait ses boutons dans la barre système
            // au lieu de les dessiner dans cette fenêtre séparée.
            .sheet(isPresented: $showGroupPicker) {
                PayeeGroupPickerView(currentGroupId: groupId) { group in
                    groupId = group?.id
                }
                .environment(\.locale, AppLocalization.locale)
                .environment(\.paneHostContext, .modal)
            }
            .sheet(isPresented: $showFullscreenMap) {
                EnrichmentMapFullscreenSheet(
                    initialQuery: searchQuery,
                    initialCandidates: candidates.filter { $0.result.latitude != nil }
                        + sireneGeoCandidates
                ) { picked in
                    applyCandidate(picked)
                }
                .environment(\.locale, AppLocalization.locale)
                .environment(\.paneHostContext, .modal)
            }
            // Tap sur un pin ÉTABLISSEMENT de la mini-carte → pré-remplit la fiche
            // (les pins Sirene ne sont pas dans `resultsList`, le tap-liste ne les
            // couvre donc pas — contrairement aux candidats MapKit/IA).
            .onChange(of: selectedCandidateId) { _, newValue in
                guard let newValue,
                      let pin = sireneGeoCandidates.first(where: { $0.id == newValue }) else { return }
                applyCandidate(pin)
            }
            .overlay(alignment: .top) {
                if let feedback = autoApplyFeedback {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(AppTheme.Colors.accent)
                        Text(feedback)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.textPrimary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(AppTheme.Colors.accent.opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .task {
                if payeeGroups.isEmpty { payeeGroups = repository.fetchPayeeGroups() }
            }
    }

    // MARK: - Sections

    @ViewBuilder
    private var contextSection: some View {
        if let row {
            Section {
                HStack(spacing: 12) {
                    MerchantLogo(domain: domain.nilIfEmpty,
                                 engineMerchantId: engineMerchantId.nilIfEmpty,
                                 fallbackIcon: allCategories.first(where: { $0.id == categoryId })?.displayIcon,
                                 size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Création depuis import").font(.caption.bold()).foregroundStyle(AppTheme.Colors.textSecondary)
                        Text(row.rawLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(AppTheme.Colors.textSecondary)
                            .lineLimit(2)
                        Text(row.amount, format: .currency(code: "EUR"))
                            .font(.caption.bold())
                            .foregroundStyle(row.amount < 0 ? AppTheme.Colors.danger : AppTheme.Colors.success)
                    }
                    Spacer()
                }
            }
        }
    }

    private var identitySection: some View {
        Section("Identité") {
            TextField("Nom du tier", text: $name)
                .autocorrectionDisabled()
            Toggle("Tier personnalisé (sans lien moteur)", isOn: $custom)
                .font(.caption)
        }
    }

    private var classificationSection: some View {
        Section {
            Picker("Catégorie", selection: $categoryId) {
                Text("Aucune").tag(Int?.none)
                ForEach(allCategories) { c in
                    Label(c.name, systemImage: c.displayIcon).tag(Int?.some(c.id))
                }
            }
            TextField("Domaine web (pour le logo)", text: $domain)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            VStack(alignment: .leading, spacing: 4) {
                Text("Regex de détection").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                TextEditor(text: $regex)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .frame(minHeight: 60)
            }
        } header: {
            Text("Catégorisation")
        } footer: {
            Text("La regex pré-remplie matche le libellé exact. Ajoute |…|… pour gérer d'autres variantes.")
        }
    }

    private var localizationSection: some View {
        Section("Localisation") {
            TextField("Ville", text: $city)
                .autocorrectionDisabled()
            TextField("Pays (ISO, ex. FR)", text: $country)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .onChange(of: country) { _, newVal in
                    let up = newVal.uppercased()
                    if up != newVal { country = up }
                    if country.count > 2 { country = String(country.prefix(2)) }
                }
            TextField("Adresse", text: $address, axis: .vertical)
                .lineLimit(1...3)
                .autocorrectionDisabled()
        }
    }

    private var advancedSection: some View {
        Section("Avancé") {
            Button {
                showGroupPicker = true
            } label: {
                HStack {
                    Text("Groupe").foregroundStyle(AppTheme.Colors.textPrimary)
                    Spacer()
                    Text(groupId == nil ? "Aucun"
                         : payeeGroups.first(where: { $0.id == groupId })?.displayName ?? "Groupe #\(groupId!)")
                        .foregroundStyle(groupId == nil ? AppTheme.Colors.textSecondary : AppTheme.Colors.accent)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
            }
            TextField("ID moteur (avancé)", text: $engineMerchantId)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
    }

    // MARK: - Search helper (collapsible)

    @ViewBuilder
    private var searchHelperSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showSearchHelper) {
                searchControls
                if hasSearched {
                    planInspector
                    companiesList
                }
                if hasSearched, !geoCandidates.isEmpty {
                    miniMap
                }
                if hasSearched {
                    resultsList
                }
            } label: {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(AppTheme.Colors.accentSecondary)
                    Text("Aide à l'identification").font(.subheadline.bold())
                    Spacer()
                    if hasSearched {
                        Text("\(candidates.count)").font(.caption).foregroundStyle(AppTheme.Colors.textSecondary)
                    }
                }
            }
        } footer: {
            Text("Optionnel : si tu ne te souviens pas du marchand, lance une recherche multi-sources. Tap un candidat pour pré-remplir la fiche au-dessus.")
        }
    }

    @ViewBuilder
    private var searchControls: some View {
        TextField("Texte à rechercher", text: $searchQuery, axis: .vertical)
            .lineLimit(1...3)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.none)
        TextField("Code postal (Sirene)", text: $searchPostalCode)
            .keyboardType(.numberPad)
        Toggle("Sources entreprises (Sirene, Companies House, …)", isOn: $useSirene)
        Toggle("Apple Maps", isOn: $useMapKit)
        Toggle("Intelligence artificielle", isOn: $useLLM)
            .disabled(!AIEnrichmentBackend.isAvailable(for: .merchantEnrichment))
        Button {
            Task { await runSearch() }
        } label: {
            if isSearching {
                HStack { ProgressView().controlSize(.small); Text("Recherche…") }
            } else {
                Label("Lancer la recherche", systemImage: "magnifyingglass")
            }
        }
        .disabled(isSearching || searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
                  || (!useSirene && !useMapKit && !useLLM))
    }

    private var geoCandidates: [SearchCandidate] {
        candidates.filter { $0.result.latitude != nil && $0.result.longitude != nil }
            + sireneGeoCandidates
    }

    @ViewBuilder
    private var miniMap: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Carte (\(geoCandidates.count))").font(.caption.bold()).foregroundStyle(AppTheme.Colors.textSecondary)
                Spacer()
                Button {
                    showFullscreenMap = true
                } label: {
                    Label("Plein écran", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
            }
            Map(position: $cameraPosition, selection: $selectedCandidateId) {
                ForEach(geoCandidates) { candidate in
                    if let lat = candidate.result.latitude,
                       let lon = candidate.result.longitude {
                        // Annotation custom : cercle avec favicon (si domain) ou icône
                        // thématique, bordure colorée par source, pointer en bas.
                        Annotation(
                            candidate.result.displayName ?? "?",
                            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        ) {
                            CandidatePin(
                                source: candidate.source,
                                displayName: candidate.result.displayName,
                                domain: candidate.result.domain,
                                isSelected: candidate.id == selectedCandidateId
                            )
                        }
                        .tag(candidate.id)
                    }
                }
            }
            .frame(height: 180)
            .cornerRadius(8)
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if isSearching {
            VStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { _ in
                    SkeletonCandidateRow()
                }
            }
        } else if candidates.isEmpty {
            Text("Aucun résultat. Affine la recherche.")
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.textSecondary)
        } else {
            VStack(spacing: 0) {
                ForEach(candidates) { candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            applyCandidate(candidate)
                        } label: {
                            candidateRow(candidate)
                        }
                        .buttonStyle(.plain)

                        // Bouton "Affiner Maps" si le LLM propose une requête nettoyée
                        // (ex. "Hung Restaurant Ha Giang" extrait depuis "VNPAY HUNG RES PSC VN P HA GIANG")
                        if candidate.source == .llm,
                           let hint = candidate.result.searchHint,
                           !hint.isEmpty,
                           hint.lowercased() != searchQuery.lowercased() {
                            Button {
                                searchQuery = hint
                                Task { await runSearch() }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "magnifyingglass.circle.fill")
                                        .font(.caption)
                                    Text("Affiner Maps avec « \(hint) »")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(AppTheme.Colors.accent.opacity(0.13), in: Capsule())
                                .foregroundStyle(AppTheme.Colors.accent)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, 60)   // align after sourceBadge
                        }
                    }
                    .padding(.vertical, 4)
                    .background(
                        candidate.id == selectedCandidateId
                        ? AppTheme.Colors.accent.opacity(0.10)
                        : Color.clear
                    )
                    if candidate.id != candidates.last?.id {
                        Divider().padding(.leading, 70)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func candidateRow(_ c: SearchCandidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            sourceBadge(c.source)
            // Look Around thumbnail pour les POI MapKit (aide à reconnaître la devanture).
            // Affiché uniquement quand on a des coords ET que Apple a couvert la zone.
            if c.source == .mapkit,
               let lat = c.result.latitude,
               let lon = c.result.longitude {
                LookAroundThumbnail(
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    size: 56
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(c.result.displayName ?? "—")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textPrimary)
                    .lineLimit(1)
                if let addr = c.result.address, !addr.isEmpty {
                    Text(addr).font(.caption).foregroundStyle(AppTheme.Colors.textSecondary).lineLimit(2)
                }
                if let siret = c.result.siret {
                    Text("SIRET \(siret)").font(.caption2.monospaced()).foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(c.result.confidence * 100))%")
                    .font(.caption2.bold())
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
            }
        }
    }

    private func sourceBadge(_ s: MerchantEnrichmentSource) -> some View {
        let (label, icon, color) = Self.style(for: s)
        return VStack(spacing: 2) {
            Image(systemName: icon).font(.caption.weight(.bold))
            Text(label).font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(width: 50)
        .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(color)
    }

    // MARK: - Apply candidate (fills form, doesn't dismiss)

    // MARK: - plan de recherche et entreprises

    /// Ce qui a été retiré du nom, et ce qui a réellement été tenté.
    @ViewBuilder
    private var planInspector: some View {
        if let searchResult, !isSearching {
            VStack(alignment: .leading, spacing: 10) {
                DroppedTokenChips(extraction: searchResult.plan.extraction) { token in
                    let base = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    searchQuery = base.isEmpty ? token : "\(base) \(token)"
                    Task { await runSearch() }
                }
                SearchDetailsDisclosure(result: searchResult)
            }
            .padding(.vertical, 4)
        }
    }

    /// Entreprises trouvées, dépliables vers leurs établissements.
    /// Contrairement à la sheet de recherche rapide, un tap PRÉ-REMPLIT le formulaire
    /// sans fermer : l'utilisateur reste maître de la fiche qu'il est en train de créer.
    @ViewBuilder
    private var companiesList: some View {
        if let searchResult, !searchResult.companies.isEmpty, !isSearching {
            VStack(alignment: .leading, spacing: 6) {
                Text("Entreprises (\(searchResult.companies.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.Colors.textSecondary)
                ForEach(searchResult.companies) { ranked in
                    CompanyMatchRow(
                        ranked: ranked,
                        initiallyExpanded: ranked.id == searchResult.companies.first?.id,
                        onPickCompany: { match in
                            prefill(from: match.enrichment(for: nil, confidence: ranked.score))
                        },
                        onPickEstablishment: { match, establishment in
                            prefill(from: match.enrichment(for: establishment,
                                                           confidence: ranked.score))
                        }
                    )
                }
                Text("C'est l'adresse de l'établissement qui distingue la bonne boutique d'une enseigne.")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.7))
            }
            .padding(.vertical, 4)
        }
    }

    /// NAF → id de catégorie locale, même logique que `prefill`.
    private var resolveNAFCategory: (String) -> Int? {
        { naf in
            guard let cat = NAFCategoryMapper.shared.lookup(naf) else { return nil }
            return allCategories.first {
                $0.name.localizedCaseInsensitiveCompare(cat.category) == .orderedSame
            }?.id
        }
    }

    /// Remplit les champs du formulaire depuis une entreprise ou un établissement retenu.
    /// Ne remplace que ce qui est vide côté catégorie — le reste est une proposition
    /// explicite de l'utilisateur, donc prioritaire sur ce qu'il avait éventuellement saisi.
    private func prefill(from enrichment: MerchantEnrichment) {
        if let n = enrichment.displayName, !n.isEmpty { name = n }
        if let c = enrichment.city, !c.isEmpty { city = c }
        if let cc = enrichment.country, !cc.isEmpty { country = cc.uppercased() }
        if let addr = enrichment.address, !addr.isEmpty { address = addr }
        if let siret = enrichment.siret, !siret.isEmpty, engineMerchantId.isEmpty {
            engineMerchantId = siret
        }
        if categoryId == nil, let naf = enrichment.nafCode,
           let category = NAFCategoryMapper.shared.lookup(naf) {
            categoryId = allCategories.first {
                $0.name.localizedCaseInsensitiveCompare(category.category) == .orderedSame
            }?.id
        }
    }

    private func applyCandidate(_ c: SearchCandidate) {
        let r = c.result
        if let n = r.displayName, !n.isEmpty { name = n }
        if let d = r.domain, !d.isEmpty { domain = d }
        if let city = r.city, !city.isEmpty { self.city = city }
        if let country = r.country, !country.isEmpty { self.country = country.uppercased() }
        if let addr = r.address, !addr.isEmpty { address = addr }
        if let cid = r.categoryId, categoryId == nil { categoryId = cid }
        if let siret = r.siret, !siret.isEmpty, engineMerchantId.isEmpty {
            engineMerchantId = siret
        }
        selectedCandidateId = c.id
    }

    // MARK: - Build payee for onCreate callback

    private func buildPayee() -> Tiers {
        Tiers(
            id: 0,   // placeholder — le ViewModel set le vrai id après insert
            name: name.trimmingCharacters(in: .whitespaces),
            regex: regex.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            categoryId: categoryId,
            linkedCompteId: nil,
            engineMerchantId: engineMerchantId.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            domain: domain.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            address: address.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            city: city.trimmingCharacters(in: .whitespaces).nilIfEmpty,
            country: country.trimmingCharacters(in: .whitespaces).uppercased().nilIfEmpty,
            groupId: groupId,
            custom: custom,
            note: note.trimmingCharacters(in: .whitespaces).nilIfEmpty
        )
    }

    // MARK: - Search

    private func runSearch() async {
        isSearching = true
        defer { isSearching = false; hasSearched = true }
        candidates.removeAll()
        searchResult = nil
        sireneGeoCandidates = []
        selectedCandidateId = nil

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let pc = searchPostalCode.trimmingCharacters(in: .whitespaces)
        var collected: [SearchCandidate] = []

        if useSirene {
            // planificateur + cascade au lieu d'un `q=` construit depuis le libellé
            // entier. L'API matche `q` contre la raison sociale et les enseignes, jamais
            // contre l'adresse : y laisser la ville faisait échouer la recherche
            // (`q=carrefour market flanches` → 0 ; `q=carrefour market` → 1411).
            let rawLabel = row?.rawLabel ?? trimmedQuery
            let userEdited = trimmedQuery != rawLabel
            let input = MerchantQueryPlanner.Input(
                rawLabel: rawLabel,
                // Le pays et le code postal du formulaire PRIMENT : l'utilisateur les a
                // saisis ou corrigés, ils valent mieux que toute déduction automatique.
                userCountry: country.trimmingCharacters(in: .whitespaces).nilIfEmpty,
                userPostalCode: pc.count == 5 ? pc : nil,
                userQueryOverride: userEdited ? trimmedQuery : nil
            )
            searchResult = await MerchantQueryExecutor.shared.search(
                input: input,
                budget: .interactive,
                knownNafPrefixes: NAFCategoryMapper.shared.knownPrefixes
            )
            sireneGeoCandidates = searchResult?.establishmentPins(resolveCategory: resolveNAFCategory) ?? []
        }

        if useMapKit {
            let mapResults = await MapKitSearchService.searchAll(query: trimmedQuery, near: nil, limit: 8)
            for map in mapResults {
                var fixed = map
                fixed.displayName = (fixed.displayName ?? trimmedQuery).titleCased
                collected.append(SearchCandidate(source: .mapkit, result: fixed))
            }
        }

        if useLLM {
            let rawLabel = row?.rawLabel ?? trimmedQuery
            let userHasEdited = trimmedQuery != rawLabel
            let context = MerchantEnrichmentContext(
                rawLabel: rawLabel,
                canonicalName: userHasEdited ? trimmedQuery : nil,
                amount: row?.amount,
                city: nil, country: nil, engineMerchantId: nil
            )
            if let llm = await AIEnrichmentBackend.identify(context: context) {
                var fixed = llm
                fixed.displayName = (fixed.displayName ?? trimmedQuery).titleCased
                collected.append(SearchCandidate(source: llm.source, result: fixed))
            }
        }

        collected.sort { lhs, rhs in
            if lhs.result.confidence != rhs.result.confidence {
                return lhs.result.confidence > rhs.result.confidence
            }
            return Self.sourceRank(lhs.source) < Self.sourceRank(rhs.source)
        }
        candidates = collected
        if !geoCandidates.isEmpty {
            cameraPosition = .automatic
        }

        // AUTO-APPLY des métadonnées "faciles" sur les champs vides du formulaire,
        // sans attendre que l'utilisateur tape un candidat.
        autoApplyMetadataFromSearch()
    }

    /// Pour chaque source qui a renvoyé un résultat avec confidence > 0.5, applique
    /// city / country / categoryId sur les champs encore vides du formulaire.
    /// L'utilisateur peut toujours surcharger en éditant à la main.
    /// Toast affiché en bas pour signaler ce qui a été rempli.
    private func autoApplyMetadataFromSearch() {
        var applied: [String] = []

        // 1) Re-tente d'abord l'extraction déterministe sur la query éditée par l'utilisateur
        //    (ex. l'utilisateur a copié-collé un meilleur libellé dans le champ recherche).
        let locHit = LocationExtractor.extract(from: searchQuery)
        if country.isEmpty, let c = locHit.country, !c.isEmpty {
            country = c
            applied.append("Pays \(c)")
        }
        if city.isEmpty, let c = locHit.city, !c.isEmpty {
            city = c
            applied.append("Ville \(c)")
        }

        // 2) Pour chaque source avec haute confidence, applique les champs encore vides.
        //    On parcourt par confidence décroissante (candidates est déjà trié).
        for candidate in candidates where candidate.result.confidence >= 0.5 {
            let r = candidate.result
            if country.isEmpty, let c = r.country, !c.isEmpty {
                country = c.uppercased()
                applied.append("Pays \(c.uppercased()) (\(badgeLabel(for: candidate.source)))")
            }
            if city.isEmpty, let c = r.city, !c.isEmpty {
                city = c
                applied.append("Ville \(c) (\(badgeLabel(for: candidate.source)))")
            }
            if categoryId == nil, let cid = r.categoryId {
                categoryId = cid
                applied.append("Catégorie")
            }
            // address / siret seulement depuis Sirene (donnée fiable)
            if candidate.source == .sirene {
                if address.isEmpty, let a = r.address, !a.isEmpty {
                    address = a
                    applied.append("Adresse")
                }
                if engineMerchantId.isEmpty, let s = r.siret, !s.isEmpty {
                    engineMerchantId = s
                    applied.append("SIRET")
                }
            }
            // domain depuis MapKit (item.url) ou si LLM a proposé un domaine
            if domain.isEmpty, let d = r.domain, !d.isEmpty {
                domain = d
                applied.append("Domaine")
            }
        }

        if !applied.isEmpty {
            let msg = "Auto-rempli : \(applied.prefix(4).joined(separator: " · "))"
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                autoApplyFeedback = msg
            }
            // Dismiss après 4s
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                withAnimation { autoApplyFeedback = nil }
            }
        }
    }

    private func badgeLabel(for s: MerchantEnrichmentSource) -> String {
        switch s {
        case .sirene:   return "SIRENE"
        case .mapkit:   return "Maps"
        case .llm:      return "IA"
        case .localLLM: return "LOCAL"
        case .cloudLLM: return "cloud"
        default:        return ""
        }
    }

    // MARK: - Style helpers

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

    private static func sourceRank(_ s: MerchantEnrichmentSource) -> Int {
        switch s {
        case .sirene:         return 0
        case .mapkit:         return 1
        case .llm, .localLLM: return 2
        default:              return 3
        }
    }
}

// MARK: - Candidate model (partagé avec EnrichmentSheetView via le type SearchCandidate)

struct SearchCandidate: Identifiable {
    let id = UUID()
    let source: MerchantEnrichmentSource
    let result: MerchantEnrichment
    /// Renseigné quand le candidat EST un établissement Sirene (pin de carte
    /// issu du drill-down entreprise → établissements). Le modèle reste plat :
    /// `result` porte déjà l'adresse/SIRET/coords de l'établissement via
    /// `CompanyMatch.enrichment(for:)` — ce contexte ne sert qu'aux badges UI.
    var establishment: EstablishmentContext? = nil
}

/// Contexte d'affichage d'un candidat-établissement (badges Siège/Fermé).
struct EstablishmentContext {
    let isHeadquarters: Bool
    let isActive: Bool
    let siren: String
}

extension MerchantSearchResult {
    /// Pins de carte : un candidat par établissement GÉOLOCALISÉ des meilleures
    /// entreprises. Cap 5 entreprises × 8 établissements, 25 pins au total —
    /// une grande enseigne matcherait des centaines de branches et noierait la
    /// carte. CHEMIN UNIQUE partagé par les 3 écrans (fiche création, recherche
    /// rapide, plein écran) — avant ce helper, la carte plein écran aplatissait
    /// chaque entreprise sur son seul meilleur établissement et les deux autres
    /// écrans n'affichaient RIEN du registre.
    func establishmentPins(resolveCategory: (String) -> Int? = { _ in nil }) -> [SearchCandidate] {
        var pins: [SearchCandidate] = []
        for ranked in companies.prefix(5) {
            let located = ranked.match.allEstablishments
                .filter { $0.latitude != nil && $0.longitude != nil }
                .prefix(8)
            for est in located {
                pins.append(SearchCandidate(
                    source: .sirene,
                    result: ranked.match.enrichment(for: est, confidence: ranked.score,
                                                    resolveCategory: resolveCategory),
                    establishment: EstablishmentContext(
                        isHeadquarters: est.isHeadquarters,
                        isActive: est.isActive,
                        siren: ranked.match.siren
                    )
                ))
                if pins.count >= 25 { return pins }
            }
        }
        return pins
    }
}

// MARK: - Initial candidate (extrait depuis row.resolution)

private struct InitialCandidate {
    let name: String
    let regex: String
    let domain: String
    let city: String
    let country: String
    let engineMerchantId: String
    let categoryId: Int?

    init(row: ImportSessionRow) {
        // Regex : pattern simple matchant le libellé brut
        let escaped = NSRegularExpression.escapedPattern(for: row.rawLabel)
            .trimmingCharacters(in: .whitespaces)
        self.regex = escaped.isEmpty ? "" : "(?i)\(escaped)"

        // Pré-extraction déterministe ville/pays depuis le libellé (sans LLM).
        // Couvre les patterns évidents : VN + HA NOI / DA NANG / etc.,
        // FR + nom de ville française connue, ou code postal 5 chiffres.
        let locHit = LocationExtractor.extract(from: row.rawLabel)

        switch row.resolution {
        case .matched(_, let eid, let n, let c, _):
            self.name = n.titleCased
            self.engineMerchantId = eid ?? ""
            self.city = c ?? locHit.city ?? ""
            self.country = locHit.country ?? ""
            self.domain = eid.flatMap { MerchantDomains.domain(for: $0) } ?? ""
            self.categoryId = nil
        case .suggestCreate(let eid, let n, let c, let country, _):
            self.name = n.titleCased
            self.engineMerchantId = eid
            self.city = c ?? locHit.city ?? ""
            self.country = country ?? locHit.country ?? ""
            self.domain = MerchantDomains.domain(for: eid) ?? ""
            self.categoryId = nil
        case .needsManualPick(_, let eid, let topName, _):
            self.name = (topName ?? row.rawLabel).titleCased
            self.engineMerchantId = eid ?? ""
            self.city = locHit.city ?? ""
            self.country = locHit.country ?? ""
            self.domain = eid.flatMap { MerchantDomains.domain(for: $0) } ?? ""
            self.categoryId = nil
        case .suggestContact(let n, _):
            self.name = n.titleCased
            self.engineMerchantId = ""
            self.city = locHit.city ?? ""
            self.country = locHit.country ?? ""
            self.domain = ""
            self.categoryId = nil
        case .systemOperation(_, let n):
            self.name = n
            self.engineMerchantId = ""
            self.city = ""
            self.country = ""
            self.domain = ""
            self.categoryId = nil
        case .pending:
            self.name = row.rawLabel.titleCased
            self.engineMerchantId = ""
            self.city = locHit.city ?? ""
            self.country = locHit.country ?? ""
            self.domain = ""
            self.categoryId = nil
        }
    }
}

// MARK: - String helper

private extension String {
    var nilIfEmpty: String? {
        let t = self.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }
}
