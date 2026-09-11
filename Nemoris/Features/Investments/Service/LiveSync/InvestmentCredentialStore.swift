import Foundation
import Security

// MARK: - Keychain storage for live sync credentials
//
// API keys / secrets NEVER touch the SQLite database. They are stored
// encrypted in the iOS Keychain with these properties:
//   - Service: "fr.hedwin.nemoris.livesync" (shared namespace)
//   - Account: "<providerId>_<linkId>" (unique per provider↔account link)
//   - Accessibility: `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
//       → decryptable only after the first unlock (not in background before)
//       → "ThisDeviceOnly" = no iCloud Keychain sync (strict privacy)
//
// Storage format: the [String: String] credentials are serialized as UTF-8 JSON.

enum InvestmentCredentialStoreError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case keychainStatus(OSStatus)
    case notFound

    var errorDescription: String? {
        switch self {
        case .encodingFailed:        return "Impossible d'encoder les credentials."
        case .decodingFailed:        return "Impossible de décoder les credentials du Keychain."
        case .keychainStatus(let s): return "Erreur Keychain (code \(s))."
        case .notFound:              return "Aucun credential trouvé pour ce lien."
        }
    }
}

/// `@unchecked Sendable`: the class only holds `service` (a constant) and uses
/// `SecItem*`, which is thread-safe on the system side.
final class InvestmentCredentialStore: @unchecked Sendable {

    static let shared = InvestmentCredentialStore()
    private init() {}

    /// Keychain namespace shared by every live sync link.
    /// Kept under the bundle ID for clarity in Settings → Passwords.
    private let service = "fr.hedwin.nemoris.livesync"

    // MARK: - Public API

    /// Stores (or replaces) a given link's credentials.
    /// `linkId` must be the ID returned by `LiveSyncRepository.addLink`.
    func store(linkId: Int, providerId: String, credentials: [String: String]) throws {
        guard let data = try? JSONEncoder().encode(credentials) else {
            throw InvestmentCredentialStoreError.encodingFailed
        }

        let account = accountKey(linkId: linkId, providerId: providerId)

        // Delete first (idempotent), then add cleanly. SecItemUpdate is faster but
        // harder to handle for the "doesn't exist yet" case.
        deleteRaw(account: account)

        let attributes: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw InvestmentCredentialStoreError.keychainStatus(status)
        }
    }

    /// Fetches a link's credentials. Returns nil if not found.
    func load(linkId: Int, providerId: String) -> [String: String]? {
        let account = accountKey(linkId: linkId, providerId: providerId)
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }

    /// Deletes a link's credentials.
    /// Doesn't throw if nothing was stored (deleting an orphaned link).
    func delete(linkId: Int, providerId: String) {
        let account = accountKey(linkId: linkId, providerId: providerId)
        deleteRaw(account: account)
    }

    // MARK: - Private helpers

    /// Stable concatenation identifying a link: "<provider>_<id>".
    /// E.g. "binance_3", "evm_wallet_7".
    private func accountKey(linkId: Int, providerId: String) -> String {
        "\(providerId)_\(linkId)"
    }

    private func deleteRaw(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        // Status ignored — errSecItemNotFound is fine
    }
}
