import Foundation
import XCTest
@testable import JarvisCore

final class LocalConversationContextTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testRelevantMemoryWinsOverUnrelatedNotes() {
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

    func testShortAndRelevantContextUnderStrictBudget() {
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
        XCTAssertTrue(chosen.allSatisfy { $0.text.count <= 680 && !$0.text.isEmpty })
    }

    func testConsentIsolationAndSensitiveLearnedMemories() {
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

    func testRecentFollowupRepliesRemainWhenHistoryOptedIn() {
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
            consent: AISharingConsent(recentHistory: true, personalMemory: false), now: now)
        XCTAssertTrue(hidden.isEmpty)
    }

    func testDuplicatedSameTextIsNotRepeated() {
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
