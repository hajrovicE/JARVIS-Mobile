import Foundation
import JarvisCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Executes the app's exact runtime source, never a mocked model response.
@main struct RuntimeProof {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ProofFailure.failed(message) }
    }
    enum ProofFailure: Error { case failed(String) }
    static func main() async {
        do {
            if CommandLine.arguments.count >= 3, CommandLine.arguments[2] == "--speech-only" {
                try await proveEarlySpeechSentence(runtime: GGUFInferenceRuntime(),
                    model: URL(fileURLWithPath: CommandLine.arguments[1]),
                    prompt: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "Söylediğim iki cümleyi aynen tekrarla: Merhaba. Görüşmek üzere.")
            } else { try await verify() }
        }
        catch {
            let error = "VALIDATION_FAILED: \(error)\n"
            FileHandle.standardError.write(Data(error.utf8))
            exit(1)
        }
    }
    static func proveStreamingAndResidency(runtime: GGUFInferenceRuntime, model: URL,
        cold: GGUFGeneration, prompt: String, owner: String) async throws {
        try require(!cold.metrics.warmModel && cold.metrics.modelLoadCount == 1, "Cold model metrics")
        printMetrics("cold", cold.metrics)
        let probe = StreamProbe()
        let warm = try await runtime.generateDetailed(prompt: prompt, modelURL: model, onToken: { delta in
            try await probe.append(delta)
        })
        let delivered = await probe.snapshot()
        try require(warm.metrics.warmModel && warm.metrics.modelLoadCount == 1,
            "Weights were reloaded between turns")
        try require(warm.renderedPrompt == cold.renderedPrompt && warm.promptTokens == cold.promptTokens,
            "A previous turn contaminated the new context")
        try require(delivered.count > 1 && delivered.firstSeconds != nil,
            "Actual native token callbacks were not received")
        try require(delivered.text.trimmingCharacters(in: .whitespacesAndNewlines) == warm.text,
            "Streamed UTF-8 text differs from final response")
        try require((delivered.firstSeconds ?? .infinity) < delivered.finishedSeconds,
            "The first callback was not observed before generation completed")
        printMetrics("warm", warm.metrics)
        print("PASS real streaming before completion: callbacks=\(delivered.count) first_callback_s=\(delivered.firstSeconds ?? -1) callback_span_s=\(delivered.lastSeconds - (delivered.firstSeconds ?? 0))")

        let cancellationProbe = StreamProbe()
        let cancelled = Task {
            try await runtime.generateDetailed(prompt: prompt, modelURL: model, onToken: { delta in
                try await cancellationProbe.append(delta)
                withUnsafeCurrentTask { $0?.cancel() }
            })
        }
        do { _ = try await cancelled.value; throw ProofFailure.failed("Mid-stream cancellation ignored") }
        catch is CancellationError { }
        let cancelledOutput = await cancellationProbe.snapshot()
        try require(cancelledOutput.count == 1, "Cancellation emitted duplicate or late tokens")
        print("PASS Task cancellation after first real native delta")

        // Actor callbacks suspend generation. Settings must remain those captured
        // for the active turn, and a second generation must be explicitly rejected.
        let gate = StreamGate()
        let active = Task {
            try await runtime.generateDetailed(prompt: prompt, modelURL: model, onToken: { _ in
                await gate.pauseFirst()
            })
        }
        await gate.waitForFirst()
        do {
            _ = try await runtime.generate(prompt: "another request", modelURL: model)
            throw ProofFailure.failed("Concurrent generation was accepted")
        } catch LocalModelError.generationInProgress { }
        await runtime.configure(maxNewTokens: 3, contextLength: 512, ownerInstructions: "",
            temperature: 0, topP: 1, cpuThreads: 1)
        await gate.release()
        let captured = try await active.value
        try require(captured.requestedMaxTokens == 48 && captured.renderedPrompt.contains(owner),
            "Settings mutated an in-flight generation")
        print("PASS concurrent-generation rejection and per-turn configuration snapshot")

        let unloadGate = StreamGate()
        let unloaded = Task {
            try await runtime.generateDetailed(prompt: "Merhaba /no_think", modelURL: model, onToken: { _ in
                await unloadGate.pauseFirst()
            })
        }
        await unloadGate.waitForFirst()
        await runtime.unload()
        await unloadGate.release()
        do { _ = try await unloaded.value; throw ProofFailure.failed("Unload did not invalidate generation") }
        catch is CancellationError { }
        let reloaded = try await runtime.generateDetailed(prompt: "Merhaba /no_think", modelURL: model)
        try require(!reloaded.metrics.warmModel && reloaded.metrics.modelLoadCount >= 2,
            "Explicit unload did not release/reload model weights")
        printMetrics("reload", reloaded.metrics)
        print("PASS unload during suspended streaming and safe cold reload")
        await runtime.configure(maxNewTokens: 48, contextLength: 1024, ownerInstructions: owner,
            temperature: 0, topP: 1, cpuThreads: 2)
    }

    static func proveEarlySpeechSentence(runtime: GGUFInferenceRuntime, model: URL,
        prompt: String = "Söylediğim iki cümleyi aynen tekrarla: Merhaba. Görüşmek üzere.") async throws {
        await runtime.configure(maxNewTokens: 96, contextLength: 1024,
            ownerInstructions: "Türkçe yanıt ver.", temperature: 0, topP: 1, cpuThreads: 2,
            preferFastResponse: true)
        let speech = SpeechTimingProbe()
        let answer = try await runtime.generateDetailed(
            prompt: prompt,
            modelURL: model, onToken: { delta in await speech.append(delta) })
        let timing = await speech.snapshot()
        try require(answer.renderedPrompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"),
            "Quick Qwen mode did not use the model's non-thinking template prefix")
        print("SPEECH_PROBE visible=\(VisibleResponseFilter.answer(from: answer.text)) raw_tokens=\(answer.generatedTokens) sentences=\(timing.count) fast_directive=\(answer.renderedPrompt.contains("/no_think"))")
        try require(timing.count > 0 && (timing.firstSentenceSeconds ?? .infinity) < timing.completedSeconds,
            "A real sentence was not ready for TTS before generation completed")
        print("PASS real speech sentence ready before model completion: first_sentence_s=\(timing.firstSentenceSeconds ?? -1) generation_s=\(answer.metrics.totalSeconds) sentences_before_completion=\(timing.count)")
    }

    static func printMetrics(_ label: String, _ metrics: LocalRuntimeMetrics) {
        let fields: [String: Any] = [
            "case": label, "warm_model": metrics.warmModel,
            "model_load_s": metrics.modelLoadSeconds, "context_init_s": metrics.contextInitSeconds,
            "prefill_s": metrics.prefillSeconds, "first_token_s": metrics.firstTokenSeconds,
            "total_s": metrics.totalSeconds, "output_tokens": metrics.outputTokens,
            "decode_tokens_per_second": metrics.tokensPerSecond,
            "resident_memory_bytes": metrics.residentMemoryBytes.map { $0 as Any } ?? NSNull(),
            "peak_resident_memory_bytes": metrics.peakResidentMemoryBytes.map { $0 as Any } ?? NSNull(),
            "thermal_start": metrics.thermalStateAtStart.map { $0 as Any } ?? NSNull(),
            "thermal_end": metrics.thermalState.map { $0 as Any } ?? NSNull(),
            "model_bytes": metrics.modelBytes, "model_load_count": metrics.modelLoadCount
        ]
        if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print("BENCHMARK " + text) }
    }

    static func verify() async throws {
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
        let qualityPassed = result.text.contains("Ankara")
        print(qualityPassed
            ? "MODEL_QUALITY_PASS capital question"
            : "MODEL_QUALITY_FAIL capital question: expected Ankara; no factual reliability claim")
        print("PASS exact multi-line owner prompt; prompt=\(result.promptTokens) output=\(result.generatedTokens) context=\(result.effectiveContext) gpu=\(result.gpuOffloadRequested)")
        try await proveStreamingAndResidency(runtime: runtime, model: model,
            cold: result, prompt: "Türkiye'nin başkenti neresidir? Kısa cevapla. /no_think", owner: owner)

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
        let loadsBeforeReplacement = await runtime.metrics?.modelLoadCount ?? 0
        let installedTime = try FileManager.default.attributesOfItem(atPath: installed.path)[.modificationDate]
        _ = try await manager.importModel(from: model, manifest: manifest)
        if let installedTime { try FileManager.default.setAttributes([.modificationDate: installedTime], ofItemAtPath: installed.path) }
        let replacement = try await runtime.generateDetailed(prompt: "Merhaba /no_think", modelURL: installed)
        try require(!replacement.metrics.warmModel && replacement.metrics.modelLoadCount == loadsBeforeReplacement + 1,
            "Atomic replacement with preserved size/mtime reused stale model weights")
        print("PASS resident identity invalidation after atomic replacement with preserved size/mtime")
        try await proveEarlySpeechSentence(runtime: runtime, model: model)
        await runtime.unload()
        print("REAL_RUNTIME_FUNCTIONAL_CHECKS_PASSED")
        // A visible quality failure must also fail CI; functional transport alone
        // must not produce an overall green result for the Turkish assistant.
        try require(qualityPassed, "MODEL_QUALITY_FAIL: Turkish capital answer is wrong")
        print("REAL_RUNTIME_PROOF_PASSED")
    }
}

