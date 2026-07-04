import Foundation
import Security

enum KeychainTokenStoreError: LocalizedError, Equatable {
    case encodeFailed
    case decodeFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodeFailed:
            return "Could not encode Nanit tokens."
        case .decodeFailed:
            return "Could not decode Nanit tokens from Keychain."
        case .keychain(let status):
            return "Keychain returned status \(status)."
        }
    }
}

final class KeychainTokenStore {
    private let service: String
    private let account: String

    init(service: String = "com.tanooj.Nanight.nanit", account: String = "tokens") {
        self.service = service
        self.account = account
    }

    func load() throws -> NanitTokens? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainTokenStoreError.keychain(status)
        }

        guard let data = item as? Data else {
            throw KeychainTokenStoreError.decodeFailed
        }

        do {
            return try JSONDecoder().decode(NanitTokens.self, from: data)
        } catch {
            throw KeychainTokenStoreError.decodeFailed
        }
    }

    func save(_ tokens: NanitTokens) throws {
        guard let data = try? JSONEncoder().encode(tokens) else {
            throw KeychainTokenStoreError.encodeFailed
        }

        var query = baseQuery()
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecSuccess {
            return
        }

        if status != errSecItemNotFound {
            throw KeychainTokenStoreError.keychain(status)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainTokenStoreError.keychain(addStatus)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.keychain(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
