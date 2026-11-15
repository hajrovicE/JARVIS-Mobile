import Foundation
import XCTest
@testable import JarvisCore

final class LearningPersistenceTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private func proposal() -> LearnedMemory {
        LearnedMemory(kind: .preference, key: "drink", text: "kahve", source: .userInput,
            confidence: 0.4, provenance: .init(sourceID: "user"))
    }
    func testMigrationOfRealV1PayloadAndLearningRestartDeletion() async throws {
        let disk = TestStorage()
        // Literal fixture excludes the new field, as an installed v1 app actually would.
        try disk.save(Data(#"{"version":1,"conversations":[],"answers":[],"personal":[]}"#.utf8))
        let store = try MemoryStore(storage: disk, now: now)
        let record = proposal()
        try await store.proposeLearning(record, now: now)
        let pending = try await store.learnedMemories(query: "drink", now: now)
        XCTAssertTrue(pending.isEmpty)
        try await store.confirmLearning(id: record.id, expectedText: record.text, now: now)
        let reopened = try MemoryStore(storage: disk, now: now)
        let results = try await reopened.learnedMemories(query: "drink", now: now)
        XCTAssertEqual(results.map(\.text), ["kahve"])
        try await reopened.correctLearning(id: record.id, text: "çay", now: now)
        let corrected = try await reopened.learnedMemories(query: "drink", now: now)
        XCTAssertEqual(corrected.map(\.text), ["çay"])
        let exported = try JSONDecoder().decode(MemorySnapshot.self, from: await reopened.export(now: now))
        XCTAssertEqual(exported.learning.records.count, 1)
        try await reopened.deleteLearning(id: record.id, now: now)
        let deleted = try MemoryStore(storage: disk, now: now)
        let empty = try await deleted.learnedMemories(query: "drink", now: now)
        XCTAssertTrue(empty.isEmpty)
    }
    func testEditedDraftCannotConfirmStoredText() async throws {
        let store = try MemoryStore(storage: TestStorage(), now: now)
        let record = proposal()
        try await store.proposeLearning(record, now: now)
        do {
            try await store.confirmLearning(id: record.id, expectedText: "çay", now: now)
            XCTFail("Changed text must require explicit correction")
        } catch { XCTAssertEqual(error as? LearningError, .staleProposal) }
        let results = try await store.learnedMemories(query: "", now: now)
        XCTAssertTrue(results.isEmpty)
    }
    func testLearningFailedWriteAndDeleteAll() async throws {
        let disk = TestStorage(); let store = try MemoryStore(storage: disk, now: now)
        disk.fail = true
        do { try await store.proposeLearning(proposal(), now: now); XCTFail("Must fail") } catch {}
        disk.fail = false
        let unchanged = try await store.read(now: now)
        XCTAssertTrue(unchanged.learning.records.isEmpty)
        try await store.proposeLearning(proposal(), now: now)
        try await store.deleteAll()
        let reopened = try MemoryStore(storage: disk, now: now)
        let empty = try await reopened.read(now: now)
        XCTAssertEqual(empty, MemorySnapshot())
    }
}
