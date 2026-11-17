import Foundation
import XCTest
@testable import JarvisCore

final class LocalConversationContextTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testRelevantMemoryWinsOverUnrelatedNotes() async throws {
        var state = MemorySnapshot()
        for index in 0..<70 {
            state.personal.append(MemoryItem(text: "Not \(index): ilgisiz bir kayıt",
                                             createdAt: now.addingTimeInterval(Double(index))))
        }
        let relevant = MemoryItem(text: "Benim kahve tercihim şekersiz espresso.",
                                  createdAt: now.addingTimeInterval(-100))
        state.personal.append(relevant)
        let chosen = LocalConversationContext.select(
            state: state, query: "Kahve tercihim neydi?",
            consent: AISharingConsent(personalMemory: true), now: now)
        XCTAssertTrue(chosen.contains { $0.id == "personal:\(relevant.id)" })
        XCTAssertLessThanOrEqual(chosen.count, LocalConversationContext.maxEntries)
    }

    func testShortAndRelevantContextUnderStrictBudget() async throws {
        var state = MemorySnapshot()
        state.personal = (0..<100).map { index in
            MemoryItem(text: "Kayıt \(index) " + String(repeating: "a", count: 3_000),
                       createdAt: now.addingTimeInterval(Double(index)))
        }
        let chosen = LocalConversationContext.select(
            state: state, query: "Kayıt",
            consent: AISharingConsent(personalMemory: true), now: now)
        XCTAssertLessThanOrEqual(chosen.count, 7)
        XCTAssertLessThanOrEqual(chosen.reduce(0) { $0 + $1.text.count }, 3_600)
        XCTAssertTrue(chosen.allSatisfy { !$0.text.isEmpty })
        XCTAssertTrue(chosen.allSatisfy { entry in state.personal.contains { $0.text == entry.text } }, "Saved facts must be kept whole")
    }

    func testConsentIsolationAndSensitiveLearnedMemories() async throws {
        var state = MemorySnapshot()
        state.personal.append(MemoryItem(text: "özel kişisel bilgi", createdAt: now))
        var ordinary = LearnedMemory(
            kind: .preference, key: "drink", text: "Kahve",
            source: .userInput, createdAt: now, confidence: 1,
            provenance: LearningProvenance(sourceID: "user", capturedAt: now))
        ordinary.userConfirmed = true
        var sensitive = LearnedMemory(
            kind: .preference, key: "private", text: "Mahrem detay",
            source: .userInput, createdAt: now, confidence: 1, sensitivity: .sensitive,
            provenance: LearningProvenance(sourceID: "user", capturedAt: now))
        sensitive.userConfirmed = true
        state.learning.records = [ordinary, sensitive]
        let none = LocalConversationContext.select(
            state: state, query: "Kahve",
            consent: AISharingConsent(), now: now)
        XCTAssertTrue(none.isEmpty)
        let learning = LocalConversationContext.select(
            state: state, query: "Kahve",
            consent: AISharingConsent(confirmedLearning: true), now: now)
        XCTAssertTrue(learning.contains { $0.text.contains("Kahve") })
        XCTAssertFalse(learning.contains { $0.text.contains("Mahrem") || $0.text.contains("kişisel") })
    }

    func testRecentFollowupRepliesRemainWhenHistoryOptedIn() async throws {
        var state = MemorySnapshot()
        let previous = StoredAIAnswer(
            question: "Nerede kaldık?",
            response: AIResponse(text: "Kitap önerilerindeydik.", provider: "local-device",
                                 model: "tiny", generatedAt: now),
            savedAt: now, cacheUntil: nil, cacheScope: "local", contextIDs: [])
        state.generatedAnswers = [previous]
        let selected = LocalConversationContext.select(
            state: state, query: "Başka bir tane öner.",
            consent: AISharingConsent(recentHistory: true), now: now)
        XCTAssertTrue(selected.contains { $0.text.contains("Kitap önerilerindeydik") })
        let privatePrevious = StoredAIAnswer(
            question: "Gizli bilgi?",
            response: AIResponse(text: "Özel cevap.", provider: "local-device",
                                 model: "tiny", generatedAt: now),
            savedAt: now, cacheUntil: nil, cacheScope: "local",
            contextIDs: ["derived:personal"])
        state.generatedAnswers = [privatePrevious]
        let hidden = LocalConversationContext.select(
            state: state, query: "Devam",
            consent: AISharingConsent(personalMemory: false, recentHistory: true), now: now)
        XCTAssertTrue(hidden.isEmpty)
    }

    func testDuplicatedSameTextIsNotRepeated() async throws {
        var state = MemorySnapshot()
        for _ in 0..<9 {
            state.personal.append(MemoryItem(text: "Öğretildi: aynı tercih", createdAt: now))
        }
        let selected = LocalConversationContext.select(
            state: state, query: "tercih",
            consent: AISharingConsent(personalMemory: true), now: now)
        XCTAssertEqual(selected.count, 1)
    }
}

