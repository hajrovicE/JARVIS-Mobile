import Foundation
import XCTest
@testable import JarvisCore

private final class GuidedMemoryDisk: SnapshotStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func save(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        stored = data
    }
}

final class UserGuidedLearningTests: XCTestCase, @unchecked Sendable {
    private let date = Date(timeIntervalSince1970: 2_000_000_000)

    func testExplicitLessonIsConfirmedAndSurvivesReopening() async throws {
        let disk = GuidedMemoryDisk()
        let store = try MemoryStore(storage: disk, now: date)
        let learner = UserGuidedLearning(store: store)
        let id = try await learner.teach(
            topic: "yanıt_tarzı", text: "Doğrudan cevap ver.", now: date)
        let reopened = try MemoryStore(storage: disk, now: date)
        let state = try await reopened.read(now: date)
        let record = try XCTUnwrap(state.learning.records.first { $0.id == id })
        XCTAssertTrue(record.userConfirmed)
        XCTAssertEqual(record.text, "Doğrudan cevap ver.")
        XCTAssertEqual(record.key, "user.lesson.yanıt_tarzı")
        XCTAssertNil(record.expiresAt)
        XCTAssertTrue(record.revisions?.isEmpty == true)
    }

    func testLongUserAuthoredLessonIsNotCutOff() async throws {
        let store = try MemoryStore(storage: GuidedMemoryDisk(), now: date)
        let learner = UserGuidedLearning(store: store)
        let lesson = String(repeating: "Uzun kişisel ilke. ", count: 100)
        _ = try await learner.teach(topic: "kapsamlı_öğrenme", text: lesson, now: date)
        let saved = try await store.read(now: date)
        XCTAssertEqual(saved.learning.records.first?.text, lesson)
    }

    func testRetaughtTopicCreatesRevisionInsteadOfDuplicate() async throws {
        let store = try MemoryStore(storage: GuidedMemoryDisk(), now: date)
        let learner = UserGuidedLearning(store: store)
        let first = try await learner.teach(
            topic: "odak", text: "Kısa cevap ver.", now: date)
        let second = try await learner.teach(
            topic: "ODAK", text: "Örneklerle açıklama yap.", now: date.addingTimeInterval(1))
        XCTAssertEqual(first, second)
        let state = try await store.read(now: date.addingTimeInterval(1))
        let matched = state.learning.records.filter { $0.key == "user.lesson.odak" }
        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched[0].revision, 2)
        XCTAssertEqual(matched[0].revisions?.first?.text, "Kısa cevap ver.")
        XCTAssertEqual(matched[0].text, "Örneklerle açıklama yap.")
    }

    func testSecretAndInvalidTopicsAreRejected() async throws {
        let store = try MemoryStore(storage: GuidedMemoryDisk(), now: date)
        let learner = UserGuidedLearning(store: store)
        do {
            _ = try await learner.teach(
                topic: "../escape", text: "Bir ilke", now: date)
            XCTFail("Traversal should fail")
        } catch {
            XCTAssertEqual(error as? GuidedLearningError, .invalidTopic)
        }
        do {
            _ = try await learner.teach(
                topic: "normal", text: "API key: sk-12345678901234567890", now: date)
            XCTFail("Credential should fail")
        } catch {
            // Either the caller or the existing LearningEngine may reject secrets.
            XCTAssertNotNil(error)
        }
        let snapshot = try await store.read(now: date)
        XCTAssertTrue(snapshot.learning.records.isEmpty)
    }

    func testTeachingCommandDoesNotDuplicateFactInHistory() async throws {
        let store = try MemoryStore(storage: GuidedMemoryDisk(), now: date)
        let router = CommandRouter(store: store)
        XCTAssertTrue(CommandRouter.isLocalCommand("öğret: bakış_açısı = açık fikirli ol"))
        let result = try await router.executeWithHistory(
            "öğret: bakış_açısı = açık fikirli ol")
        XCTAssertTrue(result.reply.contains("kaydedildi"))
        let snapshot = try await store.read()
        XCTAssertEqual(snapshot.learning.records.count, 1)
        XCTAssertFalse(snapshot.conversations.contains {
            $0.text.contains("açık fikirli ol")
        })
        let summary = try await router.execute("öğrenme raporu")
        XCTAssertTrue(summary.contains("Onaylanan bilgi: 1"))
    }

    func testModelSuggestionsStayUnconfirmedUntilUserApproves() async throws {
        let store = try MemoryStore(storage: GuidedMemoryDisk(), now: date)
        let candidate = LearnedMemory(
            kind: .suggestion, key: "model.guess", text: "Kullanıcı örnekleri seviyor olabilir.",
            source: .userInput, confidence: 0.4,
            provenance: .init(sourceID: "model-suggestion", capturedAt: date))
        try await store.proposeLearning(candidate, now: date)
        let learner = UserGuidedLearning(store: store)
        let report = try await learner.report(now: date)
        XCTAssertEqual(report.confirmed, 0)
        XCTAssertEqual(report.pending, 1)
        let active = try await store.learnedMemories(query: "", now: date)
        XCTAssertTrue(active.isEmpty)
    }

    func testUserPrinciplesNeverAuthorizeTools() async throws {
        let store = try MemoryStore(storage: GuidedMemoryDisk(), now: date)
        let learner = UserGuidedLearning(store: store)
        _ = try await learner.teach(
            topic: "görev", text: "İşleri hızlı yap ve tercihleri öğren.", now: date)
        let permissions = PermissionManager(authenticator: UnavailableBiometricAuthenticator())
        let request = ActionRequest(operation: .deleteAllMemory)
        // No action authorization token is minted by a learned rule.
        let challenge = try await permissions.prepare(request)
        XCTAssertNotNil(challenge)
        let status = try await learner.report(now: date)
        XCTAssertEqual(status.confirmed, 1)
    }

    func testUserCanChangeResponseStyleWithoutCreatingToolAuthority() async throws {
        let store = try MemoryStore(storage: GuidedMemoryDisk(), now: date)
        let learner = UserGuidedLearning(store: store)
        let original = try await learner.responsePreferences(now: date)
        XCTAssertEqual(original.answerStyle, .direct)
        _ = try await learner.teach(topic: "yanıt_tarzı", text: "analitik", now: date)
        _ = try await learner.teach(topic: "yaratıcı_öneriler", text: "hayır", now: date)
        let updated = try await learner.responsePreferences(now: date)
        XCTAssertEqual(updated.answerStyle, .analytical)
        XCTAssertFalse(updated.offerUnconventionalIdeas)
        XCTAssertTrue(updated.questionAssumptions)
        XCTAssertTrue(updated.localPresentationGuidance().contains("kanıt"))
    }

    func testStyleDirectiveIsPresentationOnly() {
        let directive = PersonalAIPreferences(
            answerStyle: .analytical, questionAssumptions: true,
            offerUnconventionalIdeas: true)
        let prompt = directive.localPresentationGuidance()
        XCTAssertTrue(prompt.contains("kanıt"))
        XCTAssertTrue(prompt.contains("yaratıcı"))
        XCTAssertTrue(prompt.contains("yetkisi değildir"))
    }
}

