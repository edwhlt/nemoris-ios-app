import Foundation

/// UK Companies House — registre officiel des entreprises britanniques.
/// Gratuit avec clé API (rate limit 600 req / 5 min).
/// Doc : https://developer.company-information.service.gov.uk/
///
/// Auth : HTTP Basic, username = API key, password vide.
struct CompaniesHouseDataSource: CompanyDataSource {
    let id = "companies_house_uk"
    let displayName = "Companies House (UK)"
    let country: String? = "GB"
    let requiresAPIKey = true
    let apiKeyHelpURL: URL? = URL(string: "https://developer.company-information.service.gov.uk/get-started")
    let isImplemented = true

    private let baseURL = URL(string: "https://api.company-information.service.gov.uk/search/companies")!

    func search(query: String,
                postalCode: String?,
                apiKey: String?) async -> [MerchantEnrichment] {
        guard let key = apiKey, !key.isEmpty else {
            print("[CompaniesHouse] missing API key, skipping")
            return []
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "q", value: trimmed),
            .init(name: "items_per_page", value: "8")
        ]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        // HTTP Basic auth : "Basic base64(key:)"
        let credentials = "\(key):".data(using: .utf8)?.base64EncodedString() ?? ""
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("[CompaniesHouse] status \(http.statusCode)")
                return []
            }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            return decoded.items.compactMap { item in
                guard let title = item.title else { return nil }
                let address = [item.address?.address_line_1,
                               item.address?.locality,
                               item.address?.postal_code].compactMap { $0 }.joined(separator: ", ")
                return MerchantEnrichment(
                    displayName: title.titleCased,
                    domain: nil,
                    categoryId: nil,
                    address: address.isEmpty ? nil : address,
                    city: item.address?.locality,
                    country: "GB",
                    latitude: nil,
                    longitude: nil,
                    phone: nil,
                    siret: item.company_number,  // identifiant officiel UK = company_number
                    nafCode: item.sic_codes?.first,
                    source: .sirene,
                    confidence: 0.8,
                    enrichedAt: Date()
                )
            }
        } catch {
            print("[CompaniesHouse] error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - JSON model

    private struct SearchResponse: Decodable {
        let items: [Company]
    }
    private struct Company: Decodable {
        let title: String?
        let company_number: String?
        let address: Address?
        let sic_codes: [String]?
    }
    private struct Address: Decodable {
        let address_line_1: String?
        let locality: String?
        let postal_code: String?
    }
}