extension LocalConversationContextTests {
    private func knowledge(_ text: String = "Ankara hava sıcaklığı 20 derece", key: String = "hava.ankara",
                           source: LearningSource = .externalSource, confidence: Double = 0.9,
                           capturedAt: Date? = nil, expiresAt: Date? = nil) -> LearnedMemory {
        var record = LearnedMemory(kind: .knowledge, key: key, text: text, source: source,
            createdAt: now.addingTimeInterval(-60), expiresAt: expiresAt ?? now.addingTimeInterval(3600),
            confidence: confidence, provenance: .init(sourceID: "owner-verified-source",
                sourceURL: URL(string: "https://example.com/weather"),
                capturedAt: capturedAt ?? now.addingTimeInterval(-60)))
        record.userConfirmed = true
        return record
    }

    func testUnrelatedQuestionDoesNotReceivePersonalMemoryOrLastDialogue() async throws {
        var state = MemorySnapshot()
        state.personal = [.init(text: "Kahve tercihim espresso", createdAt: now)]
        state.generatedAnswers = [.init(question: "Kahve tercihimi hatırlıyor musun?",
            response: .init(text: "Espresso.", provider: "local", model: "fixture", generatedAt: now),
            savedAt: now, cacheUntil: nil, cacheScope: "local", contextIDs: [])]
        let selected = LocalConversationContext.select(state: state, query: "Swift ile sıralama algoritmasını açıkla",
            consent: .init(personalMemory: true, recentHistory: true), now: now)
        XCTAssertTrue(selected.isEmpty)
        XCTAssertEqual(state.generatedAnswers.count, 1, "Retrieval must not delete history")
    }

    func testTurkishSuffixAndSynonymMatchingRetainsWholeQualifiedFact() async throws {
        var state = MemorySnapshot()
        let fact = "Espresso tercihim: " + String(repeating: "önemli ayrıntı ", count: 70) + "şeker kesinlikle ekleme."
        state.personal = [.init(text: fact, createdAt: now)]
        let selected = LocalConversationContext.select(state: state, query: "Kahveyi nasıl içiyorum?",
            consent: .init(personalMemory: true), now: now)
        XCTAssertEqual(selected.map(\.text), [fact])
        XCTAssertTrue(selected[0].text.hasSuffix("şeker kesinlikle ekleme."))
    }

    func testNewestOwnerCorrectionWinsAndHistoricRevisionIsNotInjected() async throws {
        var state = MemorySnapshot()
        var old = knowledge("Ankara hava sıcaklığı 10 derece")
        old.source = .userInput
        var corrected = knowledge("Ankara hava sıcaklığı 20 derece", source: .userCorrection)
        corrected.updatedAt = now
        corrected.revisions = [LearningRevision(record: old)]
        old.updatedAt = now.addingTimeInterval(-20)
        state.learning.records = [old, corrected]
        let selected = LocalConversationContext.select(state: state, query: "Ankara hava sıcaklığı ne?",
            consent: .init(confirmedLearning: true), now: now)
        XCTAssertEqual(selected.count, 1)
        XCTAssertTrue(selected[0].text.contains("20 derece"))
        XCTAssertFalse(selected[0].text.contains("10 derece"))
        XCTAssertTrue(selected[0].text.contains("userCorrection"))
    }

    func testExpiredAndFutureKnowledgeAreNotActiveFactsButRemainStored() async throws {
        var state = MemorySnapshot()
        var expired = knowledge(expiresAt: now)
        expired.updatedAt = now.addingTimeInterval(-60)
        var future = knowledge("Ankara hava sıcaklığı 25 derece")
        future.provenance.capturedAt = now.addingTimeInterval(1)
        state.learning.records = [expired, future]
        XCTAssertTrue(LocalConversationContext.select(state: state, query: "Ankara hava nasıl?",
            consent: .init(confirmedLearning: true), now: now).isEmpty)
        XCTAssertFalse(LocalConversationContext.hasFreshEvidence(state: state, query: "Ankara hava nasıl?",
            consent: .init(confirmedLearning: true), now: now))
        let historic = LocalConversationContext.select(state: state, query: "Önceki Ankara hava kaydı neydi?",
            consent: .init(confirmedLearning: true), now: now)
        XCTAssertEqual(historic.count, 1)
        XCTAssertTrue(try XCTUnwrap(historic.first).text.contains("geçerlilik sona ermiş"))
        XCTAssertEqual(state.learning.records.count, 2)
    }

