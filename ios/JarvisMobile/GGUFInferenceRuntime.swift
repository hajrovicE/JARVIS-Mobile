import Foundation
import JarvisCore
import LlamaSwift

/// Owner-controlled generation settings; these are not content moderation rules.
/// llama.cpp requires a real context window and a finite per-request budget.
struct GGUFGenerationSettings: Sendable {
    var maxNewTokens: Int
    var contextLength: Int32
    var ownerInstructions: String
    var temperature: Float
    var topP: Float
    var cpuThreads: Int
    var showReasoning: Bool
}

/// A real, fully local llama.cpp generation engine.
/// No HTTP, server credentials, or analytics are involved in this implementation.
actor GGUFInferenceRuntime: OnDeviceInferenceRuntime {
    private let settings: GGUFGenerationSettings

    init(maxNewTokens: Int = 2048, contextLength: Int32 = 4096,
         ownerInstructions: String = "", temperature: Float = 0.8, topP: Float = 1.0,
         cpuThreads: Int = 0, showReasoning: Bool = false) {
        settings = GGUFGenerationSettings(
            maxNewTokens: max(1, min(Int(Int32.max - 1), maxNewTokens)),
            contextLength: max(512, contextLength),
            ownerInstructions: ownerInstructions,
            temperature: temperature.isFinite ? max(0, temperature) : 0.8,
            topP: topP.isFinite ? min(1, max(Float.leastNonzeroMagnitude, topP)) : 1.0,
            cpuThreads: cpuThreads,
            showReasoning: showReasoning)
    }

    func generate(prompt: String, modelURL: URL) async throws -> String {
        try Task.checkCancellation()
        guard modelURL.isFileURL, !prompt.isEmpty else { throw LocalModelError.invalidSource }
        return try await GGUFEngine.shared.generate(
            prompt: prompt, modelURL: modelURL, settings: settings)
    }

    /// Releases the resident model weights (for example on a memory warning).
    static func unloadModel() async { await GGUFEngine.shared.unload() }
}

