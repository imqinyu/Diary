import Foundation
import Security

struct GitHubSessionCredential: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
}

protocol SyncCredentialStore {
    func read() throws -> String?
    func save(_ token: String) throws
    func remove() throws
}

struct KeychainSyncCredentials: SyncCredentialStore {
    private let service = "com.qinyu.Diary.github-sync"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "github-token"]
    }
    func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw CredentialError(status) }
        return token
    }
    func save(_ token: String) throws {
        let values = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(values) { _, value in value }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CredentialError(status) }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError(status) }
    }
    private struct CredentialError: LocalizedError {
        let status: OSStatus
        init(_ status: OSStatus) { self.status = status }
        var errorDescription: String? { "无法访问 macOS 钥匙串（\(status)），请检查钥匙串权限" }
    }
}
