import SwiftUI

/// Custom pin for the maps (`PayeeCreationFormSheet` and `EnrichmentMapFullscreenSheet`).
///
/// Shows, in this order of priority:
///   1. The `domain`'s favicon (via `MerchantLogo`) — for known chains
///   2. A thematic SF Symbol inferred from `displayName` (restaurant, café,
///      hotel, airport…)
///   3. A fallback SF Symbol by source (sirene/mapkit/llm)
///
/// The border and the pointer are colored by source. Larger when selected.
struct CandidatePin: View {
    let source: MerchantEnrichmentSource
    let displayName: String?
    let domain: String?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: pinSize, height: pinSize)
                    .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)

                Circle()
                    .strokeBorder(sourceColor, lineWidth: isSelected ? 3 : 2)
                    .frame(width: pinSize, height: pinSize)

                if let domain, !domain.isEmpty {
                    // MerchantLogo handles the Google favicon + fallback
                    MerchantLogo(
                        domain: domain,
                        engineMerchantId: nil,
                        fallbackIcon: thematicIcon,
                        size: pinSize - 8
                    )
                } else {
                    Image(systemName: thematicIcon)
                        .font(.system(size: pinSize * 0.42, weight: .semibold))
                        .foregroundStyle(sourceColor)
                }
            }
            // Triangle pointer
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 10))
                .foregroundStyle(sourceColor)
                .offset(y: -4)
        }
    }

    private var pinSize: CGFloat { isSelected ? 52 : 36 }

    private var sourceColor: Color {
        switch source {
        case .sirene:   return .blue
        case .mapkit:   return .green
        case .llm:      return .purple
        case .localLLM: return .teal
        case .cloudLLM: return .indigo
        case .merged:   return AppTheme.Colors.accent
        case .manual:   return .orange
        }
    }

    /// Thematic SF Symbol inferred from `displayName` when the domain is missing.
    /// Covers French patterns + Vietnamese abbreviations.
    private var thematicIcon: String {
        let name = (displayName ?? "")
            .folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()

        // Restaurants / nourriture
        if name.contains("restaurant") || name.contains("nha hang") ||
           name.contains("brasserie") || name.contains("bistro") ||
           name.contains("trattoria") || name.contains("pizzeria") {
            return "fork.knife"
        }
        if name.contains("café") || name.contains("cafe") || name.contains("starbucks") ||
           name.contains("costa") || name.contains("nespresso") {
            return "cup.and.saucer.fill"
        }
        if name.contains("bar") || name.contains("pub") || name.contains("quan") {
            return "wineglass.fill"
        }
        if name.contains("boulang") || name.contains("brioche") || name.contains("paul") {
            return "birthday.cake.fill"
        }

        // Hotels
        if name.contains("hotel") || name.contains("khach san") || name.contains("ibis") ||
           name.contains("novotel") || name.contains("airbnb") || name.contains("auberge") {
            return "bed.double.fill"
        }

        // Transport
        if name.contains("aeroport") || name.contains("airport") || name.contains("noi bai") ||
           name.contains("tan son nhat") {
            return "airplane"
        }
        if name.contains("gare") || name.contains("station") || name.contains("sncf") ||
           name.contains("metro") || name.contains("ratp") {
            return "tram.fill"
        }
        if name.contains("essence") || name.contains("station service") || name.contains("total") ||
           name.contains("shell") || name.contains("bp ") || name.contains("ionity") {
            return "fuelpump.fill"
        }

        // Commerce
        if name.contains("supermarche") || name.contains("supermarket") || name.contains("sieu thi") ||
           name.contains("carrefour") || name.contains("auchan") || name.contains("lidl") ||
           name.contains("leclerc") || name.contains("monoprix") || name.contains("franprix") ||
           name.contains("intermarche") {
            return "cart.fill"
        }
        if name.contains("marche") || name.contains("market") || name.contains("cho") {
            return "basket.fill"
        }
        if name.contains("pharma") || name.contains("pharmacie") {
            return "cross.case.fill"
        }
        if name.contains("librairie") || name.contains("bookshop") || name.contains("fnac") {
            return "book.fill"
        }
        if name.contains("magasin") || name.contains("shop") || name.contains("store") {
            return "bag.fill"
        }

        // Airports/travel
        if name.contains("acv") {
            return "airplane.circle.fill"
        }

        // Fallback selon source
        switch source {
        case .sirene:   return "building.2.fill"
        case .mapkit:   return "mappin.circle.fill"
        case .llm:      return "sparkles"
        case .localLLM: return "server.rack"
        case .cloudLLM: return "cloud"
        case .merged:   return "circle.grid.cross.fill"
        case .manual:   return "hand.point.up.fill"
        }
    }
}
