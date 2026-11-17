import Foundation
import XCTest
@testable import JarvisCore

/// These providers/runtimes are explicit protocol fixtures. Real GGUF streaming
/// and latency are separately exercised by the native runtime harness.
private actor StreamFixtureProvider: AIProvider {
    let pieces: [String]
    private var calls = 0
    private var requests: [AIRequest] = []
    init(_ pieces: [String] = ["Merhaba. ", "İkinci cümle."]) { self.pieces = pieces }
    func respond(to request: AIRequest) async throws -> AIResponse {
        try await respond(to: request, onToken: { _ in })
    }
    func respond(to request: AIRequest, onToken: @escaping AITokenHandler) async throws -> AIResponse {
        calls += 1
        requests.append(request)
        for piece in pieces { try await onToken(piece) }
        return AIResponse(text: pieces.joined(), provider: "test-only", model: "stream-fixture", generatedAt: Date())
    }
    func count() -> Int { calls }
    func lastRequest() -> AIRequest? { requests.last }
}

private actor StreamFixtureRuntime: OnDeviceInferenceRuntime {
    let pieces: [String]
    init(_ pieces: [String]) { self.pieces = pieces }
    func generate(prompt: String, modelURL: URL) async throws -> String { pieces.joined() }
    func generate(prompt: String, modelURL: URL, onToken: @escaping AITokenHandler) async throws -> String {
        for piece in pieces { try await onToken(piece) }
        return pieces.joined()
    }
}

private actor DeltaLog {
    var values: [String] = []
    func add(_ text: String) { values.append(text) }
    func all() -> [String] { values }
}

private enum StreamTestError: Error, Equatable { case receiverStopped }

