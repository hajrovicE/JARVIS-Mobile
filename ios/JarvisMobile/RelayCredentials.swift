import Foundation
import Security

/// This is a revocable relay-session credential, never a model vendor API key.
enum RelayCredentials {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jarvis.mobile.relay", kSecAttrAccount as String: "session",
         kSecAttrSynchronizable as String: false]
    }
    static func load() throws -> String? {
        var request = query; request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { throw CredentialError.unavailable }
        return text
    }
    static func save(_ text: String) throws {
        let values: [String: Any] = [kSecValueData as String: Data(text.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updated == errSecItemNotFound {
            var insert = query; values.forEach { insert[$0.key] = $0.value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw CredentialError.unavailable }
        } else if updated != errSecSuccess { throw CredentialError.unavailable }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialError.unavailable }
    }
    enum CredentialError: Error { case unavailable }
}
