import Foundation
import XCTest
import JarvisCore
@testable import JarvisMobile

/// Actual production native streaming against real weights, never a stub answer.
/// Simulator results are CPU checks and cannot certify iPhone Metal/thermal/audio.
final class GGUFStreamingTests: XCTestCase, @unchecked Sendable {
    private func model() throws -> URL {
        let bundle = Bundle(for: GGUFStreamingTests.self)
        if let model = bundle.url(forResource: "model", withExtension: "gguf", subdirectory: "Fixtures") { return model }
        #if JARVIS_REAL_INFERENCE_REQUIRED
        XCTFail("CI requires the real GGUF fixture for streaming tests")
        throw CocoaError(.fileNoSuchFile)
        #else
        if bundle.url(forResource: "real-inference-required", withExtension: "txt", subdirectory: "Fixtures") != nil {
            XCTFail("Required model fixture was not bundled")
            throw CocoaError(.fileNoSuchFile)
        }
        throw XCTSkip("Real GGUF weights absent; native streaming is NOT verified")
        #endif
    }

    func testQuickModeUsesModelNonThinkingPrefixAndPreservesExplicitOwnerChoice() async throws {
        let file = try model()
        let owner = "  Sahibin değişmemiş talimatı: İğde.  "
        let runtime = GGUFInferenceRuntime(maxNewTokens: 3, contextLength: 1024,
            ownerInstructions: owner, temperature: 0, cpuThreads: 2, preferFastResponse: true)
        let quick = try await runtime.generateDetailed(prompt: "Merhaba", modelURL: file)
        XCTAssertTrue(quick.renderedPrompt.contains("<|im_start|>system\n" + owner + "<|im_end|>"))
        XCTAssertTrue(quick.renderedPrompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
        let explicit = try await runtime.generateDetailed(prompt: "/think Merhaba", modelURL: file)
        XCTAssertFalse(explicit.renderedPrompt.contains("/no_think"))
        XCTAssertFalse(explicit.renderedPrompt.hasSuffix("<think>\n\n</think>\n\n"))
        await runtime.unload()
    }

    func testByteSplitTurkishAndEmojiRemainValidUTF8() async throws {
        let text = "İğne, ölçü, şişe; merhaba 👩🏽‍💻! 🇹🇷"
        var decoder = UTF8TokenDecoder()
        var delivered = ""
        for byte in text.utf8 {
            let delta = decoder.append([byte])
            XCTAssertFalse(delta.contains("\u{FFFD}"))
            delivered += delta
        }
        delivered += decoder.finish()
        XCTAssertEqual(delivered, text)
    }

    func testWarmWeightsStreamRealUTF8DeltasBeforeCompletion() async throws {
        let model = try model()
        let runtime = GGUFInferenceRuntime(maxNewTokens: 32, contextLength: 1024,
            ownerInstructions: "Türkçe cevapla. /no_think", temperature: 0, topP: 1, cpuThreads: 2)
        let cold = try await runtime.generateDetailed(prompt: "Türkiye'nin başkenti? /no_think", modelURL: model)
        let probe = NativeTokenProbe()
        let warm = try await runtime.generateDetailed(prompt: "Türkiye'nin başkenti? /no_think", modelURL: model,
            onToken: { try await probe.append($0) })
        let delivered = await probe.snapshot()
        XCTAssertFalse(cold.metrics.warmModel)
        XCTAssertTrue(warm.metrics.warmModel)
        XCTAssertEqual(cold.metrics.modelLoadCount, warm.metrics.modelLoadCount)
        XCTAssertEqual(cold.renderedPrompt, warm.renderedPrompt)
        XCTAssertEqual(cold.promptTokens, warm.promptTokens)
        XCTAssertGreaterThan(delivered.count, 1)
        XCTAssertFalse(delivered.text.contains("\u{FFFD}"))
        XCTAssertEqual(delivered.text.trimmingCharacters(in: .whitespacesAndNewlines), warm.text)
        XCTAssertGreaterThan(warm.metrics.firstTokenSeconds, 0)
        XCTAssertGreaterThanOrEqual(warm.metrics.totalSeconds, warm.metrics.firstTokenSeconds)
        XCTAssertGreaterThan(warm.metrics.outputTokens, 0)
        XCTAssertEqual(warm.metrics.modelBytes, UInt64(try model.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
        await runtime.unload()
    }

    func testMidstreamTaskCancellationHasNoFurtherDeltasAndModelCanBeReused() async throws {
        let model = try model()
        let runtime = GGUFInferenceRuntime(maxNewTokens: 32, contextLength: 1024,
            temperature: 0, cpuThreads: 2)
        let probe = NativeTokenProbe()
        let cancelled = Task {
            try await runtime.generateDetailed(prompt: "Türkçe bir cümle yaz. /no_think", modelURL: model,
                onToken: { delta in
                    try await probe.append(delta)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do { _ = try await cancelled.value; XCTFail("Midstream cancellation must fail, not finalize a partial answer") }
        catch is CancellationError { }
        let partial = await probe.snapshot()
        XCTAssertEqual(partial.count, 1)
        let restarted = try await runtime.generateDetailed(prompt: "Merhaba /no_think", modelURL: model)
        XCTAssertTrue(restarted.metrics.warmModel)
        XCTAssertFalse(restarted.text.isEmpty)
        await runtime.unload()
    }

    func testUnloadFromStreamingCallbackStopsTurnAndReloadsCleanly() async throws {
        let model = try model()
        let runtime = GGUFInferenceRuntime(maxNewTokens: 16, contextLength: 1024,
            temperature: 0, cpuThreads: 2)
        let probe = NativeTokenProbe()
        do {
            _ = try await runtime.generateDetailed(prompt: "Merhaba /no_think", modelURL: model,
                onToken: { delta in
                    try await probe.append(delta)
                    await runtime.unload()
                })
            XCTFail("A suspended turn invalidated by unload must not report success")
        } catch is CancellationError { }
        let partial = await probe.snapshot()
        XCTAssertEqual(partial.count, 1)
        let restarted = try await runtime.generateDetailed(prompt: "Merhaba /no_think", modelURL: model)
        XCTAssertFalse(restarted.metrics.warmModel)
        XCTAssertGreaterThanOrEqual(restarted.metrics.modelLoadCount, 2)
        await runtime.unload()
    }
}

private actor NativeTokenProbe {
    private var text = ""
    private var count = 0
    func append(_ delta: String) throws {
        guard !delta.isEmpty else { throw CocoaError(.coderInvalidValue) }
        text += delta; count += 1
    }
    func snapshot() -> (text: String, count: Int) { (text, count) }
}
