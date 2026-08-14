import Foundation
import MapKit

/// Wrapper léger autour de `MKLocalSearch` pour récupérer adresse / coords / POI.
/// Pas de clé API requise. Limites Apple : pas documenté, mais raisonnable.
///
/// Toujours appelé depuis `Task.detached` (la complétion peut être lente, ~500ms-2s).
struct MapKitSearchService {

    /// Renvoie le meilleur match POI pour `query` ± `region` (ville).
    /// `nil` si rien trouvé ou si offline. Utilisé par l'orchestrateur batch (1 résultat).
    static func search(query: String, near city: String?) async -> MerchantEnrichment? {
        await searchAll(query: query, near: city, limit: 1).first
    }

    /// Renvoie jusqu'à `limit` POI distincts pour `query` ± `city`.
    /// Utilisé par `EnrichmentSheetView` pour laisser l'utilisateur choisir parmi
    /// plusieurs candidats (ex. plusieurs Boulangerie X à Lyon).
    static func searchAll(query: String, near city: String?, limit: Int = 8) async -> [MerchantEnrichment] {
        let request = MKLocalSearch.Request()
        let fullQuery = [query, city].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        request.naturalLanguageQuery = fullQuery
        request.resultTypes = [.pointOfInterest]

        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            // Dédup par (name + adresse) — MapKit renvoie parfois 2 fois le même POI
            // sous des coordonnées légèrement différentes.
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
            // Construire une adresse compacte
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
            // MapKit ne renvoie pas de score ; on attribue 0.6 par défaut (signal moyen).
            confidence: 0.6,
            enrichedAt: Date()
        )
    }
}
