import XCTest
@testable import JarvisCore

final class LocalTurnBudgetTests: XCTestCase, @unchecked Sendable {
    func testFastSmallTalkUsesShortPromptAndOutputBudget() async throws {
        let result = LocalTurnBudget.select(
            prompt: "Merhaba, nasılsın?", fastConversation: true,
            ownerMaxNewTokens: 2_048, ownerContextTokens: 8_192)
        XCTAssertEqual(result.maxNewTokens, 256)
        XCTAssertEqual(result.contextTokens, 3_072)
        XCTAssertFalse(result.needsDetail)
    }

    func testTechnicalQuestionGetsRoomToExplain() async throws {
        let result = LocalTurnBudget.select(
            prompt: "Bu Swift kodunu detaylı analiz et", fastConversation: true,
            ownerMaxNewTokens: 2_048, ownerContextTokens: 8_192)
        XCTAssertEqual(result.maxNewTokens, 768)
        XCTAssertEqual(result.contextTokens, 4_096)
        XCTAssertTrue(result.needsDetail)
    }

    func testNeverExceedsExplicitOwnerConfiguration() async throws {
        let result = LocalTurnBudget.select(
            prompt: "Adım adım incele", fastConversation: true,
            ownerMaxNewTokens: 80, ownerContextTokens: 1_024)
        XCTAssertEqual(result.maxNewTokens, 80)
        XCTAssertEqual(result.contextTokens, 1_024)
    }

    func testDetailedModePreservesOwnersGenerationParameters() async throws {
        let result = LocalTurnBudget.select(
            prompt: "Merhaba", fastConversation: false,
            ownerMaxNewTokens: 2_048, ownerContextTokens: 8_192)
        XCTAssertEqual(result.maxNewTokens, 2_048)
        XCTAssertEqual(result.contextTokens, 8_192)
    }

    func testInvalidOwnerSettingsStayInvalidForExplicitRuntimeError() async throws {
        let result = LocalTurnBudget.select(
            prompt: "Merhaba", fastConversation: true,
            ownerMaxNewTokens: -7, ownerContextTokens: -8)
        XCTAssertEqual(result.maxNewTokens, -7)
        XCTAssertEqual(result.contextTokens, -8)
    }
    func testOwnerCanSelectAContextBelow512WithoutItBeingRaised() async throws {
        let result = LocalTurnBudget.select(prompt: "Merhaba", fastConversation: true,
            ownerMaxNewTokens: 1, ownerContextTokens: 128)
        XCTAssertEqual(result.maxNewTokens, 1)
        XCTAssertEqual(result.contextTokens, 128)
    }

    func testExplicitThinkingAndCodeHaveDetailedBudget() async throws {
        for prompt in ["/think Bu soruyu çöz", "Python ile bir fonksiyon yaz", "```swift\nstruct Test {}\n```", "Algoritmanın doğruluğunu kanıtla"] {
            let result = LocalTurnBudget.select(prompt: prompt, fastConversation: true,
                ownerMaxNewTokens: 4096, ownerContextTokens: 8192)
            XCTAssertTrue(result.needsDetail, prompt)
            XCTAssertEqual(result.maxNewTokens, 768)
        }
    }

    func testMinimumIntegersDoNotOverflowOrTurnIntoValidSettings() async throws {
        let result = LocalTurnBudget.select(prompt: "/think", fastConversation: true,
            ownerMaxNewTokens: .min, ownerContextTokens: .min)
        XCTAssertEqual(result.maxNewTokens, .min)
        XCTAssertEqual(result.contextTokens, .min)
    }
}
