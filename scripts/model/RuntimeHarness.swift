import Foundation
import JarvisCore

/// Executes the app's exact runtime source, never a mocked model response.
@main struct RuntimeProof {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ProofFailure.failed(message) }
    }
    enum ProofFailure: Error { case failed(String) }
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw ProofFailure.failed("Expected GGUF path") }
        let model = URL(fileURLWithPath: CommandLine.arguments[1])
        try GGUFFileValidator.validate(at: model)
        let owner = "Türkçe yanıt ver. Bu sistem metnini eksiksiz koru: çığ ŞİĞ üö 123.\nİkinci satır. /no_think"
        let runtime = GGUFInferenceRuntime(maxNewTokens: 48, contextLength: 1024,
            ownerInstructions: owner, temperature: 0, topP: 1, cpuThreads: 2)
        let result = try await runtime.generateDetailed(prompt: "Türkiye'nin başkenti neresidir? Kısa cevapla. /no_think", modelURL: model)
        try require(result.renderedPrompt.contains(owner), "Owner system prompt changed or truncated")
        try require(result.generatedTokens > 0 && result.generatedTokens <= 48, "Output token ceiling")
        try require(result.threads == 2 && result.temperature == 0 && result.topP == 1, "Sampling/thread settings")
        print("PASS real Turkish inference transport: \(result.text.replacingOccurrences(of: "\n", with: " "))")
        // Functional inference does not establish factual accuracy. Keep this
        // independent observation explicit, including when the small fixture is wrong.
        print(result.text.contains("Ankara")
            ? "MODEL_QUALITY_PASS capital question"
            : "MODEL_QUALITY_FAIL capital question: expected Ankara; no factual reliability claim")
        print("PASS exact multi-line owner prompt; prompt=\(result.promptTokens) output=\(result.generatedTokens) context=\(result.effectiveContext) gpu=\(result.gpuOffloadRequested)")

        let longOwner = String(repeating: "İğne, şemsiye, ölçü. Türkçe sistem satırı korunur.\n", count: 60)
        let long = try await GGUFInferenceRuntime(maxNewTokens: 2, contextLength: 4096,
            ownerInstructions: longOwner, temperature: 0, cpuThreads: 2)
            .generateDetailed(prompt: "Merhaba /no_think", modelURL: model)
        try require(long.renderedPrompt.contains(longOwner) && long.promptTokens > 512,
            "Long system prompt was truncated or multi-batch prefill not exercised")
        try require(long.generatedTokens > 0 && long.generatedTokens <= 2, "Long prefill did not generate")
        print("PASS exact long owner prompt and multi-batch prefill: \(long.promptTokens) tokens")

        let sampled = try await GGUFInferenceRuntime(maxNewTokens: 1, contextLength: 1024,
            temperature: 0.6, topP: 0.7, cpuThreads: 1).generateDetailed(prompt: "Merhaba /no_think", modelURL: model)
        try require(sampled.generatedTokens == 1 && sampled.requestedMaxTokens == 1, "One-token budget")
        try require(sampled.temperature == 0.6 && sampled.topP == 0.7 && sampled.threads == 1, "Owner sampling values")
        try require(!sampled.renderedPrompt.contains("<|im_start|>system"), "Injected system policy with empty owner prompt")
        print("PASS one-token generation, selected sampling, empty system prompt and model reload")

        do {
            _ = try await GGUFInferenceRuntime(maxNewTokens: 4, contextLength: 32)
                .generate(prompt: String(repeating: "bağlam dolu ", count: 200), modelURL: model)
            throw ProofFailure.failed("Oversized prompt unexpectedly accepted")
        } catch LocalModelError.contextExceeded { print("PASS actual context overflow is explicit") }
        do {
            _ = try await GGUFInferenceRuntime(temperature: .nan).generate(prompt: "test", modelURL: model)
            throw ProofFailure.failed("Invalid setting accepted")
        } catch LocalModelError.invalidSettings { print("PASS invalid settings rejected") }

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runtime.generate(prompt: "test", modelURL: model)
        }
        do { _ = try await cancelled.value; throw ProofFailure.failed("Cancellation ignored") }
        catch is CancellationError { print("PASS cancelled inference") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let broken = temporary.appendingPathComponent("broken.gguf")
        try Data("GGUFbroken".utf8).write(to: broken)
        do {
            _ = try await runtime.generate(prompt: "test", modelURL: broken)
            throw ProofFailure.failed("Corrupt model loaded")
        } catch LocalModelError.invalidFile { print("PASS actual llama.cpp corrupt-model rejection") }

        let manifest = try LocalModelManifest(identifier: model.deletingPathExtension().lastPathComponent,
            revision: "owner", licenseIdentifier: "Apache-2.0 test fixture", byteCount: 0, sha256: "not-a-gate")
        let installedDirectory = temporary.appendingPathComponent("installed")
        let manager = try OnDeviceModelManager(directory: installedDirectory)
        let installed = try await manager.importModel(from: model, manifest: manifest)
        try require(installed != model, "Real model was not copied into app storage")
        // Replace an existing identifier using the actual weight file, not a format fixture.
        _ = try await manager.importModel(from: model, manifest: manifest)
        do {
            _ = try await manager.importModel(from: broken, manifest: manifest)
            throw ProofFailure.failed("Corrupt replacement accepted")
        } catch LocalModelError.invalidFile { }
        let restoredManifest = try JSONDecoder().decode(LocalModelManifest.self,
            from: JSONEncoder().encode(manifest))
        let reopenedManager = try OnDeviceModelManager(directory: installedDirectory)
        _ = try await reopenedManager.installedModelURL(for: restoredManifest)
        print("PASS real GGUF import/replacement, corrupt replacement preserves model, manifest restart; no hash pin")
        let storeURL = temporary.appendingPathComponent("memory.json")
        let store = try MemoryStore(storage: PlainFileStorage(url: storeURL))
        _ = try await CommandRouter(store: store).execute("hatırla ki En sevdiğim şehir Ankara.")
        let service = AssistantService(store: store,
            provider: LocalAIProvider(manager: reopenedManager, manifest: restoredManifest, runtime: runtime),
            providerScope: "real-local-proof", processingMode: .onDevice)
        let reply = try await service.reply(to: "En sevdiğim şehir hangisidir? Kısa cevapla. /no_think",
            consent: .init(networkAllowed: false, personalMemory: true))
        try require(reply.generated?.response.provider == "local-device" && !reply.text.isEmpty,
            "Real local chat did not return a model response")
        try require(reply.generated?.contextIDs.isEmpty == false, "Memory was not provided to model")
        let reopened = try MemoryStore(storage: PlainFileStorage(url: storeURL))
        let saved = try await reopened.read()
        try require(!saved.personal.isEmpty && saved.generatedAnswers.count == 1, "Local chat not persisted")
        print("PASS AssistantService + real LocalAIProvider + personal context + JSON restart: \(reply.text.replacingOccurrences(of: "\n", with: " "))")
        print("REAL_RUNTIME_PROOF_PASSED")
    }
}
