import Foundation
import MapKit

/// Thin wrapper around `MKLocalSearch` to fetch an address / coordinates / POI.
/// No API key required. Apple's limits: undocumented, but reasonable.
///
/// Always called from `Task.detached` (the completion can be slow, ~500ms-2s).
struct MapKitSearchService {

    /// Returns the best POI match for `query` ± `region` (a city).
    /// `nil` if nothing found or offline. Used by the batch orchestrator (1 result).
    static func search(query: String, near city: String?) async -> MerchantEnrichment? {
        await searchAll(query: query, near: city, limit: 1).first
    }

    /// Returns up to `limit` distinct POIs for `query` ± `city`.
    /// Used by `EnrichmentSheetView` to let the user pick among
    /// several candidates (e.g. several "Bakery X" in Lyon).
    static func searchAll(query: String, near city: String?, limit: Int = 8) async -> [MerchantEnrichment] {
        let request = MKLocalSearch.Request()
        let fullQuery = [query, city].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        request.naturalLanguageQuery = fullQuery
        request.resultTypes = [.pointOfInterest]

        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            // Dedup by (name + address) — MapKit sometimes returns the same POI twice
            // under slightly different coordinates.
            var seen: Set<String> = []
            var out: [MerchantEnrichment] = []
            for item in response.mapItems {
                let key = "\(item.name ?? "")|\(item.placemark.thoroughfare ?? "")|\(item.placemark.locality ?? "")"
                guard seen.insert(key).inserted else { continue }
                out.append(convert(item))
                if out.count >= limit { break }
            }
            return out
        } catch {
            print("[MapKitSearchService] error: \(error.localizedDescription)")
            return []
        }
    }

    private static func convert(_ item: MKMapItem) -> MerchantEnrichment {
        let placemark = item.placemark
        let coords = item.placemark.coordinate
        let address: String? = {
            // Build a compact address
            var parts: [String] = []
            if let s = placemark.thoroughfare { parts.append(s) }
            if let p = placemark.postalCode { parts.append(p) }
            if let l = placemark.locality { parts.append(l) }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }()
        return MerchantEnrichment(
            displayName: item.name,
            domain: item.url?.host,
            categoryId: nil,
            address: address,
            city: placemark.locality,
            country: placemark.isoCountryCode,
            latitude: coords.latitude,
            longitude: coords.longitude,
            phone: item.phoneNumber,
            siret: nil, nafCode: nil,
            source: .mapkit,
            // MapKit doesn't return a score; we assign 0.6 by default (a middling signal).
            confidence: 0.6,
            enrichedAt: Date()
        )
    }
}
