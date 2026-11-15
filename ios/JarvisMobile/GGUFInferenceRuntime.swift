import Foundation
import JarvisCore
import LlamaSwift

/// A real, fully local llama.cpp generation engine.
/// No HTTP, server credentials, or analytics are involved in this implementation.
private enum GGUFBackend {
    static let ready: Bool = {
        llama_backend_init()
        return true
    }()
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
        self.maxNewTokens = max(1, min(Int(Int32.max - 1), maxNewTokens))
        self.contextLength = max(512, contextLength)
        self.ownerInstructions = ownerInstructions
        self.temperature = temperature.isFinite ? max(0, temperature) : 0.8
        self.topP = topP.isFinite ? min(1, max(Float.leastNonzeroMagnitude, topP)) : 1.0
        self.cpuThreads = cpuThreads
    }

    func generate(prompt: String, modelURL: URL) async throws -> String {
        try Task.checkCancellation()
        guard modelURL.isFileURL, !prompt.isEmpty else { throw LocalModelError.invalidSource }
        _ = GGUFBackend.ready

        var modelParameters = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParameters.n_gpu_layers = 0
        #else
        modelParameters.n_gpu_layers = Int32.max
        #endif

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

        // Qwen3-family chat template; changes for other model families require
        // a separate tokenizer/template compatibility check.
        // The owner controls this local policy. No remote model provider is consulted.
        // The owner defines the model's behavior in the iPhone app settings.
        // Authority for actual phone actions is enforced by ActionExecutor, not this prompt.
        let localSystem = """
        Sen JARVIS isimli, cihaz üzerinde çalışan Türkçe yapay zekâsın.
        Sahibinin doğrudan komutu olmadan telefon işlemi başlatma.
        """ + (ownerInstructions.isEmpty ? "" : "\n" + ownerInstructions)
        let renderedPrompt = "<|im_start|>system\n" + localSystem
            + "\n<|im_end|>\n<|im_start|>user\n" + prompt
            + "\n<|im_end|>\n<|im_start|>assistant\n"
        let byteCount = renderedPrompt.utf8.count
        guard byteCount < Int(Int32.max - 8) else { throw LocalModelError.runtimeUnavailable }
        let capacity = byteCount + 8
        var tokenBuffer = [llama_token](repeating: 0, count: capacity)
        let nTokens = renderedPrompt.withCString { ptr in
            llama_tokenize(vocabulary, ptr, Int32(byteCount), &tokenBuffer,
                           Int32(capacity), false, true)
        }
        guard nTokens > 0, nTokens < contextLength else {
            throw LocalModelError.runtimeUnavailable
        }
        // The model's actual context window determines the generation budget.
        // Do not underflow or overflow Int32 when the owner selects large budgets.
        let generationBudget = min(maxNewTokens, Int(contextLength - nTokens))
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

        for _ in 0..<generationBudget {
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
        return answer
    }
}
