import XCTest
@testable import JarvisCore

final class LearningEngineTests: XCTestCase, @unchecked Sendable {
    let engine = LocalLearningEngine()
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    func record(text: String = "Türk kahvesi", confidence: Double = 0.9) -> LearnedMemory {
        LearnedMemory(kind: .preference, key: "drink.preference", text: text, source: .userInput,
                      createdAt: now, confidence: confidence,
                      provenance: .init(sourceID: "explicit-feedback", capturedAt: now))
    }
    func testPendingProposalsNeverBecomeFactsWithoutConfirmation() async throws {
        var proposed = record(confidence: 0.1); proposed.userConfirmed = true
        let pending = try engine.propose(proposed, in: LearningState(), now: now)
        XCTAssertFalse(pending.records[0].userConfirmed)
        XCTAssertTrue(engine.retrieve(query: "kahve", in: pending, now: now).isEmpty)
        let confirmed = try engine.confirm(id: proposed.id, in: pending, now: now)
        XCTAssertEqual(engine.retrieve(query: "kahve", in: confirmed, now: now).count, 1)
    }
    func testConflictCorrectionPrecedenceAndDeletion() async throws {
        let first = record(), second = record(text: "Çay")
        var state = try engine.propose(first, in: LearningState(), now: now)
        state = try engine.confirm(id: first.id, in: state, now: now)
        state = try engine.propose(second, in: state, now: now)
        XCTAssertThrowsError(try engine.confirm(id: second.id, in: state, now: now)) { XCTAssertEqual($0 as? LearningError, .conflictingRecord) }
        state = try engine.correct(id: second.id, text: "Çay tercih ederim", in: state, now: now.addingTimeInterval(1))
        let found = engine.retrieve(query: "drink.preference", in: state, now: now)
        XCTAssertEqual(found.map(\.id), [second.id]); XCTAssertEqual(found[0].source, .userCorrection)
        XCTAssertEqual(found[0].revision, 2)
        state = try engine.delete(id: second.id, in: state)
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertTrue(engine.retrieve(query: "", in: state, now: now).isEmpty)
    }
    func testExternalKnowledgeExpiresExactlyAndNeedsEvidence() async throws {
        var external = LearnedMemory(kind: .knowledge, key: "reference", text: "Source claim", source: .externalSource,
            createdAt: now, expiresAt: now.addingTimeInterval(3600), confidence: 0.8,
            provenance: .init(sourceID: "reference-1", sourceURL: URL(string: "https://example.com/source"), capturedAt: now))
        var state = try engine.propose(external, in: LearningState(), now: now)
        state = try engine.confirm(id: external.id, in: state, now: now)
        XCTAssertEqual(engine.retrieve(query: "", in: state, now: now.addingTimeInterval(3599)).count, 1)
        XCTAssertTrue(engine.retrieve(query: "", in: state, now: now.addingTimeInterval(3600)).isEmpty)
        external.expiresAt = nil
        XCTAssertThrowsError(try engine.propose(external, in: LearningState(), now: now))
        external.expiresAt = now.addingTimeInterval(30 * 86400 + 1)
        XCTAssertThrowsError(try engine.propose(external, in: LearningState(), now: now))
    }
    func testPurgeRemovesExpiredKnowledgeButKeepsDurablePreference() async throws {
        let preference = record()
        var external = LearnedMemory(kind: .knowledge, key: "reference", text: "Source claim", source: .externalSource,
            createdAt: now, expiresAt: now.addingTimeInterval(3600), confidence: 0.8,
            provenance: .init(sourceID: "reference-1", sourceURL: URL(string: "https://example.com/source"), capturedAt: now))
        var state = try engine.propose(preference, in: LearningState(), now: now)
        state = try engine.propose(external, in: state, now: now)
        state.purgeExpired(now: now.addingTimeInterval(3600))
        XCTAssertEqual(state.records.map(\.id), [preference.id])
        external.provenance.capturedAt = now.addingTimeInterval(1)
        XCTAssertThrowsError(try engine.propose(external, in: LearningState(), now: now))
    }
    func testSecretAndInvalidConfidenceRejected() async throws {
        var secret = record(); secret.sensitivity = .secret
        XCTAssertThrowsError(try engine.propose(secret, in: LearningState(), now: now)) { XCTAssertEqual($0 as? LearningError, .secretNotAllowed) }
        XCTAssertThrowsError(try engine.propose(record(confidence: .nan), in: LearningState(), now: now))
    }
    func testStateRoundTripAndSuccessfulExperienceNeedsReceipt() async throws {
        let proposed = record()
        let state = try engine.propose(proposed, in: LearningState(), now: now)
        let decoded = try JSONDecoder().decode(LearningState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        let invented = TaskExperience(action: "sensitive-action", risk: .high, outcome: .succeeded)
        XCTAssertThrowsError(try engine.recordExperience(invented, in: state)) { XCTAssertEqual($0 as? LearningError, .missingReceipt) }
        let pending = TaskExperience(action: "sensitive-action", risk: .high)
        let logged = try engine.recordExperience(pending, in: state)
        XCTAssertEqual(logged.experiences[0].outcome, .proposed)
    }
}
