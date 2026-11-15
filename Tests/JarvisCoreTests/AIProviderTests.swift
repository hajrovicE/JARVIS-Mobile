import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import JarvisCore

private actor StubAITransport: AIHTTPTransport {
    let payload: Data
    let status: Int
    let finalURL: URL
    let failure: URLError?
    private var captured: [URLRequest] = []
    init(payload: Data = Data(), status: Int = 200,
         finalURL: URL = URL(string: "https://relay.example/v1/chat")!, failure: URLError? = nil) {
        self.payload = payload; self.status = status; self.finalURL = finalURL; self.failure = failure
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        if let failure { throw failure }
        return (payload, HTTPURLResponse(url: finalURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func requests() -> [URLRequest] { captured }
}

final class AIProviderTests: XCTestCase, @unchecked Sendable {
    private let endpoint = URL(string: "https://relay.example/v1/chat")!
    private let relayToken = "test-relay-credential-1234567890"
    private let goodResponse = Data(#"{"text":"İki aşamada yardımcı olayım.","provider":"openai","model":"test-model","generatedAt":"2026-01-01T12:00:00Z","sources":[],"freshness":"unverified","expiresAt":null}"#.utf8)

    func testDefaultProviderClearlyReportsNotConfigured() async throws {
        do {
            _ = try await UnavailableAIProvider().respond(to: .init(prompt: "Merhaba"))
            XCTFail("No model is configured")
        } catch { XCTAssertEqual(error as? AIProviderError, .notConfigured) }
    }
    func testHTTPSConfigurationAndHeaderInjectionRejected() async throws {
        for url in ["http://relay.example/v1/chat", "https://name:password@relay.example/v1/chat", "https://relay.example/v1/chat?token=secret", "https://relay.example/v1/chat#token"] {
            XCTAssertThrowsError(try HTTPRelayAIProvider(endpoint: URL(string: url)!, accessToken: relayToken)) {
                XCTAssertEqual($0 as? AIProviderError, .invalidConfiguration)
            }
        }
        XCTAssertThrowsError(try HTTPRelayAIProvider(endpoint: endpoint, accessToken: ""))
        XCTAssertThrowsError(try HTTPRelayAIProvider(endpoint: endpoint, accessToken: relayToken + "\r\nInjected: yes"))
    }
    func testTurkishRequestAndSelectedContextUseRelayCredential() async throws {
        let transport = StubAITransport(payload: goodResponse)
        let provider = try HTTPRelayAIProvider(endpoint: endpoint, accessToken: relayToken, transport: transport)
        let question = AIRequest(prompt: "Önce tercihlerimi değerlendir, sonra iki günlük plan çıkar.", context: [.init(id: "preference-1", text: "Çay tercih ederim.")])
        let answer = try await provider.respond(to: question)
        XCTAssertEqual(answer.text, "İki aşamada yardımcı olayım.")
        XCTAssertEqual(answer.freshness, .unverified)
        XCTAssertTrue(answer.sources.isEmpty)
        let captured = await transport.requests()
        XCTAssertEqual(captured.count, 1)
        let sent = try XCTUnwrap(captured.first)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.url, endpoint)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(relayToken)")
        let body = try XCTUnwrap(sent.httpBody)
        XCTAssertEqual(try JSONDecoder().decode(AIRequest.self, from: body), question)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains(relayToken))
    }
    func testFailuresNeverReturnFabricatedAnswers() async throws {
        let expected: [(Int, AIProviderError)] = [(401, .unauthorized), (403, .unauthorized), (429, .rateLimited), (503, .unavailable), (302, .invalidResponse)]
        for (status, expectedError) in expected {
            let transport = StubAITransport(payload: goodResponse, status: status)
            let provider = try HTTPRelayAIProvider(endpoint: endpoint, accessToken: relayToken, transport: transport)
            do { _ = try await provider.respond(to: .init(prompt: "Merhaba")); XCTFail("HTTP error must fail") }
            catch { XCTAssertEqual(error as? AIProviderError, expectedError) }
        }
        let offline = try HTTPRelayAIProvider(endpoint: endpoint, accessToken: relayToken,
            transport: StubAITransport(failure: URLError(.notConnectedToInternet)))
        do { _ = try await offline.respond(to: .init(prompt: "Merhaba")); XCTFail("Offline must fail") }
        catch { XCTAssertEqual(error as? AIProviderError, .networkUnavailable) }
    }
    func testMalformedEmptyAndCrossEndpointResponsesRejected() async throws {
        let invalid = [Data("not-json".utf8), Data(#"{"text":""}"#.utf8),
            Data(String(decoding: goodResponse, as: UTF8.self).replacingOccurrences(of: "İki aşamada yardımcı olayım.", with: " ").utf8)]
        for payload in invalid {
            let provider = try HTTPRelayAIProvider(endpoint: endpoint, accessToken: relayToken,
                transport: StubAITransport(payload: payload))
            do { _ = try await provider.respond(to: .init(prompt: "Merhaba")); XCTFail("Invalid response must fail") }
            catch { XCTAssertTrue([AIProviderError.invalidResponse, .emptyResponse].contains(error as? AIProviderError ?? .unavailable)) }
        }
        let redirected = try HTTPRelayAIProvider(endpoint: endpoint, accessToken: relayToken,
            transport: StubAITransport(payload: goodResponse, finalURL: URL(string: "https://other.example/v1/chat")!))
        do { _ = try await redirected.respond(to: .init(prompt: "Merhaba")); XCTFail("Cross-endpoint response must fail") }
        catch { XCTAssertEqual(error as? AIProviderError, .invalidResponse) }
    }
    func testUnboundedRequestsAndUnsupportedFreshnessCannotPass() async throws {
        let transport = StubAITransport(payload: goodResponse)
        let provider = try HTTPRelayAIProvider(endpoint: endpoint, accessToken: relayToken, transport: transport)
        for request in [AIRequest(prompt: "  "), AIRequest(prompt: String(repeating: "a", count: 8001)), AIRequest(prompt: "Soru", context: Array(repeating: .init(id: "id", text: "text"), count: 21))] {
            do { _ = try await provider.respond(to: request); XCTFail("Request must be bounded") }
            catch { XCTAssertEqual(error as? AIProviderError, .invalidRequest) }
        }
        let captured = await transport.requests(); XCTAssertTrue(captured.isEmpty)
        let fabricatedFreshness = String(decoding: goodResponse, as: UTF8.self).replacingOccurrences(of: "unverified", with: "verifiedStatic")
        let evidenceFree = try HTTPRelayAIProvider(endpoint: endpoint, accessToken: relayToken,
            transport: StubAITransport(payload: Data(fabricatedFreshness.utf8)))
        do { _ = try await evidenceFree.respond(to: .init(prompt: "Bugün?")); XCTFail("No evidence exists") }
        catch { XCTAssertEqual(error as? AIProviderError, .invalidResponse) }
    }
}
