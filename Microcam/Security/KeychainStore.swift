import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status): "钥匙串操作失败（\(status)）"
        case .invalidData: "钥匙串中的数据格式无效"
        }
    }
}

enum KeychainAccount: String, Sendable {
    case databaseKey = "database-key"
    case apiKey = "ai-api-key"
    case redactionTerms = "redaction-terms"
}

enum KeychainStore {
    private static let service = "com.hidge123.microcam"

    static func data(for account: KeychainAccount) throws -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.unexpectedStatus(status) }
        guard let data = result as? Data else { throw KeychainStoreError.invalidData }
        return data
    }

    static func string(for account: KeychainAccount) throws -> String? {
        guard let data = try data(for: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw KeychainStoreError.invalidData }
        return value
    }

    static func set(_ data: Data, for account: KeychainAccount) throws {
        let query = baseQuery(account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)

        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw KeychainStoreError.unexpectedStatus(insertStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    static func set(_ value: String, for account: KeychainAccount) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainStoreError.invalidData }
        try set(data, for: account)
    }

    static func delete(_ account: KeychainAccount) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unexpectedStatus(status)
        }
    }

    private static func baseQuery(_ account: KeychainAccount) -> [String: Any] {
        // 本机 ad-hoc 签名没有 Data Protection Keychain 所需的 Team ID entitlement。
        // 使用 macOS 登录钥匙串，并显式禁止 iCloud 同步，仍由系统钥匙串负责静态加密。
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecAttrSynchronizable as String: false
        ]
    }
}
