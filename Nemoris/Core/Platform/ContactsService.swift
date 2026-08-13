import Foundation
import Contacts
#if canImport(UIKit)
import UIKit
#endif

/// Service léger autour du framework `Contacts` d'Apple pour récupérer photos et noms
/// du carnet local de l'utilisateur, à associer à des tiers de type `.contact`.
///
/// **Privacy** : 100% local. Aucun appel réseau. Permission iOS demandée **uniquement**
/// au premier lien explicite (lazy), pas au launch (convention CLAUDE.md §6.7).
///
/// Architecture :
///   - `requestAccess()` : demande la permission si pas encore décidée. Idempotent.
///   - `fetchImage(identifier:)` : lit `imageData` ou `thumbnailImageData` du contact.
///   - `fetchName(identifier:)` : lit le nom formaté (pour vérifier qu'il existe encore).
///   - Cache RAM des UIImage chargées (limite : 256 entrées via NSCache).
@MainActor
final class ContactsService {

    static let shared = ContactsService()

    private let store = CNContactStore()
    private let imageCache = NSCache<NSString, UIImage>()

    private init() {
        imageCache.countLimit = 256
    }

    // MARK: - Permission

    /// État actuel de l'autorisation iOS — sans déclencher de prompt.
    var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// True si la permission a été accordée (ou limited iOS 18+).
    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized: return true
        case .limited:    return true  // iOS 18+ — accès partiel mais utilisable
        default:          return false
        }
    }

    /// Demande la permission Contacts à iOS si pas encore décidée.
    /// Renvoie true si autorisé in fine, false si refusé.
    /// **À appeler UNIQUEMENT au moment où l'utilisateur tente explicitement de lier un contact.**
    @discardableResult
    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            return false
        }
        // .notDetermined — on demande
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            print("[ContactsService] requestAccess error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Fetch

    /// Renvoie la photo du contact (thumbnail si dispo, sinon imageData full).
    /// Cache en RAM. Retourne nil si le contact n'existe plus ou n'a pas de photo.
    func fetchImage(identifier: String) async -> UIImage? {
        let key = identifier as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard isAuthorized else { return nil }

        let keysToFetch: [CNKeyDescriptor] = [
            CNContactImageDataKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]
        do {
            let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
            let data = contact.thumbnailImageData ?? contact.imageData
            guard let data, let image = UIImage(data: data) else { return nil }
            imageCache.setObject(image, forKey: key)
            return image
        } catch {
            // Contact supprimé / inaccessible / partiel sans accès à ce contact
            return nil
        }
    }

    /// Renvoie le nom formaté du contact (givenName + familyName) — utile pour
    /// vérifier que le contact existe encore et afficher un preview.
    func fetchName(identifier: String) async -> String? {
        guard isAuthorized else { return nil }
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]
        do {
            let contact = try store.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
            return CNContactFormatter.string(from: contact, style: .fullName)
        } catch {
            return nil
        }
    }
}
