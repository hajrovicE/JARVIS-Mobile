import Foundation
import XCTest
@testable import JarvisCore

private actor OfflineStubRuntime: OnDeviceInferenceRuntime {
    private var count = 0
    let result: String
    init(result: String = "Bu tamamen yerel test cevabı.") { self.result = result }
    func generate(prompt: String, modelURL: URL) async throws -> String {
        count += 1
        return result
    }
    func calls() -> Int { count }
}

private actor PromptCapturingRuntime: OnDeviceInferenceRuntime {
    private var prompt = ""
    func generate(prompt: String, modelURL: URL) async throws -> String {
        self.prompt = prompt
        return "tamam"
    }
    func lastPrompt() -> String { prompt }
}

final class LocalAIProviderTests: XCTestCase, @unchecked Sendable {
    private let digest = String(repeating: "a", count: 64)
    private func manifest(_ size: Int64 = 8) throws -> LocalModelManifest {
        try LocalModelManifest(identifier: "test-local-gguf", revision: "r1", licenseIdentifier: "Apache-2.0",
                               byteCount: size, sha256: digest)
    }
    private func files() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("fixture.gguf")
        try Data("GGUFtest".utf8).write(to: source)
        return (root, source)
    }
    func testUninstalledModelFailsClosedWithoutCallingRuntime() async throws {
        let (root, _) = try files()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"))
        let runtime = OfflineStubRuntime()
        let provider = LocalAIProvider(manager: manager, manifest: try manifest(), runtime: runtime)
        do { _ = try await provider.respond(to: AIRequest(prompt: "Merhaba")); XCTFail("Model missing") }
        catch { XCTAssertEqual(error as? AIProviderError, .notConfigured) }
        let calls = await runtime.calls(); XCTAssertEqual(calls, 0)
    }
    func testLocalModelImportAndOfflineProviderContract() async throws {
        let (root, source) = try files()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"))
        let m = try manifest()
        _ = try await manager.importModel(from: source, manifest: m)
        let runtime = OfflineStubRuntime()
        let provider = LocalAIProvider(manager: manager, manifest: m, runtime: runtime)
        let answer = try await provider.respond(to: AIRequest(prompt: "Öğrenmeye devam", context: [.init(id: "pref", text: "Türkçe yanıtla")]))
        XCTAssertEqual(answer.provider, "local-device")
        XCTAssertEqual(answer.model, "test-local-gguf")
        XCTAssertEqual(answer.freshness, .unverified)
        XCTAssertEqual(answer.text, "Bu tamamen yerel test cevabı.")
        XCTAssertTrue(answer.sources.isEmpty)
        XCTAssertNil(answer.expiresAt)
        let calls = await runtime.calls(); XCTAssertEqual(calls, 1)
        try await manager.removeModel(m)
        do { _ = try await provider.respond(to: AIRequest(prompt: "Merhaba")); XCTFail("Deleted model") }
        catch { XCTAssertEqual(error as? AIProviderError, .notConfigured) }
    }
    func testOwnerModelDoesNotRequirePinnedHashOrSize() async throws {
        let (root, source) = try files()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"))
        let metadata = try LocalModelManifest(
            identifier: "owner-model", revision: "my-version", licenseIdentifier: "owner",
            byteCount: 0, sha256: "")
        let installed = try await manager.importModel(from: source, manifest: metadata)
        let found = try await manager.installedModelURL(for: metadata)
        XCTAssertEqual(found, installed)
    }
    func testOwnerModelIsAcceptedByContentNotFileExtension() async throws {
        let (root, source) = try files()
        defer { try? FileManager.default.removeItem(at: root) }
        let renamed = root.appendingPathComponent("my-private-model.weights")
        try FileManager.default.moveItem(at: source, to: renamed)
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"))
        let result = try await manager.importModel(from: renamed, manifest: manifest())
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
    }
    func testRejectsNonGGUFContentEvenWhenNamedGGUF() async throws {
        let (root, source) = try files()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("NOT_A_MODEL".utf8).write(to: source)
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"))
        do { _ = try await manager.importModel(from: source, manifest: manifest(11)); XCTFail("Not GGUF") }
        catch { XCTAssertEqual(error as? LocalModelError, .invalidFile) }
    }
    func testReasoningBlockIsHiddenWithoutLosingTheAnswer() {
        XCTAssertEqual(ModelOutput.withoutReasoning("<think>\nplan\n</think>\n\nMerhaba!"), "Merhaba!")
        XCTAssertEqual(ModelOutput.withoutReasoning("Düz cevap"), "Düz cevap")
        XCTAssertEqual(ModelOutput.withoutReasoning("Önce <think>a</think>sonra"), "Önce sonra")
        // Never turn a reasoning-only output into an empty answer.
        XCTAssertEqual(ModelOutput.withoutReasoning("<think>yarım kalan"), "<think>yarım kalan")
        XCTAssertEqual(ModelOutput.withoutReasoning("Cevap <think>yarım"), "Cevap")
    }
    func testPromptWindowDropsOldestBodyTokensOnly() {
        XCTAssertEqual(PromptWindow.fit(prefix: [1], body: [2, 3, 4, 5], suffix: [9], limit: 4), [1, 4, 5, 9])
        XCTAssertEqual(PromptWindow.fit(prefix: [1], body: [2, 3], suffix: [9], limit: 10), [1, 2, 3, 9])
        XCTAssertNil(PromptWindow.fit(prefix: [1], body: [2], suffix: [9], limit: 2))
    }
    func testMemoriesAreRenderedAfterHistorySoTrimmingKeepsThem() async throws {
        let (root, source) = try files()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"))
        let m = try manifest()
        _ = try await manager.importModel(from: source, manifest: m)
        let runtime = PromptCapturingRuntime()
        let provider = LocalAIProvider(manager: manager, manifest: m, runtime: runtime)
        _ = try await provider.respond(to: AIRequest(prompt: "soru", context: [
            .init(id: "personal:1", text: "kahve severim"),
            .init(id: "conversation:2", text: "eski sohbet")]))
        let prompt = await runtime.lastPrompt()
        let history = try XCTUnwrap(prompt.range(of: "eski sohbet"))
        let memory = try XCTUnwrap(prompt.range(of: "kahve severim"))
        let question = try XCTUnwrap(prompt.range(of: "soru", options: .backwards))
        XCTAssertTrue(history.lowerBound < memory.lowerBound)
        XCTAssertTrue(memory.lowerBound < question.lowerBound)
    }
    func testManifestValidationAndCodableTraversalRejected() throws {
        XCTAssertThrowsError(try LocalModelManifest(identifier: "../outside", revision: "r1", licenseIdentifier: "Apache-2.0", byteCount: 8, sha256: digest))
        XCTAssertThrowsError(try LocalModelManifest(identifier: "valid", revision: "r1", licenseIdentifier: "Apache-2.0", byteCount: -1, sha256: digest))
        let valid = try manifest()
        let json = try JSONEncoder().encode(valid)
        XCTAssertEqual(try JSONDecoder().decode(LocalModelManifest.self, from: json), valid)
        let bad = Data(String(decoding: json, as: UTF8.self).replacingOccurrences(of: "test-local-gguf", with: "../../other").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalModelManifest.self, from: bad))
    }
    func testEmptyPromptAndUnavailableRuntimeCannotFabricateAnswer() async throws {
        let (root, source) = try files()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"))
        let m = try manifest()
        _ = try await manager.importModel(from: source, manifest: m)
        let provider = LocalAIProvider(manager: manager, manifest: m)
        do { _ = try await provider.respond(to: AIRequest(prompt: " ")); XCTFail("Blank prompt") }
        catch { XCTAssertEqual(error as? AIProviderError, .invalidRequest) }
        do { _ = try await provider.respond(to: AIRequest(prompt: "Merhaba")); XCTFail("No inference engine") }
        catch { XCTAssertEqual(error as? AIProviderError, .notConfigured) }
    }
}