final class StreamingServiceTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testInitialThinkTagsAcrossEverySplitNeverReachVisibleAnswer() async throws {
        let raw = "  <think>Özel akıl yürütme 🌍</think>\n\nMerhaba İğde. İkinci cümle."
        for split in raw.indices {
            var filter = VisibleResponseFilter()
            let output = filter.append(String(raw[..<split])) + filter.append(String(raw[split...])) + filter.finish()
            XCTAssertEqual(output, "Merhaba İğde. İkinci cümle.")
        }
        var byCharacter = VisibleResponseFilter()
        let output = raw.map { byCharacter.append(String($0)) }.joined() + byCharacter.finish()
        XCTAssertEqual(output, "Merhaba İğde. İkinci cümle.")
        XCTAssertEqual(VisibleResponseFilter.answer(from: "<think>"), "")
        XCTAssertEqual(VisibleResponseFilter.answer(from: "<think>bitmemiş düşünce"), "")
        XCTAssertEqual(VisibleResponseFilter.answer(from: "Kod içinde <think> bir etikettir."), "Kod içinde <think> bir etikettir.")
    }

    func testLocalProviderStreamsOnlyVisibleAnswerAndStoresNoReasoning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try OnDeviceModelManager(directory: root)
        try structuralGGUFFixture().write(to: root.appendingPathComponent("fixture.gguf"))
        let manifest = try LocalModelManifest(identifier: "fixture", revision: "test", licenseIdentifier: "fixture", byteCount: 0, sha256: "")
        let runtime = StreamFixtureRuntime(["<th", "ink>gizli", "</thi", "nk>\n", "Mer", "haba. ", "İkinci cümle."])
        let provider = LocalAIProvider(manager: manager, manifest: manifest, runtime: runtime)
        let log = DeltaLog()
        let response = try await provider.respond(to: AIRequest(prompt: "Selam")) { try Task.checkCancellation(); await log.add($0) }
        let deltas = await log.all()
        XCTAssertEqual(deltas.joined(), "Merhaba. İkinci cümle.")
        XCTAssertGreaterThan(deltas.count, 1)
        XCTAssertEqual(response.text, deltas.joined())
        XCTAssertFalse(response.text.contains("gizli"))
    }

    func testDeltasArriveBeforeFinalAnswerIsCommitted() async throws {
        let store = try MemoryStore(storage: TestStorage(), now: now)
        let log = DeltaLog()
        let provider = StreamFixtureProvider()
        let service = AssistantService(store: store, provider: provider, processingMode: .onDevice)
        let reply = try await service.reply(to: "Selam", consent: .init(), now: now) { text in
            let duringStream = try await store.read()
            XCTAssertTrue(duringStream.generatedAnswers.isEmpty)
            await log.add(text)
        }
        let deltas = await log.all()
        XCTAssertEqual(deltas, ["Merhaba. ", "İkinci cümle."])
        XCTAssertEqual(reply.text, deltas.joined())
        let final = try await store.read(now: now)
        XCTAssertEqual(final.generatedAnswers.count, 1)
    }

    func testLocalRuntimeCallbackErrorSurvivesProviderMapping() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try OnDeviceModelManager(directory: root)
        try structuralGGUFFixture().write(to: root.appendingPathComponent("fixture.gguf"))
        let manifest = try LocalModelManifest(identifier: "fixture", revision: "test", licenseIdentifier: "fixture", byteCount: 0, sha256: "")
        let provider = LocalAIProvider(manager: manager, manifest: manifest,
            runtime: StreamFixtureRuntime(["Merhaba", " ikinci parça"]))
        do {
            _ = try await provider.respond(to: AIRequest(prompt: "Selam")) { _ in throw StreamTestError.receiverStopped }
            XCTFail("Callback rejection must stop native streaming")
        } catch { XCTAssertEqual(error as? StreamTestError, .receiverStopped) }
    }

    func testCallbackFailureIsNotMappedToModelFailureOrArchived() async throws {
        let store = try MemoryStore(storage: TestStorage(), now: now)
        let service = AssistantService(store: store, provider: StreamFixtureProvider(), processingMode: .onDevice)
        do {
            _ = try await service.reply(to: "Selam", consent: .init(), now: now) { _ in throw StreamTestError.receiverStopped }
            XCTFail("Receiver failure must stop response generation")
        } catch { XCTAssertEqual(error as? StreamTestError, .receiverStopped) }
        let state = try await store.read(now: now)
        XCTAssertTrue(state.generatedAnswers.isEmpty)
    }

    func testMemoryChangeAfterFirstDeltaStopsStreamAndDoesNotResurrectHistory() async throws {
        let store = try MemoryStore(storage: TestStorage(), now: now)
        let provider = StreamFixtureProvider()
        let log = DeltaLog()
        let service = AssistantService(store: store, provider: provider, processingMode: .onDevice)
        do {
            _ = try await service.reply(to: "Bana bir selam ver", consent: .init(), now: now) { text in
                await log.add(text)
                try await store.deleteAll()
            }
            XCTFail("A stale stream must not continue or commit")
        } catch { XCTAssertEqual(error as? AssistantError, .contextChanged) }
        let deltas = await log.all()
        XCTAssertEqual(deltas, ["Merhaba. "])
        let state = try await store.read(now: now)
        XCTAssertEqual(state, MemorySnapshot())
    }

    func testCancelledStreamingResponseIsNeverArchived() async throws {
        let store = try MemoryStore(storage: TestStorage(), now: now)
        let log = DeltaLog()
        let service = AssistantService(store: store, provider: StreamFixtureProvider(), processingMode: .onDevice)
        let task = Task {
            try await service.reply(to: "Selam", consent: .init(), now: now) { text in
                await log.add(text)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await task.value; XCTFail("Cancelled stream") }
        catch { XCTAssertTrue(error is CancellationError) }
        let deltas = await log.all()
        XCTAssertEqual(deltas.count, 1)
        let state = try await store.read(now: now)
        XCTAssertTrue(state.generatedAnswers.isEmpty)
    }

    func testDirectOwnerActionDoesNotInvokeStreamingModel() async throws {
        let store = try MemoryStore(storage: TestStorage(), now: now)
        try await store.remember("silinecek", now: now)
        let provider = StreamFixtureProvider(["bu veri çalıştırılamaz"])
        let log = DeltaLog()
        let service = AssistantService(store: store, provider: provider, processingMode: .onDevice)
        let reply = try await service.reply(to: "tüm hafızayı sil", consent: .init(), now: now) { await log.add($0) }
        XCTAssertTrue(reply.actionResult?.succeeded == true)
        XCTAssertNil(reply.generated)
        let calls = await provider.count()
        XCTAssertEqual(calls, 0)
        let deltas = await log.all()
        XCTAssertTrue(deltas.isEmpty)
    }

    func testOfflineCurrentFactsWithoutFreshEvidenceDoNotCallModel() async throws {
        for query in ["Bugün İstanbul hava durumu nasıl?", "Dolar kuru kaç TL?", "En son haberler neler?"] {
            let store = try MemoryStore(storage: TestStorage(), now: now)
            let provider = StreamFixtureProvider(["unsupported live claim"])
            let service = AssistantService(store: store, provider: provider, processingMode: .onDevice)
            let reply = try await service.reply(to: query, consent: .init(), now: now)
            XCTAssertEqual(reply.text, OfflineCurrentFactPolicy.unavailableMessage)
            XCTAssertNil(reply.generated)
            let calls = await provider.count()
            XCTAssertEqual(calls, 0)
            let state = try await store.read(now: now)
            XCTAssertTrue(state.generatedAnswers.isEmpty)
            XCTAssertEqual(state.conversations.count, 1, "Store the truthful local interaction, not a fake AI response")
        }
    }

    func testStaticScienceAndPersonalQuestionsAreNotBlockedAsCurrentFacts() async throws {
        XCTAssertFalse(OfflineCurrentFactPolicy.requiresFreshEvidence("Hava nasıl oluşur?"))
        XCTAssertFalse(OfflineCurrentFactPolicy.requiresFreshEvidence("Bugün bana ne öğrettin?"))
        XCTAssertFalse(OfflineCurrentFactPolicy.requiresFreshEvidence("Dolar nedir?"))
        XCTAssertTrue(OfflineCurrentFactPolicy.requiresFreshEvidence("Güncel dolar kuru nedir?"))
        XCTAssertTrue(OfflineCurrentFactPolicy.requiresFreshEvidence("Hava durumu nasıl?"))
    }

    func testDeviceClockAnswersOfflineWithoutInventingModelResponse() async throws {
        let provider = StreamFixtureProvider()
        let store = try MemoryStore(storage: TestStorage(), now: now)
        let service = AssistantService(store: store, provider: provider, processingMode: .onDevice)
        let reply = try await service.reply(to: "Şimdi saat kaç?", consent: .init(), now: now)
        XCTAssertTrue(reply.text.hasPrefix("Cihaz saatine göre "))
        XCTAssertNil(reply.generated)
        let calls = await provider.count()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(OfflineCurrentFactPolicy.clockReply(to: "saat kaç", now: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!), "Cihaz saatine göre 00:00.")
    }

    func testModelValidationCacheRejectsSameSizeReplacementsWithPreservedMTime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try OnDeviceModelManager(directory: root)
        let installed = root.appendingPathComponent("fixture.gguf")
        let bytes = structuralGGUFFixture()
        try bytes.write(to: installed)
        let manifest = try LocalModelManifest(identifier: "fixture", revision: "test", licenseIdentifier: "fixture", byteCount: 0, sha256: "")
        _ = try await manager.installedModelURL(for: manifest)
        let modification = try FileManager.default.attributesOfItem(atPath: installed.path)[.modificationDate]
        let replacement = root.appendingPathComponent("replacement")
        try Data(repeating: 0, count: bytes.count).write(to: replacement)
        if let modification { try FileManager.default.setAttributes([.modificationDate: modification], ofItemAtPath: replacement.path) }
        try FileManager.default.removeItem(at: installed)
        try FileManager.default.moveItem(at: replacement, to: installed)
        do { _ = try await manager.installedModelURL(for: manifest); XCTFail("A cached format check must not approve a replacement inode") }
        catch { XCTAssertEqual(error as? LocalModelError, .invalidFile) }
    }
}