/// Keeps the owner's model loaded between messages so only the first request pays
/// the load cost. Actor isolation serializes generation and unloading, so the
/// weights can never be freed while a request is still using them.
private actor GGUFEngine {
    static let shared = GGUFEngine()

    private var backendReady = false
    private var loadedPath: String?
    private var model: OpaquePointer?

    func unload() {
        if let model { llama_model_free(model) }
        model = nil
        loadedPath = nil
    }

    private func residentModel(at url: URL) throws -> OpaquePointer {
        if let model, loadedPath == url.path { return model }
        unload()
        if !backendReady {
            llama_backend_init()
            backendReady = true
        }
        var modelParameters = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParameters.n_gpu_layers = 0
        #else
        modelParameters.n_gpu_layers = 999
        #endif
        guard let loaded = llama_model_load_from_file(url.path, modelParameters) else {
            throw LocalModelError.invalidFile
        }
        model = loaded
        loadedPath = url.path
        return loaded
    }

    private func tokenize(_ text: String, special: Bool,
                          vocabulary: OpaquePointer) throws -> [llama_token] {
        let byteCount = text.utf8.count
        guard byteCount > 0 else { return [] }
        guard byteCount < Int(Int32.max - 8) else { throw LocalModelError.inferenceFailed }
        let capacity = byteCount + 8
        var buffer = [llama_token](repeating: 0, count: capacity)
        let count = text.withCString { pointer in
            llama_tokenize(vocabulary, pointer, Int32(byteCount), &buffer,
                           Int32(capacity), false, special)
        }
        guard count >= 0 else { throw LocalModelError.inferenceFailed }
        return Array(buffer.prefix(Int(count)))
    }

    func generate(prompt: String, modelURL: URL,
                  settings: GGUFGenerationSettings) throws -> String {
        try Task.checkCancellation()
        let model = try residentModel(at: modelURL)

        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(settings.contextLength)
        contextParameters.n_batch = 512
        contextParameters.n_ubatch = 512
        // 0 means automatic: use all processor cores the OS exposes.
        let selectedThreads = settings.cpuThreads > 0
            ? settings.cpuThreads : ProcessInfo.processInfo.activeProcessorCount
        let threads = max(1, min(Int(Int32.max), selectedThreads))
        contextParameters.n_threads = Int32(threads)
        contextParameters.n_threads_batch = Int32(threads)

        guard let context = llama_init_from_model(model, contextParameters) else {
            // Usually the context window does not fit in this device's free memory.
            throw LocalModelError.inferenceFailed
        }
        defer { llama_free(context) }

        guard let vocabulary = llama_model_get_vocab(model) else {
            throw LocalModelError.inferenceFailed
        }

        // Qwen3-family (ChatML) chat template; other model families require
        // a separate tokenizer/template compatibility check.
        // No built-in behavioral system prompt: every instruction is set by the owner.
        // ActionExecutor independently rejects model-issued device operations.
        // Template markers are parsed as control tokens; owner and memory text is not,
        // so stored text can never forge a chat turn.
        let ownerInstructions = settings.ownerInstructions
        let systemTurn = ownerInstructions.isEmpty ? [] : [
            ("<|im_start|>system\n", true), (ownerInstructions, false), ("<|im_end|>\n", true),
        ]
        var prefix = [llama_token]()
        for (text, special) in systemTurn + [("<|im_start|>user\n", true)] {
            prefix += try tokenize(text, special: special, vocabulary: vocabulary)
        }
        let body = try tokenize(prompt, special: false, vocabulary: vocabulary)
        let suffix = try tokenize("<|im_end|>\n<|im_start|>assistant\n", special: true,
                                  vocabulary: vocabulary)

        // Reserve part of the real context window for the answer; when saved history
        // has outgrown the window, the oldest prompt tokens are dropped first.
        let window = Int(llama_n_ctx(context))
        let reserve = min(settings.maxNewTokens, max(1, window / 4))
        guard let tokens = PromptWindow.fit(prefix: prefix, body: body, suffix: suffix,
                                            limit: window - reserve), !tokens.isEmpty else {
            throw LocalModelError.inferenceFailed
        }
        let generationBudget = min(settings.maxNewTokens, window - tokens.count)

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
                    throw LocalModelError.inferenceFailed
                }
                sequenceIDs[0] = 0
                batch.logits[index] = (sourceIndex == tokens.count - 1) ? 1 : 0
            }
            guard llama_decode(context, batch) == 0 else {
                throw LocalModelError.inferenceFailed
            }
        }

        // The owner can select deterministic output (temperature 0) or sampling.
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw LocalModelError.inferenceFailed
        }
        defer { llama_sampler_free(sampler) }
        if settings.temperature == 0 {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(settings.topP, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(settings.temperature))
            llama_sampler_chain_add(
                sampler, llama_sampler_init_dist(UInt32.random(in: UInt32.min...UInt32.max)))
        }

        var bytes = [UInt8]()
        bytes.reserveCapacity(min(32_768, generationBudget) * 5)
        var position = Int32(tokens.count)

        for _ in 0..<generationBudget {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }

            var piece = [CChar](repeating: 0, count: 64)
            var written = llama_token_to_piece(vocabulary, token, &piece, 64, 0, false)
            if written < 0 {
                guard written >= -8192 else { throw LocalModelError.inferenceFailed }
                let needed = -written
                piece = [CChar](repeating: 0, count: Int(needed))
                written = llama_token_to_piece(vocabulary, token, &piece, needed, 0, false)
            }
            guard written >= 0, Int(written) <= piece.count else {
                throw LocalModelError.inferenceFailed
            }
            bytes.append(contentsOf: piece.prefix(Int(written)).map { UInt8(bitPattern: $0) })

            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = position
            batch.n_seq_id[0] = 1
            guard let sequenceIDs = batch.seq_id[0] else {
                throw LocalModelError.inferenceFailed
            }
            sequenceIDs[0] = 0
            batch.logits[0] = 1
            guard llama_decode(context, batch) == 0 else {
                throw LocalModelError.inferenceFailed
            }
            position += 1
        }

        try Task.checkCancellation()
        let raw = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = settings.showReasoning ? raw : ModelOutput.withoutReasoning(raw)
        guard !answer.isEmpty else { throw LocalModelError.emptyOutput }
        return answer
    }
}
