import Foundation
import XCTest
import JarvisCore
@testable import JarvisMobile

/// Runs the application's production runtime against real GGUF weights. The
/// simulator exercises CPU inference; it cannot prove physical iPhone Metal.
@MainActor
final class GGUFInferenceTests: XCTestCase {
    private func realModel() throws -> URL {
        let bundle = Bundle(for: GGUFInferenceTests.self)
        let model = bundle.url(forResource: "model", withExtension: "gguf", subdirectory: "Fixtures")
        let required = bundle.url(forResource: "real-inference-required", withExtension: "txt", subdirectory: "Fixtures")
        if let model { return model }
        #if JARVIS_REAL_INFERENCE_REQUIRED
        XCTFail("CI requires real GGUF inference, but the model fixture was not bundled")
        throw CocoaError(.fileNoSuchFile)
        #else
        if required != nil {
            XCTFail("CI required real GGUF inference, but the model fixture was not bundled")
            throw CocoaError(.fileNoSuchFile)
        }
        throw XCTSkip("Real GGUF weights were not staged. Real inference is NOT verified by this run.")
        #endif
    }

    func testRealInferencePreservesEntireOwnerSystemTurnAndSettings() async throws {
        let model = try realModel()
        try GGUFFileValidator.validate(at: model)
        let owner = "  Sahibin talimatı: Türkçe yanıt ver.\nÖzel satır: İĞŞçöü — korunmalı.  "
        let prompt = "Merhaba. /no_think"
        let runtime = GGUFInferenceRuntime(maxNewTokens: 32, contextLength: 1024,
            ownerInstructions: owner, temperature: 0, topP: 1, cpuThreads: 2)
        let result = try await runtime.generateDetailed(prompt: prompt, modelURL: model)
        // Qwen fixture has a known chat template; preserve the literal system
        // content, including whitespace and Unicode, rather than adding policy.
        XCTAssertTrue(result.renderedPrompt.contains("<|im_start|>system\n" + owner + "<|im_end|>"))
        XCTAssertTrue(result.renderedPrompt.contains(prompt))
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertGreaterThan(result.promptTokens, 0)
        XCTAssertGreaterThan(result.generatedTokens, 0)
        XCTAssertLessThanOrEqual(result.generatedTokens, 32)
        XCTAssertEqual(result.requestedMaxTokens, 32)
        XCTAssertEqual(result.threads, 2)
        XCTAssertEqual(result.temperature, 0)
        XCTAssertEqual(result.topP, 1)
        XCTAssertGreaterThanOrEqual(result.effectiveContext, 1024)
        #if targetEnvironment(simulator)
        XCTAssertFalse(result.gpuOffloadRequested)
        #endif
    }

    func testRealLongOwnerPromptUsesMultiplePrefillBatchesWithoutTruncation() async throws {
        let model = try realModel()
        let owner = "  Başlangıç: İĞŞçöü — sahibin talimatları.\n"
            + String(repeating: "Kalıcı talimat: Türkçe metni eksiksiz koru; çığ, şişe, öğle.\n", count: 64)
            + "Son satır: ÖÜİğşç korunmalı.  "
        let runtime = GGUFInferenceRuntime(maxNewTokens: 3, contextLength: 4096,
            ownerInstructions: owner, temperature: 0, topP: 1, cpuThreads: 2)
        let result = try await runtime.generateDetailed(prompt: "Merhaba. /no_think", modelURL: model)
        XCTAssertTrue(result.renderedPrompt.contains("<|im_start|>system\n" + owner + "<|im_end|>"))
        // More than 512 tokens ensures the production prefill loop actually
        // decodes several batches rather than only rendering a long string.
        XCTAssertGreaterThan(result.promptTokens, 512)
        XCTAssertLessThan(result.promptTokens, 4096)
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertGreaterThan(result.generatedTokens, 0)
        XCTAssertLessThanOrEqual(result.generatedTokens, 3)
    }

    func testRealSamplingTokenLimitEmptyOwnerAndReload() async throws {
        let model = try realModel()
        // Each actor loads and frees the actual file. The second call exercises
        // reopening it with different settings, with no persisted fake response.
        for temperature: Float in [0, 0.65] {
            let runtime = GGUFInferenceRuntime(maxNewTokens: 3, contextLength: 512,
                ownerInstructions: "", temperature: temperature, topP: 0.85, cpuThreads: 1)
            let result = try await runtime.generateDetailed(prompt: "Türkçe bir selam yaz. /no_think", modelURL: model)
            XCTAssertFalse(result.renderedPrompt.contains("<|im_start|>system\n"))
            XCTAssertGreaterThan(result.generatedTokens, 0)
            XCTAssertLessThanOrEqual(result.generatedTokens, 3)
            XCTAssertEqual(result.temperature, temperature)
            XCTAssertEqual(result.topP, 0.85)
            XCTAssertEqual(result.threads, 1)
        }
    }

    func testRealContextOverflowIsAnErrorRatherThanSilentTruncation() async throws {
        let model = try realModel()
        let runtime = GGUFInferenceRuntime(maxNewTokens: 16, contextLength: 128,
            temperature: 0, cpuThreads: 1)
        do {
            _ = try await runtime.generate(prompt: String(repeating: "bağlam denemesi ", count: 300), modelURL: model)
            XCTFail("An oversized prompt must not be silently shortened")
        } catch let error as LocalModelError {
            XCTAssertEqual(error, .contextExceeded)
        }
    }

    func testInvalidSettingsAreNotSilentlyClamped() async throws {
        let unused = URL(fileURLWithPath: "/unused-model.gguf")
        let runtimes = [
            GGUFInferenceRuntime(repetitionPenalty: .nan),
            GGUFInferenceRuntime(repetitionPenalty: 0),
            GGUFInferenceRuntime(repetitionWindow: -1),
            GGUFInferenceRuntime(maxNewTokens: 0),
            GGUFInferenceRuntime(contextLength: 0),
            GGUFInferenceRuntime(temperature: .nan),
            GGUFInferenceRuntime(topP: 0),
            GGUFInferenceRuntime(cpuThreads: -1),
            GGUFInferenceRuntime(ownerInstructions: "before\0after")
        ]
        for runtime in runtimes {
            do {
                _ = try await runtime.generate(prompt: "Merhaba", modelURL: unused)
                XCTFail("Invalid owner settings must produce an explicit error")
            } catch let error as LocalModelError {
                XCTAssertEqual(error, .invalidSettings)
            }
        }
    }

    func testCorruptFileDoesNotProduceAResponse() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("GGUFbroken model".utf8).write(to: file)
        do {
            _ = try await GGUFInferenceRuntime(maxNewTokens: 8).generate(prompt: "Merhaba", modelURL: file)
            XCTFail("A corrupt model must not yield a fabricated response")
        } catch let error as LocalModelError {
            XCTAssertEqual(error, .invalidFile)
        }
    }

    func testPrecancelledGenerationStopsBeforeLoadingAModel() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GGUFInferenceRuntime().generate(
                prompt: "Merhaba", modelURL: URL(fileURLWithPath: "/unused-model.gguf"))
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled generation must not report success")
        } catch is CancellationError {
            // Expected before model loading, not a model-file failure.
        }
    }
}
