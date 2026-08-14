import Foundation
import Security

// MARK: - Stockage Keychain pour les credentials live sync
//
// Les clés API / secrets ne touchent JAMAIS la base SQLite. Ils sont stockés
// chiffrés dans le Keychain iOS avec ces propriétés :
//   - Service : "fr.hedwin.nemoris.livesync" (espace de noms commun)
//   - Account : "<providerId>_<linkId>" (unique par lien provider↔compte)
//   - Accessibility : `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
//       → déchiffrable seulement après le 1er déverrouillage (pas en background avant)
//       → "ThisDeviceOnly" = pas de sync iCloud Keychain (privacy strict)
//
// Format de stockage : les credentials [String: String] sont sérialisés en JSON UTF-8.

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

/// `@unchecked Sendable` : la classe ne contient que `service` (constante) et
/// utilise `SecItem*` qui sont thread-safe côté système.
final class InvestmentCredentialStore: @unchecked Sendable {

    static let shared = InvestmentCredentialStore()
    private init() {}

    /// Espace de noms Keychain commun à tous les liens live sync.
    /// Choisi pour rester sous le bundle ID pour clarité dans Réglages → Mots de passe.
    private let service = "fr.hedwin.nemoris.livesync"

    // MARK: - Public API

    /// Stocke (ou remplace) les credentials d'un lien donné.
    /// `linkId` doit être l'ID retourné par `LiveSyncRepository.addLink`.
    func store(linkId: Int, providerId: String, credentials: [String: String]) throws {
        guard let data = try? JSONEncoder().encode(credentials) else {
            throw InvestmentCredentialStoreError.encodingFailed
        }

        let account = accountKey(linkId: linkId, providerId: providerId)

        // On supprime d'abord (idempotent), puis on ajoute proprement.
        // SecItemUpdate est plus rapide mais plus complexe à gérer pour le cas "n'existe pas encore".
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

    /// Récupère les credentials d'un lien. Retourne nil si non trouvé.
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

    /// Supprime les credentials d'un lien.
    /// Ne lève pas d'erreur si rien n'était stocké (cas suppression d'un lien orphelin).
    func delete(linkId: Int, providerId: String) {
        let account = accountKey(linkId: linkId, providerId: providerId)
        deleteRaw(account: account)
    }

    // MARK: - Helpers privés

    /// Concaténation stable pour identifier un lien : "<provider>_<id>".
    /// Ex: "binance_3", "evm_wallet_7".
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
        // Ignore le status — errSecItemNotFound est OK
    }
}
