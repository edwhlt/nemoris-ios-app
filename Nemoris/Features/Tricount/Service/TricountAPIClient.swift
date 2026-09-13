import Foundation
import Security

// The Tricount API access layer: transport DTOs and the network client.
// Separate from the views, it depends on no SwiftUI type.
// The DTOs stay private — they never leave this file, only
// TricountFetchResult crosses the boundary.

// MARK: - API Codable structs (private)

private struct TCAuthResponse: Decodable {
    let Response: [TCAuthItem]
}
private struct TCAuthItem: Decodable {
    let Token: TCToken?
    let UserPerson: TCUserPerson?
}
private struct TCToken: Decodable { let token: String }
private struct TCUserPerson: Decodable { let id: Int }

private struct TCDataResponse: Decodable {
    let Response: [TCDataItem]
}
private struct TCDataItem: Decodable {
    let Registry: TCRegistry?
}
private struct TCRegistry: Decodable {
    let title: String
    let memberships: [TCMembershipWrapper]
    let all_registry_entry: [TCEntryWrapper]
}
private struct TCMembershipWrapper: Decodable {
    let RegistryMembershipNonUser: TCMemberNonUser
}
private struct TCMemberNonUser: Decodable {
    let alias: TCAlias
}
private struct TCAlias: Decodable {
    let display_name: String
}
private struct TCEntryWrapper: Decodable {
    let RegistryEntry: TCEntry
}
private struct TCEntry: Decodable {
    let uuid: String
    let updated: String
    let type_transaction: String
    let membership_owned: TCMembershipWrapper
    let amount: TCAmount
    let amount_local: TCAmount?
    let description: String?
    let date: String
    let allocations: [TCAllocation]
    let category: String
}
private struct TCAmount: Decodable {
    let value: String
    let currency: String?
}
private struct TCAllocation: Decodable {
    let membership: TCMembershipWrapper
    let amount: TCAmount
}

// MARK: - Fetch result

struct TricountFetchResult {
    let title: String
    let currency: String
    let members: [String]
    let entries: [ParsedTCEntry]
}

// MARK: - Error

enum TricountError: LocalizedError {
    case rsaKeyGeneration
    case authFailed(String)
    case fetchFailed(String)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .rsaKeyGeneration: return "Erreur de génération des clés RSA"
        case .authFailed(let m): return "Authentification échouée : \(m)"
        case .fetchFailed(let m): return "Chargement échoué : \(m)"
        case .invalidData: return "Données Tricount invalides"
        }
    }
}

// MARK: - API Client

struct TricountAPIClient {
    private let baseURL = "https://api.tricount.bunq.com"
    private let userAgent = "com.bunq.tricount.android:RELEASE:7.0.7:3174:ANDROID:13:C"

    func fetch(key: String) async throws -> TricountFetchResult {
        let (token, userId) = try await authenticate()
        let data = try await fetchData(key: key, token: token, userId: userId)
        return try parse(data)
    }

    private func authenticate() async throws -> (token: String, userId: Int) {
        guard let pem = generatePublicKeyPEM() else { throw TricountError.rsaKeyGeneration }
        let installId = UUID().uuidString
        var req = URLRequest(url: URL(string: "\(baseURL)/v1/session-registry-installation")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(installId, forHTTPHeaderField: "app-id")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Bunq-Client-Request-Id")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "app_installation_uuid": installId,
            "client_public_key": pem,
            "device_description": "Android"
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw TricountError.authFailed(String(data: data, encoding: .utf8) ?? "HTTP \(code)")
        }
        let decoded = try JSONDecoder().decode(TCAuthResponse.self, from: data)
        guard let token = decoded.Response.first(where: { $0.Token != nil })?.Token?.token,
              let userId = decoded.Response.first(where: { $0.UserPerson != nil })?.UserPerson?.id
        else { throw TricountError.authFailed("Token ou userId manquant") }
        return (token, userId)
    }

    private func fetchData(key: String, token: String, userId: Int) async throws -> Data {
        var req = URLRequest(url: URL(string: "\(baseURL)/v1/user/\(userId)/registry?public_identifier_token=\(key)")!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(token, forHTTPHeaderField: "X-Bunq-Client-Authentication")
        req.setValue(UUID().uuidString, forHTTPHeaderField: "X-Bunq-Client-Request-Id")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw TricountError.fetchFailed("HTTP \(code)") }
        return data
    }

    private func parse(_ data: Data) throws -> TricountFetchResult {
        let decoded = try JSONDecoder().decode(TCDataResponse.self, from: data)
        guard let registry = decoded.Response.first?.Registry else { throw TricountError.invalidData }
        let members = registry.memberships.map { $0.RegistryMembershipNonUser.alias.display_name }
        let currency = registry.all_registry_entry.first?.RegistryEntry.amount.currency ?? "EUR"
        let entries: [ParsedTCEntry] = registry.all_registry_entry.map { wrapper in
            let e = wrapper.RegistryEntry
            return ParsedTCEntry(
                sourceUUID: e.uuid,
                sourceUpdatedAt: e.updated,
                typeTransaction: e.type_transaction,
                whoPaid: e.membership_owned.RegistryMembershipNonUser.alias.display_name,
                total: (Double(e.amount.value) ?? 0) * -1,
                currency: e.amount.currency ?? currency,
                localTotal: e.amount_local.map { (Double($0.value) ?? 0) * -1 },
                localCurrency: e.amount_local?.currency ?? e.amount.currency ?? currency,
                description: e.description ?? "",
                date: String(e.date.prefix(10)),
                shares: e.allocations.map {
                    (memberName: $0.membership.RegistryMembershipNonUser.alias.display_name,
                     amount: abs(Double($0.amount.value) ?? 0))
                },
                category: e.category
            )
        }
        return TricountFetchResult(title: registry.title, currency: currency, members: members, entries: entries)
    }

    private func generatePublicKeyPEM() -> String? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false
        ]
        var err: Unmanaged<CFError>?
        guard let privKey = SecKeyCreateRandomKey(attrs as CFDictionary, &err),
              let pubKey = SecKeyCopyPublicKey(privKey),
              let keyData = SecKeyCopyExternalRepresentation(pubKey, &err) as Data?
        else { return nil }

        // iOS returns SubjectPublicKeyInfo (SPKI/PKCS#8); strip 24-byte header for PKCS#1
        let pkcs1: Data = (keyData.count > 26 && keyData[0] == 0x30 && keyData[4] == 0x30)
            ? keyData.dropFirst(24) : keyData

        let b64 = pkcs1.base64EncodedString(options: .lineLength64Characters)
        return "-----BEGIN RSA PUBLIC KEY-----\n\(b64)\n-----END RSA PUBLIC KEY-----\n"
    }
}

// MARK: - Tricount List View
