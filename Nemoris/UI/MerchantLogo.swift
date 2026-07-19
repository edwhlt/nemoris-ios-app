import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Cercle affichant le logo d'un marchand (favicon Google) avec fallback SF Symbol
/// teinté par la couleur de la catégorie. AXE A.
///
/// Usage minimal :
///     MerchantLogo(domain: tiers.domain, engineMerchantId: tiers.engineMerchantId,
///                  fallbackIcon: category?.displayIcon)
///
/// Le composant lance le téléchargement (cache RAM/disque) en `.task`. Tant que
/// l'image n'est pas disponible, on affiche immédiatement le placeholder SF Symbol.
struct MerchantLogo: View {
    let domain: String?
    let engineMerchantId: String?
    let fallbackIcon: String?
    /// Si non-nil, on tente d'abord de charger la photo depuis le carnet de contacts iOS
    /// (priorité absolue car plus personnel). Fallback ensuite sur le domain/engineId.
    var contactIdentifier: String? = nil
    var size: CGFloat = 36
    var tint: Color = AppTheme.Colors.accent

    @State private var image: UIImage?
    @State private var resolvedDomain: String?
    @State private var resolvedContactId: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(image == nil ? tint.opacity(0.13) : Color.white)

            if let image {
                // Favicons Google viennent souvent avec leur propre padding et fond
                // transparent → on remplit beaucoup plus le cercle (0.86) pour que
                // le logo de marque soit bien visible (vs SF Symbol qui reste à 0.42).
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.86, height: size * 0.86)
                    .clipShape(Circle())
            } else {
                Image(systemName: fallbackIcon ?? "building.2.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            Circle().stroke(AppTheme.Colors.textSecondary.opacity(0.10), lineWidth: 0.5)
        )
        .task(id: cacheKey) {
            await loadIfNeeded()
        }
    }

    /// Clé combinée pour le `.task(id:)` — recharge si l'une des sources change.
    private var cacheKey: String {
        "\(contactIdentifier ?? "")|\(domain ?? "")|\(engineMerchantId ?? "")"
    }

    private func loadIfNeeded() async {
        // 1) PRIORITÉ : photo du carnet de contacts iOS (le plus personnel + local)
        if let contactId = contactIdentifier, !contactId.isEmpty {
            resolvedContactId = contactId
            if let contactImage = await ContactsService.shared.fetchImage(identifier: contactId) {
                if resolvedContactId == contactId {
                    image = contactImage
                }
                return
            }
            // Contact supprimé / pas de photo → on tombe sur le favicon ci-dessous
        }

        // 2) Favicon (domain explicite ou domain résolu via engine seed)
        let resolved = MerchantLogoService.resolveDomain(
            payeeDomain: domain,
            engineMerchantId: engineMerchantId
        )
        guard let resolved else {
            image = nil
            return
        }
        resolvedDomain = resolved
        if let cached = await MerchantLogoService.shared.cachedLogo(forDomain: resolved) {
            image = cached
            return
        }
        let downloaded = await MerchantLogoService.shared.logo(forDomain: resolved)
        if resolvedDomain == resolved {
            image = downloaded
        }
    }
}

// MARK: - Convenience init pour FinanceTransaction + Category

extension MerchantLogo {
    /// Initializer pour une transaction (utilise allTiers + allCategories déjà chargés
    /// dans la vue parente pour résoudre payee → domain/engineId/icon).
    /// AXE F : inclut aussi `contactIdentifier` et fallback contextuel par `tierType`
    /// pour que les transactions liées à un tier `.contact` affichent l'avatar carnet iOS.
    init(transaction tx: FinanceTransaction,
         allTiers: [Tiers],
         allCategories: [Category],
         size: CGFloat = 36) {
        let tiers = allTiers.first(where: { $0.id == tx.tiersId })
        let categoryId = tx.categoryId ?? tiers?.categoryId
        let category = allCategories.first(where: { $0.id == categoryId })
        // Fallback contextuel : si le tier est un contact, on préfère l'icône `person`
        // que l'icône de catégorie qui n'a pas de sens pour un humain.
        let fallback: String? = {
            if let t = tiers, t.tierType != .merchant {
                return t.tierType.systemIcon
            }
            return category?.displayIcon
        }()
        self.init(
            domain: tiers?.domain,
            engineMerchantId: tiers?.engineMerchantId,
            fallbackIcon: fallback,
            contactIdentifier: tiers?.contactIdentifier,
            size: size
        )
    }

    /// Initializer pour un tiers seul (liste des payees / pickers).
    /// Inclut automatiquement le contactIdentifier si le tier en a un (avatar carnet).
    init(tiers: Tiers, allCategories: [Category], size: CGFloat = 36) {
        let category = allCategories.first(where: { $0.id == tiers.categoryId })
        // Fallback icon contextuel : icône type si c'est un contact, sinon icône catégorie
        let fallback = tiers.tierType == .merchant
            ? category?.displayIcon
            : tiers.tierType.systemIcon
        self.init(
            domain: tiers.domain,
            engineMerchantId: tiers.engineMerchantId,
            fallbackIcon: fallback,
            contactIdentifier: tiers.contactIdentifier,
            size: size
        )
    }
}