    func testCurrentEvidenceRequiresConfirmationConfidenceSourceAndCorrectLocation() async throws {
        var state = MemorySnapshot(); let record = knowledge()
        state.learning.records = [record]
        let consent = AISharingConsent(confirmedLearning: true)
        XCTAssertTrue(LocalConversationContext.hasFreshEvidence(state: state, query: "Bugün Ankara hava nasıl?", consent: consent, now: now))
        XCTAssertFalse(LocalConversationContext.hasFreshEvidence(state: state, query: "Bugün İstanbul hava nasıl?", consent: consent, now: now))
        XCTAssertFalse(LocalConversationContext.hasFreshEvidence(state: state, query: "Ankara hava?", consent: .init(), now: now))
        for index in 0..<4 {
            var invalid = record
            switch index {
            case 0: invalid.userConfirmed = false
            case 1: invalid.confidence = 0.4
            case 2: invalid.provenance.sourceURL = URL(string: "http://example.com/weather")
            default: invalid.supersededBy = UUID()
            }
            state.learning.records = [invalid]
            XCTAssertFalse(LocalConversationContext.hasFreshEvidence(state: state, query: "Ankara hava?", consent: consent, now: now))
        }
    }

    func testFreshEvidenceMustActuallyBeSelectedAndFitsWithoutTruncation() async throws {
        var state = MemorySnapshot(); state.learning.records = [knowledge()]
        let consent = AISharingConsent(confirmedLearning: true)
        XCTAssertFalse(LocalConversationContext.hasFreshEvidence(state: state, query: "Ankara hava?",
            consent: consent, now: now, selectedContext: []))
        state.learning.records[0].text += String(repeating: " uzun metin", count: 1000)
        XCTAssertFalse(LocalConversationContext.hasFreshEvidence(state: state, query: "Ankara hava?", consent: consent, now: now))
        XCTAssertTrue(LocalConversationContext.select(state: state, query: "Ankara hava?", consent: consent, now: now).isEmpty)
    }

    func testCurrentFinancialEvidenceExpiresForReuseWithoutDeletingHistory() async throws {
        var state = MemorySnapshot()
        state.learning.records = [knowledge("Dolar kuru 30", key: "dolar.kur", capturedAt: now.addingTimeInterval(-900))]
        let consent = AISharingConsent(confirmedLearning: true)
        XCTAssertTrue(LocalConversationContext.hasFreshEvidence(state: state, query: "Dolar kuru şu an ne?", consent: consent, now: now))
        XCTAssertFalse(LocalConversationContext.hasFreshEvidence(state: state, query: "Dolar kuru şu an ne?", consent: consent, now: now.addingTimeInterval(1)))
        XCTAssertFalse(LocalConversationContext.hasFreshEvidence(state: state, query: "Euro kuru şu an ne?", consent: consent, now: now))
        XCTAssertEqual(state.learning.records.count, 1)
    }

    func testVerifiedTaskResultsAndConfirmedCorrectionsAreAvailableNotProposals() async throws {
        var state = MemorySnapshot()
        let completed = TaskExperience(action: "rota.planla", risk: .low, outcome: .succeeded,
            result: "Merdivensiz rota seçildi", executionReceipt: "actual-executor-receipt", createdAt: now)
        let proposed = TaskExperience(action: "rota.planla", risk: .low, outcome: .proposed,
            result: "Merdivenli rota önerisi", createdAt: now)
        state.learning.experiences = [completed, proposed]
        var correction = knowledge("Merdivensiz güzergah tercih et", key: "rota.tercih", source: .taskResult)
        correction.kind = .rule
        correction.provenance.sourceID = completed.id.uuidString
        state.learning.records = [correction]
        let selected = LocalConversationContext.select(state: state, query: "Yeni güzergah öner",
            consent: .init(confirmedLearning: true), now: now)
        XCTAssertTrue(selected.contains { $0.id == "learning:\(correction.id)" })
        XCTAssertTrue(selected.contains { $0.id == "experience:\(completed.id)" })
        XCTAssertFalse(selected.contains { $0.text.contains("Merdivenli") })
    }

    func testCorrectedLearningRemovesStaleDerivedDialogueFromCurrentContext() async throws {
        var state = MemorySnapshot(); var current = knowledge("Espresso tercihim şekersiz", key: "kahve.tercih", source: .userCorrection)
        current.kind = .preference; current.updatedAt = now
        state.learning.records = [current]
        state.generatedAnswers = [.init(question: "Kahvem?",
            response: .init(text: "Şekerli kahve", provider: "local", model: "fixture", generatedAt: now.addingTimeInterval(-60)),
            savedAt: now.addingTimeInterval(-60), cacheUntil: nil, cacheScope: "local", contextIDs: ["learning:\(current.id)"])]
        let selected = LocalConversationContext.select(state: state, query: "Kahve tercihim?",
            consent: .init(confirmedLearning: true, recentHistory: true), now: now)
        XCTAssertTrue(selected.contains { $0.text.contains("şekersiz") })
        XCTAssertFalse(selected.contains { $0.text.contains("Şekerli") })
    }

