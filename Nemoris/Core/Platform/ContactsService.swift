import Foundation
import Contacts
#if canImport(UIKit)
import UIKit
#endif

/// Lightweight service around Apple's `Contacts` framework to fetch photos
/// and names from the user's local address book, for association with tiers
/// of type `.contact`.
///
/// **Privacy**: 100% local. No network calls. The iOS permission is
/// requested **only** on the first explicit link (lazy), not at launch.
///
/// Architecture:
///   - `requestAccess()`: requests the permission if not yet decided. Idempotent.
///   - `fetchImage(identifier:)`: reads the contact's `imageData` or `thumbnailImageData`.
///   - `fetchName(identifier:)`: reads the formatted name (to check the contact still exists).
///   - RAM cache of loaded UIImages (limit: 256 entries via NSCache).
@MainActor
final class ContactsService {

    static let shared = ContactsService()

    private let store = CNContactStore()
    private let imageCache = NSCache<NSString, UIImage>()

    private init() {
        imageCache.countLimit = 256
    }

    // MARK: - Permission

    /// Current iOS authorization state — does not trigger a prompt.
    var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    /// True if permission has been granted (or limited on iOS 18+).
    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized: return true
        case .limited:    return true  // iOS 18+ — partial but usable access
        default:          return false
        }
    }

    /// Requests the Contacts permission from iOS if not yet decided.
    /// Returns true if ultimately authorized, false if denied.
    /// **Call ONLY when the user explicitly attempts to link a contact.**
    @discardableResult
    func requestAccess() async -> Bool {
        if isAuthorized { return true }
        if authorizationStatus == .denied || authorizationStatus == .restricted {
            return false
        }
        // .notDetermined — request it
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            print("[ContactsService] requestAccess error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Fetch

    /// Returns the contact's photo (thumbnail if available, otherwise full
    /// imageData). Cached in RAM. Returns nil if the contact no longer
    /// exists or has no photo.
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
            // Contact deleted / inaccessible / limited access without this contact
            return nil
        }
    }

    /// Returns the contact's formatted name (givenName + familyName) —
    /// useful to check the contact still exists and to show a preview.
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
