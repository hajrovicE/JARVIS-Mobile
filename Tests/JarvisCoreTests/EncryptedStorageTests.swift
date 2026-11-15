#if canImport(CryptoKit) && canImport(Security)
import Foundation
import Security
import XCTest
@testable import JarvisCore

/// These tests use platform Keychain and filesystem APIs, including on the iOS simulator.
final class EncryptedStorageTests: XCTestCase, @unchecked Sendable {
    private func fixture() -> (directory: URL, url: URL, account: String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (directory, directory.appendingPathComponent("memory.aes"), "storage-test-\(UUID())")
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jarvis.mobile.storage", kSecAttrAccount as String: account]
    }
    private func cleanup(_ directory: URL, _ account: String) {
        try? FileManager.default.removeItem(at: directory)
        SecItemDelete(query(account) as CFDictionary)
    }

    func testKeychainAccessibilityAndRandomizedCiphertext() async throws {
        let f = fixture(); defer { cleanup(f.directory, f.account) }
        let disk = try EncryptedFileStorage(url: f.url, keychainAccount: f.account)
        let plaintext = Data("private-content".utf8)
        try disk.save(plaintext)
        let first = try Data(contentsOf: f.url)
        try disk.save(plaintext)
        let second = try Data(contentsOf: f.url)
        XCTAssertNotEqual(first, second, "Each write needs a fresh AES-GCM nonce")
        XCTAssertNil(second.range(of: plaintext))
        var attributesQuery = query(f.account)
        attributesQuery[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attributesQuery as CFDictionary, &attributes), errSecSuccess)
        let attributesDictionary = try XCTUnwrap(attributes as? [String: Any])
        #if os(iOS)
        // iOS exposes and enforces Data Protection accessibility. The legacy macOS login
        // keychain does not return this iOS-only attribute in its item metadata.
        XCTAssertEqual(attributesDictionary[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #endif
        XCTAssertNotEqual(attributesDictionary[kSecAttrSynchronizable as String] as? Bool, true)
        let reopened = try EncryptedFileStorage(url: f.url, keychainAccount: f.account)
        XCTAssertEqual(try reopened.load(), plaintext)
        XCTAssertEqual(try f.url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testMissingKeyDoesNotReplaceExistingCiphertext() async throws {
        let f = fixture(); defer { cleanup(f.directory, f.account) }
        let disk = try EncryptedFileStorage(url: f.url, keychainAccount: f.account)
        try disk.save(Data("preserve".utf8))
        let before = try Data(contentsOf: f.url)
        XCTAssertEqual(SecItemDelete(query(f.account) as CFDictionary), errSecSuccess)
        XCTAssertThrowsError(try EncryptedFileStorage(url: f.url, keychainAccount: f.account)) { error in
            guard let storageError = error as? EncryptedFileStorage.StorageError, case .missingKey = storageError else {
                return XCTFail("Expected missingKey")
            }
        }
        XCTAssertEqual(try Data(contentsOf: f.url), before)
        var value: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query(f.account) as CFDictionary, &value), errSecItemNotFound)
    }

    func testMalformedKeyIsRejectedWithoutReplacement() async throws {
        let f = fixture(); defer { cleanup(f.directory, f.account) }
        var insert = query(f.account)
        insert[kSecValueData as String] = Data([1, 2, 3])
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(insert as CFDictionary, nil), errSecSuccess)
        XCTAssertThrowsError(try EncryptedFileStorage(url: f.url, keychainAccount: f.account)) { error in
            guard let storageError = error as? EncryptedFileStorage.StorageError, case .invalidKey = storageError else {
                return XCTFail("Expected invalidKey")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.url.path))
    }

