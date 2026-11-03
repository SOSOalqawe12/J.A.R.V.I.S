import Foundation
import Security

/// Stores API keys in the Keychain (falls back to UserDefaults if the
/// Keychain is unavailable, e.g. in some unsigned/sideloaded builds).
enum KeychainStore {
    private static let service = "com.jarvis.assistant.keys"

    static func get(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) {
            return value
        }
        return UserDefaults.standard.string(forKey: fallbackKey(account)) ?? ""
    }

    static func set(_ value: String, for account: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(baseQuery as CFDictionary)
        guard !trimmed.isEmpty else {
            UserDefaults.standard.removeObject(forKey: fallbackKey(account))
            return
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = Data(trimmed.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: fallbackKey(account))
        } else {
            UserDefaults.standard.set(trimmed, forKey: fallbackKey(account))
        }
    }

    private static func fallbackKey(_ account: String) -> String { "jarvis.fallback.\(account)" }
}
