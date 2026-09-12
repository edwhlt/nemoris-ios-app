import Foundation

/// Zefix — the official Swiss company registry.
/// Public, no key. Docs: https://www.zefix.admin.ch/ZefixPublicREST/
///
/// Note: Zefix uses POST with a JSON body, which is unusual but fine.
struct ZefixDataSource: CompanyDataSource {
    let id = "zefix_ch"
    let displayName = "Zefix (entreprises CH)"
    let country: String? = "CH"
    let requiresAPIKey = false
    let apiKeyHelpURL: URL? = URL(string: "https://www.zefix.ch/")
    let isImplemented = true

    private let endpoint = URL(string: "https://www.zefix.admin.ch/ZefixPublicREST/api/v1/company/search")!

    func search(query: String,
                postalCode: String?,
                apiKey: String?) async -> [MerchantEnrichment] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8
        let body: [String: Any] = [
            "name": trimmed,
            "languageKey": "fr",
            "maxEntries": 8
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                print("[Zefix] status \(http.statusCode)")
                return []
            }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            return decoded.list.compactMap { item in
                guard let name = item.name else { return nil }
                let address = [item.address?.street,
                               item.address?.swissZipCode,
                               item.address?.city].compactMap { $0 }.joined(separator: " ")
                return MerchantEnrichment(
                    displayName: name.titleCased,
                    domain: nil,
                    categoryId: nil,
                    address: address.isEmpty ? nil : address,
                    city: item.address?.city,
                    country: "CH",
                    latitude: nil,
                    longitude: nil,
                    phone: nil,
                    siret: item.uid,  // identifiant officiel CH = UID
                    nafCode: nil,
                    source: .sirene,
                    confidence: 0.8,
                    enrichedAt: Date()
                )
            }
        } catch {
            print("[Zefix] error: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - JSON model

    private struct SearchResponse: Decodable {
        let list: [Company]
    }
    private struct Company: Decodable {
        let name: String?
        let uid: String?
        let address: Address?
    }
    private struct Address: Decodable {
        let street: String?
        let swissZipCode: String?
        let city: String?
    }
}
