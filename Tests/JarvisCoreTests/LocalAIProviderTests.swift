import Foundation
import XCTest
@testable import JarvisCore

private struct FixedDigest: LocalModelDigestChecking {
    let digest: String
    func sha256(of fileURL: URL) throws -> String { digest }
}

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
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"), digester: FixedDigest(digest: digest))
        let runtime = OfflineStubRuntime()
        let provider = LocalAIProvider(manager: manager, manifest: try manifest(), runtime: runtime)
        do { _ = try await provider.respond(to: AIRequest(prompt: "Merhaba")); XCTFail("Model missing") }
        catch { XCTAssertEqual(error as? AIProviderError, .notConfigured) }
        let calls = await runtime.calls(); XCTAssertEqual(calls, 0)
    }
    func testLocalModelImportAndOfflineProviderContract() async throws {
        let (root, source) = try files()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"), digester: FixedDigest(digest: digest))
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
    func testBadSizeOrDigestNeverInstallsModel() async throws {
        let (root, source) = try files()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"), digester: FixedDigest(digest: digest))
        do { _ = try await manager.importModel(from: source, manifest: manifest(100)); XCTFail("Invalid size") }
        catch { XCTAssertEqual(error as? LocalModelError, .mismatchedSize) }
        let wrong = try LocalModelManifest(identifier: "wrong-hash", revision: "r1", licenseIdentifier: "Apache-2.0",
                                           byteCount: 8, sha256: String(repeating: "b", count: 64))
        do { _ = try await manager.importModel(from: source, manifest: wrong); XCTFail("Invalid hash") }
        catch { XCTAssertEqual(error as? LocalModelError, .mismatchedDigest) }
        do { _ = try await manager.installedModelURL(for: wrong); XCTFail("Must not install") }
        catch { XCTAssertEqual(error as? LocalModelError, .notInstalled) }
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
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("private"), digester: FixedDigest(digest: digest))
        let m = try manifest()
        _ = try await manager.importModel(from: source, manifest: m)
        let provider = LocalAIProvider(manager: manager, manifest: m)
        do { _ = try await provider.respond(to: AIRequest(prompt: " ")); XCTFail("Blank prompt") }
        catch { XCTAssertEqual(error as? AIProviderError, .invalidRequest) }
        do { _ = try await provider.respond(to: AIRequest(prompt: "Merhaba")); XCTFail("No inference engine") }
        catch { XCTAssertEqual(error as? AIProviderError, .notConfigured) }
    }
    #if canImport(CryptoKit)
    func testRealSHA256IncrementalDigest() throws {
        let (root, source) = try files()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("abc".utf8).write(to: source)
        XCTAssertEqual(try PlatformSHA256Checker().sha256(of: source),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    #endif
}
