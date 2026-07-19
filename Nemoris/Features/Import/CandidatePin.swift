import SwiftUI

/// Pin custom pour les cartes (`PayeeCreationFormSheet` et `EnrichmentMapFullscreenSheet`).
///
/// Affiche dans cet ordre de priorité :
///   1. Favicon du `domain` (via `MerchantLogo`) — pour les chaînes connues
///   2. SF Symbol thématique déduit du `displayName` (restaurant, café, hôtel, aéroport…)
///   3. Fallback SF Symbol selon la source (sirene/mapkit/llm)
///
/// La bordure et le pointer sont colorés selon la source. Plus grand quand sélectionné.
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
                    // MerchantLogo gère le favicon Google + fallback
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
        case .sirene: return .blue
        case .mapkit: return .green
        case .llm:    return .purple
        case .merged: return AppTheme.Colors.accent
        case .manual: return .orange
        }
    }

    /// SF Symbol thématique déduit du `displayName` quand le domain manque.
    /// Couvre les patterns FR + abréviations vietnamiennes.
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

        // Hôtels
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

        // Aéroports/voyage
        if name.contains("acv") {
            return "airplane.circle.fill"
        }

        // Fallback selon source
        switch source {
        case .sirene: return "building.2.fill"
        case .mapkit: return "mappin.circle.fill"
        case .llm:    return "sparkles"
        case .merged: return "circle.grid.cross.fill"
        case .manual: return "hand.point.up.fill"
        }
    }
}
