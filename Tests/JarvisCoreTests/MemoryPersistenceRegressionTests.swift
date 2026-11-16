import Foundation
import XCTest
@testable import JarvisCore
#if canImport(Security)
import Security
#endif

/// These tests exercise the migration transaction with decoded legacy payloads.
/// The Apple-only test below separately exercises actual AES-GCM/Keychain input.
final class MemoryPersistenceRegressionTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func directory() throws -> URL {
        let value = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    func testLegacyMigrationValidatesUpgradesAndRemovesSourceAfterCommit() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let json = root.appendingPathComponent("memory.json")
        let legacy = root.appendingPathComponent("memory.aes")
        let encryptedMarker = Data("opaque legacy ciphertext fixture".utf8)
        try encryptedMarker.write(to: legacy)
        var old = MemorySnapshot(); old.version = 1
        old.personal = [.init(text: "sütlü kahve", createdAt: now)]
        old.conversations = [.init(text: "eski konuşma", createdAt: .distantPast)]
        let storage = try PlainFileStorage.migratingLegacySnapshot(to: json, legacyURL: legacy) {
            XCTAssertEqual(try Data(contentsOf: legacy), encryptedMarker)
            return try JSONEncoder().encode(old)
        }
        let decoded = try MemorySnapshot.decodeSupported(from: XCTUnwrap(storage.load()))
        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(decoded.personal, old.personal)
        XCTAssertEqual(decoded.conversations, old.conversations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let reopened = try MemoryStore(storage: PlainFileStorage(url: json), now: now)
        let state = try await reopened.read(now: now)
        XCTAssertEqual(state.personal, old.personal)
        XCTAssertEqual(state.conversations, old.conversations)
    }

    func testExistingJSONWinsWithoutKeyLookupAndDeletedDataCannotResurrect() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let json = root.appendingPathComponent("memory.json")
        let legacy = root.appendingPathComponent("memory.aes")
        var current = MemorySnapshot(); current.personal = [.init(text: "güncel", createdAt: now)]
        let original = try JSONEncoder().encode(current)
        try original.write(to: json)
        try Data("unreadable old ciphertext".utf8).write(to: legacy)
        let storage = try PlainFileStorage.migratingLegacySnapshot(to: json, legacyURL: legacy) {
            XCTFail("A committed JSON snapshot must never require the legacy Keychain key")
            throw CocoaError(.fileReadNoPermission)
        }
        XCTAssertEqual(try storage.load(), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let store = try MemoryStore(storage: storage, now: now)
        try await store.deleteAll()
        let relaunchedStorage = try PlainFileStorage.migratingLegacySnapshot(to: json, legacyURL: legacy) {
            XCTFail("An owner erase must not reload deleted legacy data")
            return try JSONEncoder().encode(current)
        }
        let relaunched = try MemoryStore(storage: relaunchedStorage, now: now)
        let empty = try await relaunched.read(now: now)
        XCTAssertEqual(empty, MemorySnapshot())
    }

