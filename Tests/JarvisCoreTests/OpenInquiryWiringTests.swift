import Foundation
import XCTest
@testable import JarvisCore

private final class InquiryDisk: SnapshotStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func load() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func save(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        value = data
    }
}

private struct InquiryDigest: LocalModelDigestChecking {
    func sha256(of fileURL: URL) throws -> String {
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    }
}

private actor CapturedPromptRuntime: OnDeviceInferenceRuntime {
    private var received: [String] = []
    func generate(prompt: String, modelURL: URL) async throws -> String {
        received.append(prompt)
        return "Yerel model deneme yanıtı"
    }
    func prompts() -> [String] { received }
}

final class OpenInquiryWiringTests: XCTestCase, @unchecked Sendable {
    func testOwnerPreferencesChangeLocalPromptNotDevicePermissions() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let input = base.appendingPathComponent("tiny.gguf")
        try Data("abc".utf8).write(to: input)
        let verified = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let manifest = try LocalModelManifest(
            identifier: "tiny-test", revision: "test", licenseIdentifier: "MIT",
            byteCount: 3, sha256: verified)
        let manager = try OnDeviceModelManager(
            directory: base.appendingPathComponent("private", isDirectory: true),
            digester: InquiryDigest())
        _ = try await manager.importModel(from: input, manifest: manifest)

        let store = try MemoryStore(storage: InquiryDisk())
        let runtime = CapturedPromptRuntime()
        let provider = LocalAIProvider(manager: manager, manifest: manifest,
                                       runtime: runtime, memoryStore: store)
        _ = try await provider.respond(to: AIRequest(prompt: "Farklı fikirleri tartışalım."))
        let first = await runtime.prompts()
        XCTAssertTrue(first[0].contains("peşinen dışlama"))
        let learner = UserGuidedLearning(store: store)
        _ = try await learner.teach(topic: "serbest_sorgulama", text: "hayır")
        _ = try await provider.respond(to: AIRequest(prompt: "Kısa cevap ver."))
        let second = await runtime.prompts()
        XCTAssertEqual(second.count, 2)
        XCTAssertFalse(second[1].contains("peşinen dışlama"))
        XCTAssertTrue(second[1].contains("yetkisi değildir"))
    }
}
