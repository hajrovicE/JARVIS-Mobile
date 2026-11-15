import Foundation
import XCTest
@testable import JarvisCore

private final class ReviewMemoryDisk: SnapshotStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return bytes
    }
    func save(_ contents: Data) throws {
        lock.lock(); defer { lock.unlock() }
        bytes = contents
    }
}

final class UserExperienceReviewerTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func experience(outcome: TaskOutcome, at date: Date) -> TaskExperience {
        TaskExperience(action: "memory.remember", risk: .low, outcome: outcome,
                       executionReceipt: outcome == .succeeded ? UUID().uuidString : nil,
                       createdAt: date)
    }

    func testOnlyRealCompletedTaskCanBeReviewed() async throws {
        let store = try MemoryStore(storage: ReviewMemoryDisk(), now: now)
        let reviewer = UserExperienceReviewer(store: store)
        do {
            _ = try await reviewer.review(experienceID: UUID(), verdict: .correct,
                                          lesson: "Olumlu", now: now)
            XCTFail("Unknown experience must not create evidence")
        } catch {
            XCTAssertEqual(error as? ExperienceReviewError, .missingRealExperience)
        }
        let pending = experience(outcome: .proposed, at: now)
        try await store.recordExperience(pending, now: now)
        do {
            _ = try await reviewer.review(experienceID: pending.id, verdict: .incorrect,
                                          lesson: "Böyle yapma", now: now)
            XCTFail("Proposed action has no verified outcome")
        } catch {
            XCTAssertEqual(error as? ExperienceReviewError, .incompleteExperience)
        }
        let state = try await store.read(now: now)
        XCTAssertTrue(state.learning.records.isEmpty)
    }

    func testOwnerLabelsRightWrongPrivateWithoutGrantingTools() async throws {
        let disk = ReviewMemoryDisk()
        let store = try MemoryStore(storage: disk, now: now)
        let reviewer = UserExperienceReviewer(store: store)
        let a = experience(outcome: .succeeded, at: now)
        let b = experience(outcome: .failed, at: now)
        let c = experience(outcome: .cancelled, at: now)
        for item in [a,b,c] { try await store.recordExperience(item, now: now) }

        _ = try await reviewer.review(experienceID: a.id, verdict: .correct,
                                      lesson: "Bu sonucu tekrar değerlendir.", now: now)
        _ = try await reviewer.review(experienceID: b.id, verdict: .incorrect,
                                      lesson: "Bu adımın alternatifi gerekli.", now: now)
        let privateID = try await reviewer.review(experienceID: c.id,
                         verdict: .privateInformation,
                         lesson: "Kişisel bilgi, dış servise aktarılmamalı.", now: now)
        let state = try await store.read(now: now)
        XCTAssertEqual(state.learning.records.count, 3)
        XCTAssertTrue(state.learning.records.allSatisfy(\.userConfirmed))
        XCTAssertEqual(state.learning.records.first(where: { $0.id == privateID })?.sensitivity,
                       .sensitive)
        let shareable = LocalLearningEngine().shareableContext(
            query: "", in: state.learning, now: now)
        XCTAssertEqual(shareable.count, 2)
        XCTAssertFalse(shareable.contains { $0.id == privateID })
        // A review has no ActionAuthorization, and it does not execute a task.
        let reopened = try MemoryStore(storage: disk, now: now)
        let saved = try await reopened.read(now: now)
        XCTAssertEqual(saved.learning.records.count, 3)
    }

    func testLongOwnerReviewCanBeLearnedWithoutTruncation() async throws {
        let store = try MemoryStore(storage: ReviewMemoryDisk(), now: now)
        let item = experience(outcome: .succeeded, at: now)
        try await store.recordExperience(item, now: now)
        let lesson = String(repeating: "Deneyimle doğrulandı. ", count: 100)
        _ = try await UserExperienceReviewer(store: store).review(
            experienceID: item.id, verdict: .correct, lesson: lesson, now: now)
        let records = try await store.read(now: now)
        XCTAssertEqual(records.learning.records.first?.text, "doğru: " + lesson)
    }

    func testDuplicateAndCredentialFeedbackAreRejected() async throws {
        let store = try MemoryStore(storage: ReviewMemoryDisk(), now: now)
        let item = experience(outcome: .failed, at: now)
        try await store.recordExperience(item, now: now)
        let reviewer = UserExperienceReviewer(store: store)
        do {
            _ = try await reviewer.review(experienceID: item.id, verdict: .correct,
                                          lesson: "api_key=private-secret-value", now: now)
            XCTFail("Credential contents must never be saved")
        } catch {
            XCTAssertEqual(error as? ExperienceReviewError, .secretDetected)
        }
        _ = try await reviewer.review(experienceID: item.id, verdict: .incorrect,
                                      lesson: "Daha iyi test gerekli.", now: now)
        do {
            _ = try await reviewer.review(experienceID: item.id, verdict: .correct,
                                          lesson: "Yeni bir hüküm", now: now)
            XCTFail("Duplicate review must not quietly overwrite user decisions")
        } catch {
            XCTAssertEqual(error as? ExperienceReviewError, .duplicateReview)
        }
        let result = try await reviewer.reviewedExperiences(now: now)
        XCTAssertEqual(result.count, 1)
    }

    func testTurkishCommandReviewsRecordedTasksAndDoesNotDuplicateDetails() async throws {
        let date = Date()
        let store = try MemoryStore(storage: ReviewMemoryDisk(), now: date)
        let item = experience(outcome: .succeeded, at: date)
        try await store.recordExperience(item, now: date)
        let command = CommandRouter(store: store)
        let input = "değerlendir: \(item.id.uuidString) | mahrem | Sadece cihazda tutulmalı."
        XCTAssertTrue(CommandRouter.isLocalCommand(input))
        let response = try await command.executeWithHistory(input)
        XCTAssertTrue(response.reply.contains("değerlendirildi"))
        let state = try await store.read(now: date)
        XCTAssertFalse(state.conversations.contains { $0.text.contains("Sadece cihazda") })
        XCTAssertEqual(state.learning.records.count, 1)
        XCTAssertEqual(state.learning.records.first?.sensitivity, .sensitive)
        let list = try await command.execute("değerlendirmeler")
        XCTAssertTrue(list.contains("mahrem"))
    }

    func testLocalizedVerdictIsStrict() {
        XCTAssertEqual(ExperienceVerdict(turkishName: "DOĞRU"), .correct)
        XCTAssertEqual(ExperienceVerdict(turkishName: "yanlış"), .incorrect)
        XCTAssertEqual(ExperienceVerdict(turkishName: "mahrem"), .privateInformation)
        XCTAssertNil(ExperienceVerdict(turkishName: "not-a-verdict"))
    }
}
