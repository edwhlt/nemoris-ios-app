import Foundation

/// Adapter conforming `SireneClient` to the `CompanyDataSource` protocol.
/// The implementation is unchanged — everything is delegated to the existing client.
struct SireneDataSource: CompanyDataSource {
    let id = "sirene_fr"
    let displayName = "Sirene (entreprises FR)"
    let country: String? = "FR"
    let requiresAPIKey = false
    let apiKeyHelpURL: URL? = URL(string: "https://recherche-entreprises.api.gouv.fr/")
    let isImplemented = true

    func search(query: String,
                postalCode: String?,
                apiKey: String?) async -> [MerchantEnrichment] {
        let establishments = (try? await SireneClient.shared.search(
            query: query,
            postalCode: postalCode,
            limit: 8
        )) ?? []
        return establishments.map { est in
            let nafCat = NAFCategoryMapper.shared.lookup(est.nafCode)
            return MerchantEnrichment(
                displayName: est.displayName.titleCased,
                domain: nil,
                categoryId: nil, // mapping done in the View, which has access to allCategories
                address: est.address,
                city: est.city,
                country: "FR",
                latitude: est.coordinates?.latitude,
                longitude: est.coordinates?.longitude,
                phone: nil,
                siret: est.siret,
                nafCode: est.nafCode,
                source: .sirene,
                confidence: (est.enseigne != nil ? 0.85 : 0.7) * (nafCat != nil ? 1.0 : 0.85),
                enrichedAt: Date()
            )
        }
    }
}
