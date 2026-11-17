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

/// Ephemeral measured counters; never includes prompts, audio or owner memory.
struct LocalRuntimeMetrics: Equatable, Sendable {
    let warmModel: Bool
    let modelLoadSeconds: Double
    let contextInitSeconds: Double
    let prefillSeconds: Double
    let firstTokenSeconds: Double
    let totalSeconds: Double
    let outputTokens: Int
    let tokensPerSecond: Double
    let residentMemoryBytes: UInt64?
    let peakResidentMemoryBytes: UInt64?
    let thermalState: String?
    let thermalStateAtStart: String?
    let modelBytes: UInt64
    let modelLoadCount: Int
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
    let repetitionPenalty: Float
    let requestedRepetitionWindow: Int
    let repetitionWindow: Int
    let gpuOffloadRequested: Bool
    let metrics: LocalRuntimeMetrics
}

/// File identity, not an owner checksum gate. Atomic replacements remain visible
/// even when the replacement preserves the old byte count and modification date.
private struct GGUFFileIdentity: Equatable {
    let path: String
    let bytes: UInt64
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(url: URL) throws {
        var information = stat()
        guard url.isFileURL, lstat(url.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG, information.st_size >= 0 else {
            throw LocalModelError.invalidFile
        }
        path = url.standardizedFileURL.path
        bytes = UInt64(information.st_size)
        device = UInt64(truncatingIfNeeded: information.st_dev)
        inode = UInt64(information.st_ino)
        #if canImport(Darwin)
        modifiedSeconds = Int64(information.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        changedSeconds = Int64(information.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(information.st_ctimespec.tv_nsec)
        #else
        modifiedSeconds = Int64(information.st_mtim.tv_sec)
        modifiedNanoseconds = Int64(information.st_mtim.tv_nsec)
        changedSeconds = Int64(information.st_ctim.tv_sec)
        changedNanoseconds = Int64(information.st_ctim.tv_nsec)
        #endif
    }
}

private final class ResidentGGUFModel {
    let pointer: OpaquePointer
    let identity: GGUFFileIdentity
    let gpuOffloadRequested: Bool
    init(pointer: OpaquePointer, identity: GGUFFileIdentity, gpuOffloadRequested: Bool) {
        self.pointer = pointer; self.identity = identity
        self.gpuOffloadRequested = gpuOffloadRequested
    }
    deinit { llama_model_free(pointer) }
}

/// The native abort callback runs on worker threads outside the Swift task. A
/// locked signal bridges cancellation without touching actor-owned native state.
private final class GGUFAbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

/// Keeps incomplete UTF-8 bytes between model tokens. Valid split Turkish/emoji
/// scalars never become replacement characters merely because a token ended.
struct UTF8TokenDecoder: Sendable {
    private var pending: [UInt8] = []
    mutating func append(_ bytes: [UInt8]) -> String {
        pending += bytes
        var cursor = 0
        while cursor < pending.count {
            let first = pending[cursor]
            let width: Int
            if first < 0x80 { width = 1 }
            else if first >= 0xC2 && first <= 0xDF { width = 2 }
            else if first >= 0xE0 && first <= 0xEF { width = 3 }
            else if first >= 0xF0 && first <= 0xF4 { width = 4 }
            else { cursor += 1; continue }
            // Only defer a potentially valid incomplete scalar. Malformed bytes
            // must not trap all subsequent text in the pending buffer.
            var validPrefix = true
            for part in 1..<min(width, pending.count - cursor) {
                let byte = pending[cursor + part]
                if byte < 0x80 || byte > 0xBF ||
                    (part == 1 && first == 0xE0 && byte < 0xA0) ||
                    (part == 1 && first == 0xED && byte > 0x9F) ||
                    (part == 1 && first == 0xF0 && byte < 0x90) ||
                    (part == 1 && first == 0xF4 && byte > 0x8F) {
                    validPrefix = false; break
                }
            }
            if !validPrefix { cursor += 1; continue }
            if cursor + width > pending.count { break }
            cursor += width
        }
        guard cursor > 0 else { return "" }
        let value = String(decoding: pending.prefix(cursor), as: UTF8.self)
        pending.removeFirst(cursor)
        return value
    }
    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }
}

private enum RuntimeProcessSample {
    static func residentBytes() -> UInt64? {
        #if canImport(Darwin)
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(information.resident_size) : nil
        #elseif os(Linux)
        guard let status = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8),
              let pages = status.split(separator: " ").dropFirst().first.flatMap({ UInt64($0) }) else { return nil }
        let pageSize = sysconf(Int32(_SC_PAGESIZE))
        return pageSize > 0 ? pages * UInt64(pageSize) : nil
        #else
        return nil
        #endif
    }
    static func peakResidentBytes() -> UInt64? {
        var information = rusage()
        #if canImport(Darwin)
        guard getrusage(RUSAGE_SELF, &information) == 0 else { return nil }
        return UInt64(max(0, information.ru_maxrss))
        #elseif os(Linux)
        guard getrusage(Int32(RUSAGE_SELF.rawValue), &information) == 0 else { return nil }
        return UInt64(max(0, information.ru_maxrss)) * 1024
        #else
        return nil
        #endif
    }
    static func thermalState() -> String? {
        #if os(iOS) || os(macOS)
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
        #else
        return nil
        #endif
    }
}

actor GGUFInferenceRuntime: OnDeviceInferenceRuntime {
    private struct Settings: Sendable {
        let maxNewTokens: Int
        let contextLength: Int32
        let ownerInstructions: String
        let temperature: Float
        let topP: Float
        let cpuThreads: Int
        let preferFastResponse: Bool
        let repetitionPenalty: Float
        let repetitionWindow: Int
    }
    private var settings: Settings
    private var resident: ResidentGGUFModel?
    private var activeGeneration: UUID?
    private var activeAbort: GGUFAbortFlag?
    private var modelLoadCount = 0
    private(set) var metrics: LocalRuntimeMetrics?

    init(maxNewTokens: Int = 2048, contextLength: Int32 = 8192,
         ownerInstructions: String = "", temperature: Float = 0.8, topP: Float = 1.0,
         cpuThreads: Int = 0, preferFastResponse: Bool = false,
         repetitionPenalty: Float = 1, repetitionWindow: Int = 64) {
        settings = Settings(maxNewTokens: maxNewTokens, contextLength: contextLength,
            ownerInstructions: ownerInstructions, temperature: temperature, topP: topP,
            cpuThreads: cpuThreads, preferFastResponse: preferFastResponse,
            repetitionPenalty: repetitionPenalty, repetitionWindow: repetitionWindow)
    }

    /// Updates affect the next turn; an active turn retains its exact snapshot.
    func configure(maxNewTokens: Int, contextLength: Int32, ownerInstructions: String,
                   temperature: Float, topP: Float, cpuThreads: Int,
                   preferFastResponse: Bool = false,
                   repetitionPenalty: Float = 1, repetitionWindow: Int = 64) {
        settings = Settings(maxNewTokens: maxNewTokens, contextLength: contextLength,
            ownerInstructions: ownerInstructions, temperature: temperature, topP: topP,
            cpuThreads: cpuThreads, preferFastResponse: preferFastResponse,
            repetitionPenalty: repetitionPenalty, repetitionWindow: repetitionWindow)
    }

    /// Call on backgrounding, memory warning or model changes. The active local
    /// strong reference survives until its native context has been safely freed.
    func unload() {
        activeAbort?.cancel()
        resident = nil
        metrics = nil
    }

    private func model(for url: URL, abort: GGUFAbortFlag) throws -> (ResidentGGUFModel, Bool) {
        let identity = try GGUFFileIdentity(url: url)
        if let resident, resident.identity == identity { return (resident, true) }
        resident = nil
        try GGUFFileValidator.validate(at: url)
        var parameters = llama_model_default_params()
        #if (os(iOS) && !targetEnvironment(simulator)) || os(macOS)
        let gpu = llama_supports_gpu_offload()
        #else
        let gpu = false
        #endif
        parameters.n_gpu_layers = gpu ? Int32.max : 0
        parameters.progress_callback = { _, pointer in
            guard let pointer else { return true }
            return !Unmanaged<GGUFAbortFlag>.fromOpaque(pointer).takeUnretainedValue().isCancelled
        }
        parameters.progress_callback_user_data = Unmanaged.passUnretained(abort).toOpaque()
        // llama.cpp's loading callback is synchronous; abort remains alive for
        // this whole call and bridges Task.cancel even before the actor yields.
        guard let pointer = llama_model_load_from_file(url.path, parameters) else {
            if abort.isCancelled { throw CancellationError() }
            throw LocalModelError.invalidFile
        }
        guard (try? GGUFFileIdentity(url: url)) == identity else {
            llama_model_free(pointer)
            throw LocalModelError.invalidFile
        }
        let loaded = ResidentGGUFModel(pointer: pointer, identity: identity, gpuOffloadRequested: gpu)
        resident = loaded; modelLoadCount += 1
        return (loaded, false)
    }

    private func checkGeneration(_ generation: UUID, abort: GGUFAbortFlag) throws {
        try Task.checkCancellation()
        guard activeGeneration == generation, !abort.isCancelled else { throw CancellationError() }
    }

    func generate(prompt: String, modelURL: URL) async throws -> String {
        try await generateDetailed(prompt: prompt, modelURL: modelURL).text
    }

    func generate(prompt: String, modelURL: URL,
                  onToken: @escaping @Sendable (String) async throws -> Void) async throws -> String {
        try await generateDetailed(prompt: prompt, modelURL: modelURL, onToken: onToken).text
    }

    func generateDetailed(prompt: String, modelURL: URL,
        onToken: (@Sendable (String) async throws -> Void)? = nil) async throws -> GGUFGeneration {
        let abort = GGUFAbortFlag()
        return try await withTaskCancellationHandler {
            try await performGeneration(prompt: prompt, modelURL: modelURL, onToken: onToken, abort: abort)
        } onCancel: { abort.cancel() }
    }

    private func performGeneration(prompt: String, modelURL: URL,
        onToken: (@Sendable (String) async throws -> Void)?, abort: GGUFAbortFlag) async throws -> GGUFGeneration {
        try Task.checkCancellation()
        guard activeGeneration == nil else { throw LocalModelError.generationInProgress }
        let generation = UUID()
        activeGeneration = generation; activeAbort = abort
        defer { activeGeneration = nil; activeAbort = nil }
        let settings = self.settings
        let maxNewTokens = settings.maxNewTokens, contextLength = settings.contextLength
        let ownerInstructions = settings.ownerInstructions, temperature = settings.temperature
        let topP = settings.topP, cpuThreads = settings.cpuThreads
        let repetitionPenalty = settings.repetitionPenalty, repetitionWindow = settings.repetitionWindow
        guard maxNewTokens > 0, maxNewTokens < Int(Int32.max), contextLength > 0,
              temperature.isFinite, temperature >= 0, topP.isFinite, topP > 0, topP <= 1,
              cpuThreads >= 0, cpuThreads <= Int(Int32.max),
              repetitionPenalty.isFinite, repetitionPenalty > 0,
              repetitionWindow >= 0, repetitionWindow <= Int(Int32.max),
              !ownerInstructions.utf8.contains(0), !prompt.utf8.contains(0) else {
            throw LocalModelError.invalidSettings
        }
        guard modelURL.isFileURL, !prompt.isEmpty else { throw LocalModelError.invalidSource }
        metrics = nil
        _ = GGUFBackend.ready
        let started = ProcessInfo.processInfo.systemUptime
        let thermalAtStart = RuntimeProcessSample.thermalState()
        let (heldModel, wasWarm) = try model(for: modelURL, abort: abort)
        let modelLoadSeconds = ProcessInfo.processInfo.systemUptime - started
        try checkGeneration(generation, abort: abort)
        let model = heldModel.pointer
        // Register before the context defer: model lifetime extends past context
        // destruction even if unload() removes the actor's resident reference.
        defer { withExtendedLifetime(heldModel) {} }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(contextLength)
        contextParameters.n_batch = 512
        contextParameters.n_ubatch = 512
        // 0 means automatic: use all processor cores the OS exposes.
        let selectedThreads = cpuThreads > 0 ? cpuThreads : ProcessInfo.processInfo.activeProcessorCount
        let threads = max(1, min(Int(Int32.max), selectedThreads))
        contextParameters.n_threads = Int32(threads)
        contextParameters.n_threads_batch = Int32(threads)

        let contextStarted = ProcessInfo.processInfo.systemUptime
        guard let context = llama_init_from_model(model, contextParameters) else {
            throw LocalModelError.runtimeUnavailable
        }
        defer { llama_free(context) }
        let contextInitSeconds = ProcessInfo.processInfo.systemUptime - contextStarted
        llama_set_abort_callback(context, { pointer in
            guard let pointer else { return false }
            return Unmanaged<GGUFAbortFlag>.fromOpaque(pointer).takeUnretainedValue().isCancelled
        }, Unmanaged.passUnretained(abort).toOpaque())

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
        var userPrompt = prompt
        var qwenFastMode = false
        if settings.preferFastResponse,
           !ownerInstructions.contains("/think"), !ownerInstructions.contains("/no_think"),
           !prompt.contains("/think"), !prompt.contains("/no_think") {
            var architecture = [CChar](repeating: 0, count: 64)
            let count = llama_model_meta_val_str(model, "general.architecture", &architecture, architecture.count)
            if count > 0, count < architecture.count {
                let value = String(decoding: architecture.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if value == "qwen3" || value == "qwen3moe" {
                    userPrompt += "\n/no_think"
                    qwenFastMode = true
                }
            }
        }
        messages.append(llama_chat_message(role: try cString("user"), content: try cString(userPrompt)))
        let required = messages.withUnsafeBufferPointer {
            llama_chat_apply_template(template, $0.baseAddress, $0.count, true, nil, 0)
        }
        guard required > 0, required < Int32.max - 1 else { throw LocalModelError.unsupportedTemplate }
        var rendered = [CChar](repeating: 0, count: Int(required) + 1)
        let renderedCount = messages.withUnsafeBufferPointer {
            llama_chat_apply_template(template, $0.baseAddress, $0.count, true, &rendered, Int32(rendered.count))
        }
        guard renderedCount == required else { throw LocalModelError.unsupportedTemplate }
        var renderedPrompt = String(decoding: rendered.prefix(Int(renderedCount)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // The model's own Qwen3 template defines this assistant prefix when
        // enable_thinking=false. Prefill that exact non-thinking prefix only
        // for explicit quick mode; owner system content stays byte-for-byte.
        if qwenFastMode, String(cString: template).contains("enable_thinking"),
           renderedPrompt.hasSuffix("<|im_start|>assistant\n") {
            renderedPrompt += "<think>\n\n</think>\n\n"
        }
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

        let prefillStarted = ProcessInfo.processInfo.systemUptime
        // Chunk the prompt rather than overflowing the 512-token physical batch.
        for offset in stride(from: 0, to: tokens.count, by: 512) {
            try checkGeneration(generation, abort: abort)
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
            let decoded = llama_decode(context, batch)
            try checkGeneration(generation, abort: abort)
            guard decoded == 0 else { throw LocalModelError.runtimeUnavailable }
        }

        let prefillSeconds = ProcessInfo.processInfo.systemUptime - prefillStarted
        // The owner can select deterministic output (temperature 0) or sampling.
        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw LocalModelError.runtimeUnavailable
        }
        defer { llama_sampler_free(sampler) }
        // A turn cannot contain more tokens than its context. Keep output-only
        // repetition state in this fresh sampler; do not penalize owner prompts.
        // b10549 llama_sampler_sample() already accepts the sampled token once.
        let appliedRepetitionWindow = min(repetitionWindow, effectiveContext)
        if repetitionPenalty != 1 && appliedRepetitionWindow > 0 {
            guard let penalties = llama_sampler_init_penalties(llama_vocab_n_tokens(vocabulary),
                Int32(appliedRepetitionWindow), repetitionPenalty, 0, 0) else {
                throw LocalModelError.runtimeUnavailable
            }
            llama_sampler_chain_add(sampler, penalties)
        }
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
        var firstTokenAt: Double?
        var decoder = UTF8TokenDecoder()
        for step in 0..<generationBudget {
            try checkGeneration(generation, abort: abort)
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocabulary, token) { break }
            if firstTokenAt == nil { firstTokenAt = ProcessInfo.processInfo.systemUptime }

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
            let tokenBytes = piece.prefix(Int(written)).map { UInt8(bitPattern: $0) }
            bytes.append(contentsOf: tokenBytes)
            generatedTokens += 1
            let delta = decoder.append(tokenBytes)
            if !delta.isEmpty, let onToken {
                try await onToken(delta)
                try checkGeneration(generation, abort: abort)
            }
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
            let decoded = llama_decode(context, batch)
            try checkGeneration(generation, abort: abort)
            guard decoded == 0 else { throw LocalModelError.runtimeUnavailable }
            position += 1
        }

        try checkGeneration(generation, abort: abort)
        let finalDelta = decoder.finish()
        if !finalDelta.isEmpty, let onToken {
            try await onToken(finalDelta)
            try checkGeneration(generation, abort: abort)
        }
        let answer = String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw LocalModelError.emptyOutput }
        let ended = ProcessInfo.processInfo.systemUptime
        let measured = LocalRuntimeMetrics(
            warmModel: wasWarm, modelLoadSeconds: modelLoadSeconds,
            contextInitSeconds: contextInitSeconds, prefillSeconds: prefillSeconds,
            firstTokenSeconds: (firstTokenAt ?? ended) - started,
            totalSeconds: ended - started, outputTokens: generatedTokens,
            tokensPerSecond: generatedTokens > 1 && ended > (firstTokenAt ?? ended)
                ? Double(generatedTokens - 1) / (ended - (firstTokenAt ?? ended)) : 0,
            residentMemoryBytes: RuntimeProcessSample.residentBytes(),
            peakResidentMemoryBytes: RuntimeProcessSample.peakResidentBytes(),
            thermalState: RuntimeProcessSample.thermalState(), thermalStateAtStart: thermalAtStart,
            modelBytes: heldModel.identity.bytes, modelLoadCount: modelLoadCount)
        metrics = measured
        return GGUFGeneration(text: answer, renderedPrompt: renderedPrompt,
            promptTokens: Int(nTokens), generatedTokens: generatedTokens,
            requestedMaxTokens: maxNewTokens, effectiveContext: effectiveContext,
            threads: threads, temperature: temperature, topP: topP,
            repetitionPenalty: repetitionPenalty, requestedRepetitionWindow: repetitionWindow,
            repetitionWindow: appliedRepetitionWindow, gpuOffloadRequested: heldModel.gpuOffloadRequested,
            metrics: measured)
    }
}