    func testLocallyConsentedSensitivePreferenceIsNotAHiddenCategoryProhibition() async throws {
        var state = MemorySnapshot(); var record = knowledge("Mahrem tercih", key: "private.preference", source: .userInput)
        record.kind = .preference; record.sensitivity = .sensitive
        state.learning.records = [record]
        XCTAssertFalse(LocalConversationContext.select(state: state, query: "Mahrem tercihim?",
            consent: .init(confirmedLearning: true), now: now).isEmpty)
        XCTAssertTrue(LocalConversationContext.select(state: state, query: "Mahrem tercihim?", consent: .init(), now: now).isEmpty)
    }
}

extension LocalConversationContextTests {
    func testEditedPersonalFactInvalidatesOldFollowupButKeepsNewFactAndArchive() async throws {
        var state = MemorySnapshot()
        let personal = MemoryItem(text: "Kahvem şekersiz", createdAt: now.addingTimeInterval(-90), updatedAt: now)
        state.personal = [personal]
        let first = StoredAIAnswer(question: "Kahvem?", response: .init(text: "Şekerli kahve", provider: "test", model: "fixture", generatedAt: now.addingTimeInterval(-60)), savedAt: now.addingTimeInterval(-60), cacheUntil: nil, cacheScope: "local", contextIDs: ["personal:\(personal.id)"])
        let second = StoredAIAnswer(question: "Devam", response: .init(text: "Eski tercihe devam", provider: "test", model: "fixture", generatedAt: now.addingTimeInterval(-30)), savedAt: now.addingTimeInterval(-30), cacheUntil: nil, cacheScope: "local", contextIDs: ["answer:\(first.id)"])
        state.generatedAnswers = [first, second]
        let selected = LocalConversationContext.select(state: state, query: "Peki kahvem?", consent: .init(personalMemory: true, recentHistory: true), now: now)
        XCTAssertFalse(selected.contains { $0.id.hasPrefix("answer:") })
        XCTAssertTrue(selected.contains { $0.id == "personal:\(personal.id)" && $0.text == personal.text })
        XCTAssertEqual(state.generatedAnswers.count, 2)
    }

    func testCorrectionInvalidatesLegacyMultiHopDerivedConversation() async throws {
        var state = MemorySnapshot()
        var current = knowledge("Kahvem şekersiz", key: "kahve.tercih", source: .userCorrection)
        current.kind = .preference
        current.updatedAt = now
        state.learning.records = [current]
        let first = StoredAIAnswer(question: "Kahvem?", response: .init(text: "Şekerli kahve", provider: "test", model: "fixture", generatedAt: now.addingTimeInterval(-60)), savedAt: now.addingTimeInterval(-60), cacheUntil: nil, cacheScope: "local", contextIDs: ["learning:\(current.id)"])
        let second = StoredAIAnswer(question: "Devam", response: .init(text: "Eski şekerli tercihe göre plan", provider: "test", model: "fixture", generatedAt: now.addingTimeInterval(-30)), savedAt: now.addingTimeInterval(-30), cacheUntil: nil, cacheScope: "local", contextIDs: ["answer:\(first.id)", "derived:learning"])
        state.generatedAnswers = [first, second]
        let selected = LocalConversationContext.select(state: state, query: "Peki devam", consent: .init(confirmedLearning: true, recentHistory: true), now: now)
        XCTAssertFalse(selected.contains { $0.id.hasPrefix("answer:") })
        XCTAssertEqual(state.generatedAnswers.count, 2, "Selection must not erase owner history")
    }

    func testDeletedPersonalOrExperienceCannotReturnThroughFollowupHistory() async throws {
        for origin in ["personal:", "experience:"] {
            var state = MemorySnapshot()
            let missing = UUID()
            let first = StoredAIAnswer(question: "Rota", response: .init(text: "Silinmiş kaynaktan rota", provider: "test", model: "fixture", generatedAt: now), savedAt: now, cacheUntil: nil, cacheScope: "local", contextIDs: [origin + missing.uuidString])
            let second = StoredAIAnswer(question: "Devam", response: .init(text: "Eski rota devamı", provider: "test", model: "fixture", generatedAt: now), savedAt: now, cacheUntil: nil, cacheScope: "local", contextIDs: ["answer:\(first.id)"])
            state.generatedAnswers = [first, second]
            let selected = LocalConversationContext.select(state: state, query: "Peki devam", consent: .init(personalMemory: true, confirmedLearning: true, recentHistory: true), now: now)
            XCTAssertTrue(selected.isEmpty, origin)
        }
    }
}
