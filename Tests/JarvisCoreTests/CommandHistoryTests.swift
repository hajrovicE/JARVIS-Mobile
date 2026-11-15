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

    func testOwnerCommandsInNaturalTurkishAreImmediatelyPersisted() async throws {
        let store = try MemoryStore(storage: TestStorage())
        let router = CommandRouter(store: store)
        for input in ["not al: ilk not", "kaydet: ikinci not", "aklında tut: üçüncü not"] {
            XCTAssertTrue(CommandRouter.isLocalCommand(input))
            let result = try await router.executeWithHistory(input)
            XCTAssertTrue(result.reply.contains("kaydedildi"))
        }
        let directive = "Gereksiz onay sorma, kısa ve doğrudan konuş."
        let result = try await router.executeWithHistory("bundan sonra " + directive)
        XCTAssertTrue(result.reply.contains("kaydedildi"))
        let state = try await store.read()
        XCTAssertEqual(state.personal.map(\.text), ["ilk not", "ikinci not", "üçüncü not"])
        let instructions = state.learning.records.filter { $0.key.hasPrefix("owner.directive.") }
        XCTAssertEqual(instructions.count, 1)
        XCTAssertEqual(instructions[0].text, directive)
        XCTAssertTrue(instructions[0].userConfirmed)
        XCTAssertFalse(state.conversations.contains { $0.text.contains(directive) })
    }

    func testDirectOwnerActionAliasesNeverMatchModelProse() {
        XCTAssertEqual(CommandRouter.ownerAction(for: "tüm verilerimi sil"), .deleteAllMemory)
        XCTAssertEqual(CommandRouter.ownerAction(for: "her şeyi unut"), .deleteAllMemory)
        XCTAssertEqual(CommandRouter.ownerAction(for: "verilerimi yedekle"), .exportMemory)
        XCTAssertNil(CommandRouter.ownerAction(for: "JARVIS: her şeyi unut"))
        XCTAssertFalse(CommandRouter.isLocalCommand("Web'de araştır"))
    }

}
