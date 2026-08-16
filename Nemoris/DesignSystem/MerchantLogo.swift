import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Circle displaying a merchant's logo (Google favicon) with an SF Symbol
/// fallback tinted by the category color.
///
/// Minimal usage:
///     MerchantLogo(domain: tiers.domain, engineMerchantId: tiers.engineMerchantId,
///                  fallbackIcon: category?.displayIcon)
///
/// The component kicks off the download (RAM/disk cache) in `.task`. Until
/// the image is available, the SF Symbol placeholder is shown immediately.
struct MerchantLogo: View {
    let domain: String?
    let engineMerchantId: String?
    let fallbackIcon: String?
    /// When non-nil, the photo is first loaded from the iOS contacts book
    /// (absolute priority, since it's the most personal source). Falls back
    /// to domain/engineId afterward.
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
                // Google favicons often come with their own padding and a
                // transparent background, so the circle is filled much more
                // (0.86) to keep the brand logo clearly visible (vs the SF
                // Symbol, which stays at 0.42).
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

    /// Combined key for `.task(id:)` — reloads when any source changes.
    private var cacheKey: String {
        "\(contactIdentifier ?? "")|\(domain ?? "")|\(engineMerchantId ?? "")"
    }

    private func loadIfNeeded() async {
        // 1) PRIORITY: photo from the iOS contacts book (most personal + local)
        if let contactId = contactIdentifier, !contactId.isEmpty {
            resolvedContactId = contactId
            if let contactImage = await ContactsService.shared.fetchImage(identifier: contactId) {
                if resolvedContactId == contactId {
                    image = contactImage
                }
                return
            }
            // Contact deleted / no photo → fall through to the favicon below
        }

        // 2) Favicon (explicit domain, or domain resolved via the engine seed)
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

// MARK: - Convenience init for FinanceTransaction + Category

extension MerchantLogo {
    /// Initializer for a transaction (uses allTiers + allCategories already
    /// loaded in the parent view to resolve payee → domain/engineId/icon).
    /// Also includes `contactIdentifier` and a contextual fallback by
    /// `tierType`, so transactions linked to a `.contact` tier show the
    /// contacts-book avatar.
    init(transaction tx: FinanceTransaction,
         allTiers: [Tiers],
         allCategories: [Category],
         size: CGFloat = 36) {
        let tiers = allTiers.first(where: { $0.id == tx.tiersId })
        let categoryId = tx.categoryId ?? tiers?.categoryId
        let category = allCategories.first(where: { $0.id == categoryId })
        // Contextual fallback: if the tier is a contact, the `person` icon
        // is preferred over the category icon, which makes no sense for a
        // human.
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

    /// Initializer for a standalone tier (payee lists / pickers).
    /// Automatically includes the contactIdentifier if the tier has one
    /// (contacts-book avatar).
    init(tiers: Tiers, allCategories: [Category], size: CGFloat = 36) {
        let category = allCategories.first(where: { $0.id == tiers.categoryId })
        // Contextual fallback icon: type icon for a contact, category icon otherwise
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
