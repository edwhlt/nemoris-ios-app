import SwiftUI
import MapKit
import NemorisEngine

/// Carte plein écran pour explorer les candidats d'enrichissement géolocalisés.
///
/// L'utilisateur peut :
///   - Pan/zoom à volonté
///   - Modifier la requête en haut et **relancer la recherche** (région courante prise
///     en compte si dispo, sinon globale)
///   - Tap sur un pin → bottom sheet avec détails + "Choisir ce candidat"
///
/// Tap "Choisir" → ferme la sheet et appelle `onPick(candidate)` (qui pré-remplit le
/// formulaire parent — typiquement `PayeeCreationFormSheet`).
struct EnrichmentMapFullscreenSheet: View {
    @Environment(\.dismiss) private var dismiss

    let initialQuery: String
    let initialCandidates: [SearchCandidate]
    let onPick: (SearchCandidate) -> Void

    @State private var query: String
    @State private var candidates: [SearchCandidate]
    @State private var selectedCandidate: SearchCandidate? = nil
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isSearching: Bool = false

    init(initialQuery: String,
         initialCandidates: [SearchCandidate],
         onPick: @escaping (SearchCandidate) -> Void) {
        self.initialQuery = initialQuery
        self.initialCandidates = initialCandidates
        self.onPick = onPick
        _query = State(initialValue: initialQuery)
        _candidates = State(initialValue: initialCandidates)
    }

    var body: some View {
            ZStack(alignment: .bottom) {
                Map(position: $cameraPosition, selection: Binding(
                    get: { selectedCandidate?.id },
                    set: { id in selectedCandidate = candidates.first(where: { $0.id == id }) }
                )) {
                    ForEach(geoCandidates) { candidate in
                        if let lat = candidate.result.latitude,
                           let lon = candidate.result.longitude {
                            Annotation(
                                candidate.result.displayName ?? "?",
                                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
                            ) {
                                CandidatePin(
                                    source: candidate.source,
                                    displayName: candidate.result.displayName,
                                    domain: candidate.result.domain,
                                    isSelected: candidate.id == selectedCandidate?.id
                                )
                            }
                            .tag(candidate.id)
                        }
                    }
                }
                .mapStyle(.standard)
                .ignoresSafeArea(edges: .bottom)

                // Top search bar overlay
                VStack(spacing: 0) {
                    searchBar
                    Spacer()
                    if let selected = selectedCandidate {
                        candidateDetailCard(selected)
                    }
                }
            }
            // `.paneChrome` dessine ses propres barres sur macOS-sheet — la
            // barre d'outils native laisse le bureau de l'utilisateur
            // transparaître (retour d'usage 2026-08-21). Cf. le commentaire
            // de `macSheetChrome` dans AdaptivePane.swift.
            .paneChrome("Carte des résultats", cancelLabel: "Fermer", onCancel: { dismiss() })
    }

    private var geoCandidates: [SearchCandidate] {
        candidates.filter { $0.result.latitude != nil && $0.result.longitude != nil }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.Colors.textSecondary)
            TextField("Affine la recherche…", text: $query)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.none)
                .submitLabel(.search)
                .onSubmit { Task { await rerunSearch() } }
            if isSearching {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await rerunSearch() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: Detail card

    @ViewBuilder
    private func candidateDetailCard(_ c: SearchCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                sourceBadge(c.source)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.result.displayName ?? "—")
                            .font(.headline)
                            .lineLimit(1)
                        if c.establishment?.isHeadquarters == true {
                            detailBadge("Siège", color: AppTheme.Colors.accent)
                        }
                        if c.establishment?.isActive == false {
                            detailBadge("Fermé", color: AppTheme.Colors.danger)
                        }
                    }
                    if let addr = c.result.address, !addr.isEmpty {
                        Text(addr).font(.caption).foregroundStyle(AppTheme.Colors.textSecondary).lineLimit(2)
                    }
                    if let siret = c.result.siret {
                        Text("SIRET \(siret)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(AppTheme.Colors.textSecondary.opacity(0.5))
                    }
                }
                Spacer()
                Text("\(Int(c.result.confidence * 100))%")
                    .font(.caption.bold())
                    .foregroundStyle(AppTheme.Colors.textSecondary)
            }
            Button {
                onPick(c)
                dismiss()
            } label: {
                Label("Choisir ce candidat", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedCandidate?.id)
    }

    private func detailBadge(_ label: LocalizedStringKey, color: Color) -> some View {
        Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func sourceBadge(_ s: MerchantEnrichmentSource) -> some View {
        VStack(spacing: 2) {
            Image(systemName: markerIcon(for: s)).font(.caption.weight(.bold))
            Text(badgeLabel(for: s)).font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .frame(width: 50)
        .background(markerColor(for: s).opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(markerColor(for: s))
    }

    // MARK: Re-search

    private func rerunSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        selectedCandidate = nil

        // Pour le plein écran on relance Sirene + MapKit + LLM (toggles non exposés
        // ici — l'utilisateur veut juste explorer la carte, on garde toutes les sources).
        var collected: [SearchCandidate] = []

        // même chemin que les deux autres écrans : planificateur + cascade.
        // Laisser ici l'ancienne construction de `q=` aurait recréé deux chemins de code
        // divergents pour la même question, ce que la doctrine du projet proscrit.
        //
        // Un pin par ÉTABLISSEMENT géolocalisé (`establishmentPins`, chemin partagé) —
        // l'ancien aplatissement 1 entreprise = 1 pin masquait toutes les branches
        // alors que c'est précisément l'adresse qui distingue la bonne boutique.
        let result = await MerchantQueryExecutor.shared.search(
            input: MerchantQueryPlanner.Input(
                rawLabel: trimmed,
                userQueryOverride: trimmed
            ),
            budget: .interactive,
            knownNafPrefixes: NAFCategoryMapper.shared.knownPrefixes
        )
        collected.append(contentsOf: result.establishmentPins())

        let mapResults = await MapKitSearchService.searchAll(query: trimmed, near: nil, limit: 12)
        for map in mapResults {
            var fixed = map
            fixed.displayName = (fixed.displayName ?? trimmed).titleCased
            collected.append(SearchCandidate(source: .mapkit, result: fixed))
        }

        candidates = collected
        if !geoCandidates.isEmpty {
            cameraPosition = .automatic
        }
    }

    // MARK: Style

    private func markerIcon(for s: MerchantEnrichmentSource) -> String {
        switch s {
        case .sirene:   return "building.2.fill"
        case .mapkit:   return "mappin.circle.fill"
        case .llm:      return "sparkles"
        case .localLLM: return "server.rack"
        case .cloudLLM: return "cloud"
        default:        return "mappin"
        }
    }

    private func markerColor(for s: MerchantEnrichmentSource) -> Color {
        switch s {
        case .sirene:   return .blue
        case .mapkit:   return .green
        case .llm:      return .purple
        case .localLLM: return .teal
        default:        return .red
        }
    }

    private func badgeLabel(for s: MerchantEnrichmentSource) -> String {
        switch s {
        case .sirene:   return "SIRENE"
        case .mapkit:   return "MAPS"
        case .llm:      return "IA"
        case .localLLM: return "LOCAL"
        case .cloudLLM: return "cloud"
        case .merged:   return "FUSION"
        case .manual:   return "MANUEL"
        }
    }
}
