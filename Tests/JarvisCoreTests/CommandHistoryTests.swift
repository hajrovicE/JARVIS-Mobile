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
}
