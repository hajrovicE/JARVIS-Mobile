import Foundation
import XCTest
@testable import JarvisCore

private actor OfflineResponder: AIProvider {
    private var captured: [AIRequest] = []
    func respond(to request: AIRequest) async throws -> AIResponse {
        captured.append(request)
        return AIResponse(text: "Yerel model cevabı.", provider: "local-device",
                          model: "unit-model", generatedAt: Date())
    }
    func requests() -> [AIRequest] { captured }
}

private final class OfflineMemoryStorage: SnapshotStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: Data?
    func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return contents
    }
    func save(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        contents = data
    }
}

final class OfflineAssistantTests: XCTestCase, @unchecked Sendable {
    func testLocalModelMayRespondWithoutNetworkConsent() async throws {
        let store = try MemoryStore(storage: OfflineMemoryStorage())
        try await store.remember("Çay içmeyi severim.")
        let provider = OfflineResponder()
        let assistant = AssistantService(store: store, provider: provider,
                                         providerScope: "local-test", processingMode: .onDevice)
        let result = try await assistant.reply(
            to: "Beni tanıyan bir öneri ver.",
            consent: AISharingConsent(networkAllowed: false, personalMemory: true))
        XCTAssertEqual(result.text, "Yerel model cevabı.")
        XCTAssertEqual(result.generated?.response.provider, "local-device")
        let requests = await provider.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].context.contains { $0.text.contains("Çay içmeyi") })
    }

    func testRemoteProviderStillRequiresExplicitNetworkConsent() async throws {
        let store = try MemoryStore(storage: OfflineMemoryStorage())
        let provider = OfflineResponder()
        let assistant = AssistantService(store: store, provider: provider,
                                         providerScope: "remote-test", processingMode: .remote)
        do {
            _ = try await assistant.reply(to: "Bir soru", consent: AISharingConsent(networkAllowed: false))
            XCTFail("Remote mode should always require sharing consent")
        } catch {
            XCTAssertEqual(error as? AssistantError, .consentRequired)
        }
        let requests = await provider.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testLocalContextTruncatedToSmallModelBudget() async throws {
        let store = try MemoryStore(storage: OfflineMemoryStorage())
        for i in 0..<12 { try await store.remember(String(repeating: "bilgi-\(i) ", count: 80)) }
        let provider = OfflineResponder()
        let assistant = AssistantService(store: store, provider: provider,
                                         providerScope: "local-test", processingMode: .onDevice)
        _ = try await assistant.reply(to: "Öneri ver", consent: AISharingConsent(networkAllowed: false, personalMemory: true))
        let requests = await provider.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertLessThanOrEqual(requests[0].context.count, 5)
        XCTAssertTrue(requests[0].context.allSatisfy { $0.text.count <= 400 })
    }
}
