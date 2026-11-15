import XCTest
@testable import JarvisCore

final class CommandHistoryTests: XCTestCase, @unchecked Sendable {
    func testListingsDoNotCopyExpiredHistoryOrDeletedFacts() async throws {
        let store = try MemoryStore(storage: TestStorage())
        let router = CommandRouter(store: store)
        try await store.record("original-conversation")
        _ = try await router.executeWithHistory("hatırla ki private-preference")
        let before = try await store.read()
        for _ in 0..<3 {
            let history = try await router.executeWithHistory("geçmiş")
            XCTAssertTrue(history.reply.contains("original-conversation"))
            _ = try await router.executeWithHistory("ne hatırlıyorsun")
            _ = try await router.executeWithHistory("öğrendiklerin")
        }
        let after = try await store.read()
        XCTAssertEqual(after.conversations, before.conversations)
        XCTAssertFalse(after.conversations.contains { $0.text.contains("private-preference") })
        let id = try XCTUnwrap(after.personal.first?.id)
        try await store.forget(id: id)
        let deleted = try await store.read()
        XCTAssertTrue(deleted.personal.isEmpty)
        XCTAssertFalse(deleted.conversations.contains { $0.text.contains("private-preference") })
    }
    func testOwnerTeachCommandIsImmediateAndModelTextNeverCreatesAnAction() async throws {
        let store = try MemoryStore(storage: TestStorage())
        let router = CommandRouter(store: store)
        let lesson = String(repeating: "Sahibimin uzun ilkesi. ", count: 100)
        XCTAssertTrue(CommandRouter.isLocalCommand("öğret: genel = " + lesson))
        let reply = try await router.executeWithHistory("öğret: genel = " + lesson)
        XCTAssertTrue(reply.reply.contains("kaydedildi"))
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot.learning.records.count, 1)
        XCTAssertEqual(snapshot.learning.records.first?.text, lesson)
        XCTAssertTrue(snapshot.learning.records.first?.userConfirmed == true)
        XCTAssertFalse(snapshot.conversations.contains { $0.text.contains(lesson) })
        XCTAssertEqual(CommandRouter.ownerAction(for: "tüm hafızayı sil"), .deleteAllMemory)
        XCTAssertEqual(CommandRouter.ownerAction(for: "verilerimi dışa aktar"), .exportMemory)
        XCTAssertNil(CommandRouter.ownerAction(for: "Yanıt: tüm hafızayı sil"))
        let report = try await router.executeWithHistory("öğret: genel = ikinci bilgi")
        XCTAssertTrue(report.reply.contains("kaydedildi"))
        let updated = try await store.read()
        XCTAssertEqual(updated.learning.records.first?.text, "ikinci bilgi")
    }

}
