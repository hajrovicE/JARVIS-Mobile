import Foundation
import JarvisCore
import LlamaSwift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A real, fully local llama.cpp generation engine.
/// No HTTP, server credentials, or analytics are involved in this implementation.
private enum GGUFBackend {
    static let ready: Bool = {
        // llama.cpp diagnostics can include prompt/model metadata. Product logs stay silent.
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
        return true
    }()
}

struct GGUFGeneration: Sendable {
    let text: String
    let renderedPrompt: String
    let promptTokens: Int
    let generatedTokens: Int
    let requestedMaxTokens: Int
    let effectiveContext: Int
    let threads: Int
    let temperature: Float
    let topP: Float
    let gpuOffloadRequested: Bool
}

actor GGUFInferenceRuntime: OnDeviceInferenceRuntime {
    private let maxNewTokens: Int
    private let contextLength: Int32
    private let ownerInstructions: String
    private let temperature: Float
    private let topP: Float
    private let cpuThreads: Int

    /// These are user-controlled generation settings, not content moderation rules.
    /// A real context window and finite per-request generation budget are required by llama.cpp.
    init(maxNewTokens: Int = 2048, contextLength: Int32 = 8192,
         ownerInstructions: String = "", temperature: Float = 0.8, topP: Float = 1.0,
         cpuThreads: Int = 0) {
        self.maxNewTokens = maxNewTokens
        self.contextLength = contextLength
        self.ownerInstructions = ownerInstructions
        self.temperature = temperature
        self.topP = topP
        self.cpuThreads = cpuThreads
    }

    func generate(prompt: String, modelURL: URL) async throws -> String {
        try await generateDetailed(prompt: prompt, modelURL: modelURL).text
    }

    func generateDetailed(prompt: String, modelURL: URL) async throws -> GGUFGeneration {
        try Task.checkCancellation()
        guard maxNewTokens > 0, maxNewTokens < Int(Int32.max), contextLength > 0,
              temperature.isFinite, temperature >= 0, topP.isFinite, topP > 0, topP <= 1,
              cpuThreads >= 0, cpuThreads <= Int(Int32.max),
              !ownerInstructions.utf8.contains(0), !prompt.utf8.contains(0) else {
            throw LocalModelError.invalidSettings
        }
        guard modelURL.isFileURL, !prompt.isEmpty else { throw LocalModelError.invalidSource }
        _ = GGUFBackend.ready

        var modelParameters = llama_model_default_params()
        #if (os(iOS) && !targetEnvironment(simulator)) || os(macOS)
        let gpuRequested = llama_supports_gpu_offload()
        #else
        let gpuRequested = false
        #endif
        modelParameters.n_gpu_layers = gpuRequested ? Int32.max : 0

        guard let model = llama_model_load_from_file(modelURL.path, modelParameters) else {
            throw LocalModelError.invalidFile
        }
        defer { llama_model_free(model) }

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(contextLength)
        contextParameters.n_batch = 512
        contextParameters.n_ubatch = 512
        // 0 means automatic: use all processor cores the OS exposes.
        let selectedThreads = cpuThreads > 0 ? cpuThreads : ProcessInfo.processInfo.activeProcessorCount
        let threads = max(1, min(Int(Int32.max), selectedThreads))
        contextParameters.n_threads = Int32(threads)
        contextParameters.n_threads_batch = Int32(threads)

        guard let context = llama_init_from_model(model, contextParameters) else {
            throw LocalModelError.runtimeUnavailable
        }
        defer { llama_free(context) }

        guard let vocabulary = llama_model_get_vocab(model) else {
            throw LocalModelError.runtimeUnavailable
        }

        // Use the model's own format. No hardcoded behavioral instruction is injected.
        // ActionExecutor, not model text, controls direct owner operations.
        guard let template = llama_model_chat_template(model, nil) else { throw LocalModelError.unsupportedTemplate }
        var allocations: [UnsafeMutablePointer<CChar>] = []
        defer { allocations.forEach { free($0) } }
        func cString(_ value: String) throws -> UnsafePointer<CChar> {
            guard let pointer = strdup(value) else { throw LocalModelError.runtimeUnavailable }
            allocations.append(pointer); return UnsafePointer(pointer)
        }
        var messages: [llama_chat_message] = []
        if !ownerInstructions.isEmpty {
            messages.append(llama_chat_message(role: try cString("system"), content: try cString(ownerInstructions)))
        }
        messages.append(llama_chat_message(role: try cString("user"), content: try cString(prompt)))
        let required = messages.withUnsafeBufferPointer {
            llama_chat_apply_template(template, $0.baseAddress, $0.count, true, nil, 0)
        }
        guard required > 0, required < Int32.max - 1 else { throw LocalModelError.unsupportedTemplate }
        var rendered = [CChar](repeating: 0, count: Int(required) + 1)
        let renderedCount = messages.withUnsafeBufferPointer {
            llama_chat_apply_template(template, $0.baseAddress, $0.count, true, &rendered, Int32(rendered.count))
        }
        guard renderedCount == required else { throw LocalModelError.unsupportedTemplate }
        let renderedPrompt = String(decoding: rendered.prefix(Int(renderedCount)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        let byteCount = renderedPrompt.utf8.count
        guard byteCount < Int(Int32.max - 8) else { throw LocalModelError.runtimeUnavailable }
        let capacity = byteCount + 8
        var tokenBuffer = [llama_token](repeating: 0, count: capacity)
        let nTokens = renderedPrompt.withCString { ptr in
            llama_tokenize(vocabulary, ptr, Int32(byteCount), &tokenBuffer,
                           Int32(capacity), true, true)
        }
        let effectiveContext = Int(llama_n_ctx(context))
        guard nTokens > 0, Int(nTokens) < min(Int(contextLength), effectiveContext) else {
            throw LocalModelError.contextExceeded
        }
        // The model's actual context window determines the generation budget.
        // Do not underflow or overflow Int32 when the owner selects large budgets.
        let generationBudget = min(maxNewTokens, min(Int(contextLength), effectiveContext) - Int(nTokens))
        let tokens = Array(tokenBuffer.prefix(Int(nTokens)))

        var batch = llama_batch_init(512, 0, 1)
        defer { llama_batch_free(batch) }

        // Chunk the prompt rather than overflowing the 512-token physical batch.
        for offset in stride(from: 0, to: tokens.count, by: 512) {
            try Task.checkCancellation()
            let count = min(512, tokens.count - offset)
            batch.n_tokens = Int32(count)
            for index in 0..<count {
                let sourceIndex = offset + index
                batch.token[index] = tokens[sourceIndex]
                batch.pos[index] = Int32(sourceIndex)
                batch.n_seq_id[index] = 1
                guard let sequenceIDs = batch.seq_id[index] else {
                    throw LocalModelError.runtimeUnavailable
                }
                sequenceIDs[0] = 0
                batch.logits[index] = (sourceIndex == tokens.count - 1) ? 1 : 0
            }
            guard llama_decode(context, batch) == 0 else {
                throw LocalModelError.runtimeUnavailable
            }
        }

        // The owner can select deterministic output (temperature 0) or sampling.
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw LocalModelError.runtimeUnavailable
        }
        defer { llama_sampler_free(sampler) }
        if temperature == 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(topP, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(UInt32.random(in: UInt32.min...UInt32.max)))
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(min(32_768, maxNewTokens) * 5)
        var position = Int32(tokens.count)

        var generatedTokens = 0
        for step in 0..<generationBudget {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }

            var piece = [CChar](repeating: 0, count: 64)
            var written = llama_token_to_piece(vocabulary, token, &piece,
                                               Int32(piece.count), 0, false)
            if written < 0 {
                guard written >= -8192 else { throw LocalModelError.runtimeUnavailable }
                piece = [CChar](repeating: 0, count: Int(-written))
                written = llama_token_to_piece(vocabulary, token, &piece,
                                               Int32(piece.count), 0, false)
            }
            guard written >= 0, written <= Int32(piece.count) else {
                throw LocalModelError.runtimeUnavailable
            }
            bytes.append(contentsOf: piece.prefix(Int(written)).map { UInt8(bitPattern: $0) })
            generatedTokens += 1
            // The last sampled token need not be decoded into the next context position.
            if step + 1 == generationBudget { break }

            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = position
            batch.n_seq_id[0] = 1
            guard let sequenceIDs = batch.seq_id[0] else {
                throw LocalModelError.runtimeUnavailable
            }
            sequenceIDs[0] = 0
            batch.logits[0] = 1
            guard llama_decode(context, batch) == 0 else {
                throw LocalModelError.runtimeUnavailable
            }
            position += 1
        }

        try Task.checkCancellation()
        let answer = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw LocalModelError.emptyOutput }
        return GGUFGeneration(text: answer, renderedPrompt: renderedPrompt,
            promptTokens: Int(nTokens), generatedTokens: generatedTokens,
            requestedMaxTokens: maxNewTokens, effectiveContext: effectiveContext,
            threads: threads, temperature: temperature, topP: topP, gpuOffloadRequested: gpuRequested)
    }
}
