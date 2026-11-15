#if canImport(CryptoKit) && canImport(Security)
import Foundation
import CryptoKit
import Security
import Darwin

/// One encrypted snapshot, with all filesystem operations serialized per storage instance.
/// The unchecked conformance is limited to NSLock-protected I/O; URL and key are immutable.
public final class EncryptedFileStorage: SnapshotStorage, @unchecked Sendable {
    private let url: URL
    private let key: SymmetricKey
    private let lock = NSLock()
    private static let service = "com.jarvis.mobile.storage"

    public init(url: URL, keychainAccount: String) throws {
        self.url = url
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrSynchronizable as String: false
        ]
        if let existing = try Self.readKey(query) {
            key = existing
            return
        }
        // An unavailable or removed key must never cause existing ciphertext to be overwritten.
        guard !FileManager.default.fileExists(atPath: url.path) else { throw StorageError.missingKey }
        let generated = SymmetricKey(size: .bits256)
        var insert = query
        insert[kSecValueData as String] = generated.withUnsafeBytes { Data($0) }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        if status == errSecSuccess {
            key = generated
        } else if status == errSecDuplicateItem, let existing = try Self.readKey(query) {
            // Another initializer may have created the account between lookup and insert.
            key = existing
        } else {
            throw StorageError.keychain(status)
        }
    }

    private static func readKey(_ query: [String: Any]) throws -> SymmetricKey? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StorageError.keychain(status) }
        guard let data = result as? Data, data.count == 32 else { throw StorageError.invalidKey }
        return SymmetricKey(data: data)
    }

    public func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let ciphertext = try Data(contentsOf: url)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext), using: key)
    }

    public func save(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        #if os(iOS)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.complete])
        #else
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        #endif
        // Protect backup policy before creating any new snapshot. No fallible metadata writes
        // may follow the rename: a reported failure must preserve the previous live snapshot.
        var excludedDirectory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excludedDirectory.setResourceValues(values)
        let temporary = directory.appendingPathComponent(".jarvis-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        guard let ciphertext = try AES.GCM.seal(data, using: key).combined else {
            throw StorageError.invalidCiphertext
        }
        #if os(iOS)
        try ciphertext.write(to: temporary, options: [.withoutOverwriting, .completeFileProtection])
        #else
        try ciphertext.write(to: temporary, options: .withoutOverwriting)
        #endif
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        var excludedFile = temporary
        try excludedFile.setResourceValues(values)
        // Same-directory POSIX rename replaces the destination atomically, preserving the new
        // file's protection and backup attributes. A failed rename leaves old ciphertext intact.
        let result = temporary.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }

    public enum StorageError: Error { case keychain(OSStatus), invalidKey, missingKey, invalidCiphertext }
}
#endif
