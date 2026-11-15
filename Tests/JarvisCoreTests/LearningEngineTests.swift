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

extension LearningEngineTests {
    func testCorrectionAuditPreservesProvenanceAndDeletesWithRecord() async throws {
        let first = record(text: "eski tercih", confidence: 0.6)
        var state = try engine.propose(first, in: LearningState(), now: now)
        state = try engine.confirm(id: first.id, in: state, now: now)
        state = try engine.correct(id: first.id, text: "ara tercih", in: state, now: now.addingTimeInterval(1))
        state = try engine.correct(id: first.id, text: "yeni tercih", in: state, now: now.addingTimeInterval(2))
        let updated = try XCTUnwrap(state.records.first)
        XCTAssertEqual(updated.revision, 3)
        XCTAssertEqual(updated.revisions?.map(\.text), ["eski tercih", "ara tercih"])
        XCTAssertEqual(updated.revisions?.first?.confidence, 0.6)
        XCTAssertEqual(updated.revisions?.first?.provenance.sourceID, "explicit-feedback")
        XCTAssertEqual(updated.revisions?.first?.source, .userInput)
        XCTAssertEqual(updated.revisions?.last?.source, .userCorrection)
        let context = engine.shareableContext(query: "drink", in: state, now: now)
        XCTAssertNil(context.first?.revisions, "Default AI context must not silently include historic text")
        state = try engine.delete(id: first.id, in: state)
        let exported = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        XCTAssertFalse(exported.contains("eski tercih")); XCTAssertFalse(exported.contains("yeni tercih"))
        XCTAssertTrue(state.records.isEmpty)
    }

    func testTaskCorrectionRequiresConfirmationAndSurvivesTaskHistoryExpiry() async throws {
        let experience = TaskExperience(action: "plan.route", risk: .low, outcome: .failed, error: "unavailable", createdAt: now)
        var state = try engine.recordExperience(experience, in: LearningState())
        state = try engine.proposeTaskCorrection(experienceID: experience.id, key: "task.route", text: "Merdivensiz rota seç", in: state, now: now)
        let proposed = try XCTUnwrap(state.records.first)
        XCTAssertFalse(proposed.userConfirmed)
        XCTAssertEqual(proposed.source, .taskResult)
        XCTAssertEqual(state.experiences.first?.correctionMemoryID, proposed.id)
        XCTAssertTrue(engine.retrieve(query: "task.route", in: state, now: now).isEmpty)
        state = try engine.confirm(id: proposed.id, in: state, now: now)
        XCTAssertEqual(engine.retrieve(query: "task.route", in: state, now: now).map(\.text), ["Merdivensiz rota seç"])
        state.purgeExpired(now: now.addingTimeInterval(90 * 86400 - 1))
        XCTAssertEqual(state.experiences.count, 1)
        state.purgeExpired(now: now.addingTimeInterval(90 * 86400))
        XCTAssertTrue(state.experiences.isEmpty)
        XCTAssertEqual(state.records.count, 1, "Approved rules remain durable after task history expires")
    }

    func testDeletingTaskCorrectionRemovesRelatedExperienceAndRevisionContents() async throws {
        let experience = TaskExperience(action: "plan.route", risk: .low, outcome: .failed, result: "yanlış öğrenilen sonuç", createdAt: now)
        var state = try engine.recordExperience(experience, in: LearningState())
        state = try engine.proposeTaskCorrection(experienceID: experience.id, key: "task.route", text: "yanlış öğrenilen kural", in: state, now: now)
        let proposalID = try XCTUnwrap(state.records.first?.id)
        state = try engine.correct(id: proposalID, text: "düzeltilmiş kural", in: state, now: now)
        state = try engine.delete(id: proposalID, in: state)
        XCTAssertTrue(state.experiences.isEmpty)
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(state), as: UTF8.self).contains("yanlış"))
    }

    func testTransitiveSupersessionDeletionCannotResurrectOldRecords() async throws {
        var oldest = record(text: "oldest"), older = record(text: "older"), newest = record(text: "newest")
        oldest.supersededBy = older.id; older.supersededBy = newest.id
        oldest.userConfirmed = true; older.userConfirmed = true; newest.userConfirmed = true
        var state = LearningState(); state.records = [oldest, older, newest]
        state = try engine.delete(id: newest.id, in: state)
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertTrue(engine.retrieve(query: "", in: state, now: now).isEmpty)
    }

    func testOldV2RecordsDecodeWithoutRevisionOrTaskCorrectionFields() async throws {
        var state = try engine.propose(record(), in: LearningState(), now: now)
        state = try engine.recordExperience(.init(action: "task", risk: .low), in: state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var records = try XCTUnwrap(object["records"] as? [[String: Any]])
        records[0].removeValue(forKey: "revisions"); object["records"] = records
        var experiences = try XCTUnwrap(object["experiences"] as? [[String: Any]])
        experiences[0].removeValue(forKey: "correctionMemoryID"); object["experiences"] = experiences
        let oldData = try JSONSerialization.data(withJSONObject: object)
        var decoded = try JSONDecoder().decode(LearningState.self, from: oldData)
        XCTAssertNil(decoded.records[0].revisions); XCTAssertNil(decoded.experiences[0].correctionMemoryID)
        decoded = try engine.correct(id: decoded.records[0].id, text: "Çay", in: decoded, now: now)
        XCTAssertEqual(decoded.records[0].revisions?.count, 1)
    }

    func testCredentialPatternsBlockedOnProposalCorrectionAuditAndDefaultContext() async throws {
        let credentials = [
            "api_key=secret-value-123", "Authorization: Bearer abcdefghijklmnop",
            "-----BEGIN PRIVATE KEY-----", "şifre: gizli-deger", "otp=123456",
            "sk-proj-abcdefghijklmnopqrstuvwxyz", "https://user:password@example.com",
            "APP_ACCESS_TOKEN=opaque-random-session-value"
        ]
        for value in credentials {
            XCTAssertTrue(CredentialFilter.containsCredential(value))
            XCTAssertThrowsError(try engine.propose(record(text: value), in: LearningState(), now: now))
        }
        var state = try engine.propose(record(), in: LearningState(), now: now)
        let id = try XCTUnwrap(state.records.first?.id)
        XCTAssertThrowsError(try engine.correct(id: id, text: credentials[0], in: state, now: now))
        XCTAssertEqual(state.records[0].text, "Türk kahvesi")
        var sensitive = record(text: "özel sağlık tercihi"); sensitive.sensitivity = .sensitive
        state = try engine.propose(sensitive, in: state, now: now)
        state = try engine.confirm(id: sensitive.id, in: state, now: now)
        XCTAssertEqual(engine.retrieve(query: "", in: state, now: now).count, 1)
        XCTAssertTrue(engine.shareableContext(query: "", in: state, now: now).isEmpty)
        let secretAudit = TaskExperience(action: "task", risk: .low, result: credentials[0])
        XCTAssertThrowsError(try engine.recordExperience(secretAudit, in: state))
        XCTAssertFalse(CredentialFilter.containsCredential("Kahveyi az şekerli severim"))
    }
}