    func testTamperRejectsAndFailedReplacementPreservesDestination() async throws {
        let f = fixture(); defer { cleanup(f.directory, f.account) }
        let disk = try EncryptedFileStorage(url: f.url, keychainAccount: f.account)
        try disk.save(Data("before".utf8))
        var bytes = try Data(contentsOf: f.url)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: f.url)
        XCTAssertThrowsError(try disk.load())
        // A non-empty directory cannot be replaced by a regular file, including as root.
        try FileManager.default.removeItem(at: f.url)
        try FileManager.default.createDirectory(at: f.url, withIntermediateDirectories: false)
        let sentinel = f.url.appendingPathComponent("keep")
        try Data("sentinel".utf8).write(to: sentinel)
        XCTAssertThrowsError(try disk.save(Data("after".utf8)))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.directory.path)
        XCTAssertEqual(leftovers, ["memory.aes"], "Failed writes must clean temporary ciphertext")
    }

    func testEncryptedMemorySurvivesRestartAndDeletion() async throws {
        let f = fixture(); defer { cleanup(f.directory, f.account) }
        let store = try MemoryStore(storage: EncryptedFileStorage(url: f.url, keychainAccount: f.account))
        try await store.remember("permanent")
        try await store.record("conversation")
        try await store.cache(question: "static", answer: "cached", timeSensitive: false)
        let preference = LearnedMemory(kind: .preference, key: "drink.preference", text: "Türk kahvesi",
            source: .userInput, confidence: 0.8, provenance: .init(sourceID: "explicit-feedback"))
        try await store.proposeLearning(preference)
        try await store.confirmLearning(id: preference.id, expectedText: preference.text)
        let ciphertext = try Data(contentsOf: f.url)
        XCTAssertNil(ciphertext.range(of: Data(preference.text.utf8)))
        let reopened = try MemoryStore(storage: EncryptedFileStorage(url: f.url, keychainAccount: f.account))
        let snapshot = try await reopened.read()
        XCTAssertEqual(snapshot.personal.map(\.text), ["permanent"])
        XCTAssertEqual(snapshot.conversations.map(\.text), ["conversation"])
        XCTAssertEqual(snapshot.answers.map(\.answer), ["cached"])
        let learned = try await reopened.learnedMemories(query: "drink.preference")
        XCTAssertEqual(learned.map(\.text), [preference.text])
        try await reopened.deleteLearning(id: preference.id)
        try await reopened.forget(id: snapshot.personal[0].id)
        let afterDelete = try MemoryStore(storage: EncryptedFileStorage(url: f.url, keychainAccount: f.account))
        let deleted = try await afterDelete.read()
        XCTAssertTrue(deleted.personal.isEmpty)
        XCTAssertTrue(deleted.learning.records.isEmpty)
        let deletedLearning = try await afterDelete.learnedMemories(query: "drink.preference")
        XCTAssertTrue(deletedLearning.isEmpty)
        // Include learning state again so deleteAll proves it clears the new encrypted schema.
        try await afterDelete.proposeLearning(preference)
        try await afterDelete.confirmLearning(id: preference.id, expectedText: preference.text)
        try await afterDelete.deleteAll()
        let erased = try MemoryStore(storage: EncryptedFileStorage(url: f.url, keychainAccount: f.account))
        let empty = try await erased.read()
        XCTAssertEqual(empty, MemorySnapshot())
    }

    #if os(iOS)
    func testIOSFileProtectionSurvivesReplacement() async throws {
        #if targetEnvironment(simulator)
        // Simulator files live on the host Mac filesystem, which does not implement iOS
        // Data Protection classes or report NSFileProtectionKey. Verify on physical iOS.
        throw XCTSkip("iOS Data Protection attributes require a physical iPhone; simulator does not expose NSFileProtectionKey.")
        #else
        let f = fixture(); defer { cleanup(f.directory, f.account) }
        let disk = try EncryptedFileStorage(url: f.url, keychainAccount: f.account)
        for value in ["first", "replacement"] {
            try disk.save(Data(value.utf8))
            let attributes = try FileManager.default.attributesOfItem(atPath: f.url.path)
            XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
            XCTAssertEqual(try disk.load(), Data(value.utf8))
        }
        #endif
    }
    #endif
}
#endif