private actor StreamProbe {
    private let clock = ContinuousClock()
    private let started = ContinuousClock.now
    private var text = ""
    private var count = 0
    private var firstSeconds: Double?
    private var lastSeconds = 0.0
    func append(_ delta: String) throws {
        guard !delta.isEmpty, !delta.contains("\u{FFFD}") else {
            throw RuntimeProof.ProofFailure.failed("Invalid/incomplete UTF-8 delta")
        }
        let elapsed = seconds(started.duration(to: clock.now))
        if firstSeconds == nil { firstSeconds = elapsed }
        lastSeconds = elapsed; count += 1; text += delta
    }
    func snapshot() -> (text: String, count: Int, firstSeconds: Double?, lastSeconds: Double, finishedSeconds: Double) {
        (text, count, firstSeconds, lastSeconds, seconds(started.duration(to: clock.now)))
    }
    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

private actor StreamGate {
    private var first = false
    private var waitingForFirst: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?
    func pauseFirst() async {
        guard !first else { return }
        first = true
        await withCheckedContinuation { continuation in
            paused = continuation
            waitingForFirst?.resume(); waitingForFirst = nil
        }
    }
    func waitForFirst() async {
        if first { return }
        await withCheckedContinuation { waitingForFirst = $0 }
    }
    func release() { paused?.resume(); paused = nil }
}

private actor SpeechTimingProbe {
    private let start = ProcessInfo.processInfo.systemUptime
    private var filter = VisibleResponseFilter()
    private var stream = TurkishSpeechStream()
    private var firstSentenceSeconds: Double?
    private var count = 0
    func append(_ delta: String) {
        let sentences = stream.append(filter.append(delta))
        if !sentences.isEmpty, firstSentenceSeconds == nil {
            firstSentenceSeconds = ProcessInfo.processInfo.systemUptime - start
        }
        count += sentences.count
    }
    func snapshot() -> (firstSentenceSeconds: Double?, completedSeconds: Double, count: Int) {
        (firstSentenceSeconds, ProcessInfo.processInfo.systemUptime - start, count)
    }
}