    func testInvalidLegacyDoesNotCreateJSONOrDestroySource() throws {
        let invalidPayloads = [Data("not JSON".utf8), Data(#"{"version":99}"#.utf8), Data(#"{"version":3}"#.utf8)]
        for payload in invalidPayloads {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let json = root.appendingPathComponent("memory.json")
            let legacy = root.appendingPathComponent("memory.aes")
            let marker = Data("preserve me".utf8); try marker.write(to: legacy)
            XCTAssertThrowsError(try PlainFileStorage.migratingLegacySnapshot(to: json, legacyURL: legacy) { payload })
            XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
            XCTAssertEqual(try Data(contentsOf: legacy), marker)
        }
    }

    func testMissingLegacyKeyAndEmptyLegacyDoNotOverwriteSource() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let json = root.appendingPathComponent("memory.json")
        let legacy = root.appendingPathComponent("memory.aes")
        let marker = Data("ciphertext".utf8); try marker.write(to: legacy)
        XCTAssertThrowsError(try PlainFileStorage.migratingLegacySnapshot(to: json, legacyURL: legacy) {
            throw CocoaError(.fileReadNoPermission)
        })
        XCTAssertThrowsError(try PlainFileStorage.migratingLegacySnapshot(to: json, legacyURL: legacy) { nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
        XCTAssertEqual(try Data(contentsOf: legacy), marker)
    }

    func testInvalidCurrentJSONIsNotSilentlyReplacedByLegacy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let json = root.appendingPathComponent("memory.json")
        let legacy = root.appendingPathComponent("memory.aes")
        let corrupt = Data("broken current JSON".utf8)
        let marker = Data("preserved legacy".utf8)
        try corrupt.write(to: json); try marker.write(to: legacy)
        XCTAssertThrowsError(try PlainFileStorage.migratingLegacySnapshot(to: json, legacyURL: legacy) {
            XCTFail("Invalid current data must surface an error, never silently roll back")
            return try JSONEncoder().encode(MemorySnapshot())
        })
        XCTAssertEqual(try Data(contentsOf: json), corrupt)
        XCTAssertEqual(try Data(contentsOf: legacy), marker)
    }

    func testFailedMigrationWritePreservesLegacy() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let json = root.appendingPathComponent("memory.json")
        let legacy = root.appendingPathComponent("memory.aes")
        let marker = Data("legacy source".utf8); try marker.write(to: legacy)
        XCTAssertThrowsError(try PlainFileStorage.migratingLegacySnapshot(to: json, legacyURL: legacy) {
            // Deterministically block the destination after its initial absence was read.
            try FileManager.default.createDirectory(at: json, withIntermediateDirectories: false)
            return try JSONEncoder().encode(MemorySnapshot())
        })
        XCTAssertEqual(try Data(contentsOf: legacy), marker)
    }

    func testCurrentSnapshotCanOpenReadAndExportWhenWritesFail() async throws {
        let disk = TestStorage()
        var initial = MemorySnapshot(); initial.personal = [.init(text: "okunabilir", createdAt: now)]
        let original = try JSONEncoder().encode(initial); try disk.save(original)
        disk.fail = true
        let store = try MemoryStore(storage: disk, now: now)
        let state = try await store.read(now: now)
        XCTAssertEqual(state, initial)
        let export = try await store.export(now: now)
        XCTAssertEqual(try MemorySnapshot.decodeSupported(from: export), initial)
        do { try await store.remember("yazılamaz", now: now); XCTFail("Write must fail") } catch {}
        XCTAssertEqual(try disk.load(), original)
        let unchanged = try await store.read(now: now)
        XCTAssertEqual(unchanged, initial)
    }

    func testContextChangesInvalidateReuseWithoutErasingOwnerHistory() async throws {
        let disk = TestStorage(); let store = try MemoryStore(storage: disk, now: now)
        try await store.record("önceki konuşma", now: now)
        try await store.cache(question: "tercihim", answer: "eski tercih", timeSensitive: false, now: now)
        let (_, epoch) = try await store.aiContextSnapshot(now: now)
        let response = AIResponse(text: "arşivlenmiş model cevabı", provider: "local", model: "fixture", generatedAt: now)
        let answer = StoredAIAnswer(question: "soru", response: response, savedAt: now,
                                   cacheUntil: now.addingTimeInterval(3600), cacheScope: "local", contextIDs: [])
        try await store.recordGeneratedAnswer(answer, expectedEpoch: epoch)
        // Cache-only bookkeeping cannot invalidate an in-flight response.
        try await store.validateAIContext(expectedEpoch: epoch)
        try await store.remember("yeni tercih", now: now)
        let cached = try await store.cachedAnswer(question: "tercihim", timeSensitive: false, now: now)
        XCTAssertNil(cached)
        let preserved = try await store.read(now: now)
        XCTAssertEqual(preserved.answers.map(\.answer), ["eski tercih"])
        XCTAssertEqual(preserved.answers.first?.invalidated, true)
        XCTAssertEqual(preserved.conversations.map(\.text), ["önceki konuşma"])
        XCTAssertEqual(preserved.generatedAnswers.first?.response, response)
        XCTAssertNil(preserved.generatedAnswers.first?.cacheUntil)
        do { try await store.validateAIContext(expectedEpoch: epoch); XCTFail("Old context must be invalidated") }
        catch { XCTAssertEqual(error as? AssistantError, .contextChanged) }
        let relaunched = try MemoryStore(storage: disk, now: now.addingTimeInterval(1000 * 86400))
        let retained = try await relaunched.read(now: now.addingTimeInterval(1000 * 86400))
        XCTAssertEqual(retained, preserved)
    }

    func testCacheFreshnessBoundariesAndClockRollbackDoNotDeleteRecords() async throws {
        let store = try MemoryStore(storage: TestStorage(), now: now)
        try await store.cache(question: "soru", answer: "cevap", timeSensitive: false, now: now)
        let tooEarly = try await store.cachedAnswer(question: "soru", timeSensitive: false, now: now.addingTimeInterval(-1))
        let justValid = try await store.cachedAnswer(question: "soru", timeSensitive: false, now: now.addingTimeInterval(30 * 86400 - 1))
        let expired = try await store.cachedAnswer(question: "soru", timeSensitive: false, now: now.addingTimeInterval(30 * 86400))
        XCTAssertNil(tooEarly); XCTAssertEqual(justValid, "cevap"); XCTAssertNil(expired)
        let state = try await store.read(now: now.addingTimeInterval(1000 * 86400))
        XCTAssertEqual(state.answers.map(\.answer), ["cevap"])
    }

    func testActivityClockRollbackPreservesEventsButExcludesFutureEvidence() async throws {
        let disk = TestStorage()
        let recordedAt = now.addingTimeInterval(3600)
        let journal = try ActivityLearningJournal(storage: disk, now: recordedAt)
        try await journal.setEnabled(true, now: recordedAt)
        try await journal.record(.voiceInputFinished, at: recordedAt)
        let reopened = try ActivityLearningJournal(storage: disk, now: now)
        let retained = try await reopened.read(now: now)
        XCTAssertEqual(retained.observations.map(\.recordedAt), [recordedAt])
        let premature = try await reopened.insights(now: now)
        XCTAssertTrue(premature.isEmpty)
        let eligible = try await reopened.insights(now: recordedAt)
        XCTAssertEqual(eligible.first?.id, "input.voice")
        XCTAssertEqual(eligible.first?.evidenceCount, 1)
    }

    func testCurrentActivityJournalRemainsReadableWhenWritesFail() async throws {
        let disk = TestStorage()
        var initial = ActivityJournalSnapshot()
        initial.enabled = true
        initial.observations = [.init(kind: .typedCommand, recordedAt: now)]
        let original = try JSONEncoder().encode(initial)
        try disk.save(original)
        disk.fail = true
        let journal = try ActivityLearningJournal(storage: disk, now: now)
        let state = try await journal.read(now: now)
        XCTAssertEqual(state, initial)
        let insights = try await journal.insights(now: now)
        XCTAssertEqual(insights.first?.id, "input.typed")
        do { try await journal.setEnabled(false, now: now); XCTFail("Write must fail") } catch {}
        let unchanged = try await journal.read(now: now)
        XCTAssertEqual(unchanged, initial)
        XCTAssertEqual(try disk.load(), original)
    }

    #if canImport(CryptoKit) && canImport(Security)
    func testRealEncryptedSnapshotMigratesToJSONWithoutResurrection() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("memory.aes")
        let json = root.appendingPathComponent("memory.json")
        let account = "migration-regression-\(UUID())"
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: "com.jarvis.mobile.storage",
                           kSecAttrAccount as String: account] as CFDictionary)
        }
        let encrypted = try EncryptedFileStorage(url: legacy, keychainAccount: account)
        let original = try MemoryStore(storage: encrypted, now: now)
        try await original.remember("gerçek AES geçişi", now: now)
        let storage = try PlainFileStorage.migratingLegacySnapshot(to: json, legacyURL: legacy) {
            try encrypted.load()
        }
        let migrated = try MemoryStore(storage: storage, now: now)
        let state = try await migrated.read(now: now)
        XCTAssertEqual(state.personal.map(\.text), ["gerçek AES geçişi"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let plaintext = try String(contentsOf: json, encoding: .utf8)
        XCTAssertTrue(plaintext.contains("gerçek AES geçişi"))
        try await migrated.deleteAll()
        let reopened = try MemoryStore(storage: PlainFileStorage(url: json), now: now)
        let empty = try await reopened.read(now: now)
        XCTAssertEqual(empty, MemorySnapshot())
    }
    #endif
}
