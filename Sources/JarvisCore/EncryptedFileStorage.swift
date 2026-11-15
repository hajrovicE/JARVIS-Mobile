#if canImport(CryptoKit) && canImport(Security)
import Foundation
import CryptoKit
import Security

public struct EncryptedFileStorage: SnapshotStorage {
    private let url: URL
    private let key: SymmetricKey
    public init(url: URL, keychainAccount: String) throws {
        self.url = url
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.jarvis.mobile.storage", kSecAttrAccount as String: keychainAccount]
        var result: CFTypeRef?
        var lookup = query; lookup[kSecReturnData as String] = true
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data {
            guard data.count == 32 else { throw StorageError.invalidKey }
            key = SymmetricKey(data: data)
        } else if status == errSecItemNotFound {
            // Never generate a replacement key for existing ciphertext.
            guard !FileManager.default.fileExists(atPath: url.path) else { throw StorageError.missingKey }
            let generated = SymmetricKey(size: .bits256)
            var insert = query
            insert[kSecValueData as String] = generated.withUnsafeBytes { Data($0) }
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw StorageError.keychain(added) }
            key = generated
        } else { throw StorageError.keychain(status) }
    }
    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key)
    }
    public func save(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encrypted = try AES.GCM.seal(data, using: key).combined!
        #if os(iOS)
        try encrypted.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try encrypted.write(to: url, options: .atomic)
        #endif
        var resourceURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
    public enum StorageError: Error { case keychain(OSStatus), invalidKey, missingKey }
}
#endif
