import Foundation
import XCTest
@testable import JarvisCore

final class ImprovementReviewTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testAllRecordedFailuresCreateReviewSuggestions() {
        var state = LearningState()
        state.experiences = [
            .init(action: "memory.remember", risk: .low, outcome: .failed,
                  createdAt: now.addingTimeInterval(-120)),
            .init(action: "memory.remember", risk: .low, outcome: .failed,
                  createdAt: now.addingTimeInterval(-60)),
            .init(action: "memory.export", risk: .sensitive, outcome: .failed, createdAt: now)
        ]
        let suggestions = ImprovementReview.opportunities(from: state, now: now)
        XCTAssertEqual(suggestions.count, 2)
        XCTAssertEqual(suggestions.first?.id, "reliability.memory.remember")
        XCTAssertEqual(suggestions.first?.failureCount, 2)
        XCTAssertEqual(suggestions.first?.risk, .low)
    }

    func testOldOrUnrecognizedActionsCanBeAnalyzedButNotExecuted() {
        var state = LearningState()
        state.experiences = [
            .init(action: "outside.phone.backdoor", risk: .high,
                  outcome: .failed, createdAt: now),
            .init(action: "outside.phone.backdoor", risk: .high,
                  outcome: .failed, createdAt: now),
            .init(action: "memory.delete", risk: .sensitive,
                  outcome: .failed, createdAt: now.addingTimeInterval(-91 * 86400)),
            .init(action: "memory.delete", risk: .sensitive,
                  outcome: .failed, createdAt: now.addingTimeInterval(-91 * 86400))
        ]
        XCTAssertEqual(ImprovementReview.opportunities(from: state, now: now).count, 2)
    }

    func testSensitiveFailuresRecommendReviewWithoutRunningTask() {
        var state = LearningState()
        state.experiences = [
            .init(action: "memory.deleteAll", risk: .high, outcome: .failed, createdAt: now),
            .init(action: "memory.deleteAll", risk: .high, outcome: .failed, createdAt: now)
        ]
        let opportunity = ImprovementReview.opportunities(from: state, now: now).first
        XCTAssertEqual(opportunity?.risk, .high)
        XCTAssertTrue(opportunity?.reason.contains("kullanıcı komutu olmadan") == true)
    }
}
