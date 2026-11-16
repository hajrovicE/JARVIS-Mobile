import XCTest
@testable import JarvisCore

final class LocalTurnBudgetTests: XCTestCase {
    func testFastSmallTalkUsesShortPromptAndOutputBudget() {
        let result = LocalTurnBudget.select(
            prompt: "Merhaba, nasılsın?", fastConversation: true,
            ownerMaxNewTokens: 2_048, ownerContextTokens: 8_192)
        XCTAssertEqual(result.maxNewTokens, 256)
        XCTAssertEqual(result.contextTokens, 3_072)
        XCTAssertFalse(result.needsDetail)
    }

    func testTechnicalQuestionGetsRoomToExplain() {
        let result = LocalTurnBudget.select(
            prompt: "Bu Swift kodunu detaylı analiz et", fastConversation: true,
            ownerMaxNewTokens: 2_048, ownerContextTokens: 8_192)
        XCTAssertEqual(result.maxNewTokens, 768)
        XCTAssertEqual(result.contextTokens, 4_096)
        XCTAssertTrue(result.needsDetail)
    }

    func testNeverExceedsExplicitOwnerConfiguration() {
        let result = LocalTurnBudget.select(
            prompt: "Adım adım incele", fastConversation: true,
            ownerMaxNewTokens: 80, ownerContextTokens: 1_024)
        XCTAssertEqual(result.maxNewTokens, 80)
        XCTAssertEqual(result.contextTokens, 1_024)
    }

    func testDetailedModePreservesOwnersGenerationParameters() {
        let result = LocalTurnBudget.select(
            prompt: "Merhaba", fastConversation: false,
            ownerMaxNewTokens: 2_048, ownerContextTokens: 8_192)
        XCTAssertEqual(result.maxNewTokens, 2_048)
        XCTAssertEqual(result.contextTokens, 8_192)
    }

    func testDefaultClampsInvalidOwnerInputWithoutOverflow() {
        let result = LocalTurnBudget.select(
            prompt: "Merhaba", fastConversation: true,
            ownerMaxNewTokens: -7, ownerContextTokens: -8)
        XCTAssertEqual(result.maxNewTokens, 1)
        XCTAssertEqual(result.contextTokens, 512)
    }
}