// Verify privacy through more than one generated follow-up, not only a direct
// experience ID: consent revocation must stop transitive history reuse too.
extension StreamingServiceTests {
    func testExperiencePrivacySurvivesMultipleLocalFollowups() async throws {
        let store = try MemoryStore(storage: TestStorage(), now: now)
        let experience = TaskExperience(action: "rota.planla", risk: .low, outcome: .succeeded,
            result: "Merdivensiz rota seçildi", executionReceipt: "test-receipt", createdAt: now)
        try await store.recordExperience(experience, now: now)
        let provider = StreamFixtureProvider(["Merdivensiz rota uygundur."])
        let service = AssistantService(store: store, provider: provider, processingMode: .onDevice)
        let first = try await service.reply(to: "Rota öner", consent: .init(confirmedLearning: true), now: now)
        XCTAssertTrue(try XCTUnwrap(first.generated).contextIDs.contains("experience:\(experience.id)"))
        let second = try await service.reply(to: "Peki devam", consent: .init(confirmedLearning: true, recentHistory: true), now: now.addingTimeInterval(1))
        XCTAssertTrue(try XCTUnwrap(second.generated).contextIDs.contains("derived:learning"))
        _ = try await service.reply(to: "Peki devam", consent: .init(recentHistory: true), now: now.addingTimeInterval(2))
        let last = await provider.lastRequest()
        XCTAssertTrue(try XCTUnwrap(last).context.isEmpty)
    }
}
