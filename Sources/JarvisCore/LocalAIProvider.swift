import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
/// Owner-owned local model metadata. No hash pinning or model provenance restrictions.
public struct LocalModelManifest: Codable, Equatable, Sendable {
    public let identifier: String
    public let revision: String
    public let licenseIdentifier: String
    public let byteCount: Int64
    public let sha256: String

    public init(identifier: String, revision: String, licenseIdentifier: String,
                byteCount: Int64, sha256: String) throws {
        let allowed: (UInt8) -> Bool = { byte in
            (65...90).contains(byte) || (97...122).contains(byte) ||
            (48...57).contains(byte) || byte == 45 || byte == 46 || byte == 95
        }
        // Only filesystem-safe identity and digest structure are enforced;
        // owner-defined descriptive metadata has no arbitrary character limits.
        guard !identifier.isEmpty, identifier.utf8.allSatisfy(allowed),
              identifier != ".", identifier != "..",
              !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !licenseIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              byteCount >= 0 else {
            throw LocalModelError.invalidManifest
        }
        self.identifier = identifier
        self.revision = revision
        self.licenseIdentifier = licenseIdentifier
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
        case identifier, revision, licenseIdentifier, byteCount, sha256
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(identifier: container.decode(String.self, forKey: .identifier),
                      revision: container.decode(String.self, forKey: .revision),
                      licenseIdentifier: container.decode(String.self, forKey: .licenseIdentifier),
                      byteCount: container.decode(Int64.self, forKey: .byteCount),
                      sha256: container.decode(String.self, forKey: .sha256))
    }
}

public enum LocalModelError: Error, Equatable, Sendable {
    case invalidManifest, invalidSource, notInstalled, invalidFile
    case runtimeUnavailable, emptyOutput, invalidSettings, contextExceeded, unsupportedTemplate, generationInProgress
}

/// Imports a user-provided model file into an app-private directory.
/// Does not download models, use a network connection, or execute a model.
public actor OnDeviceModelManager {
    private let directory: URL
    private var validated: [URL: FileIdentity] = [:]

    /// Nanosecond modification/change times and inode identity detect replacements
    /// even when a copied file preserves its original modification date and size.
    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let bytes: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
    }

    private func identity(of url: URL) throws -> FileIdentity {
        var attributes = stat()
        let result = url.path.withCString { lstat($0, &attributes) }
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard UInt32(attributes.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG) else {
            throw LocalModelError.invalidFile
        }
        #if canImport(Darwin)
        let modified = attributes.st_mtimespec
        let changed = attributes.st_ctimespec
        #else
        let modified = attributes.st_mtim
        let changed = attributes.st_ctim
        #endif
        return FileIdentity(device: UInt64(attributes.st_dev), inode: UInt64(attributes.st_ino),
            bytes: Int64(attributes.st_size), modifiedSeconds: Int64(modified.tv_sec),
            modifiedNanoseconds: Int64(modified.tv_nsec), changedSeconds: Int64(changed.tv_sec),
            changedNanoseconds: Int64(changed.tv_nsec))
    }

    public init(directory: URL) throws {
        guard directory.isFileURL else { throw LocalModelError.invalidSource }
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func destination(for manifest: LocalModelManifest) -> URL {
        directory.appendingPathComponent(manifest.identifier + ".gguf", isDirectory: false)
    }

    private func verify(_ file: URL, using manifest: LocalModelManifest) throws {
        let before = try identity(of: file)
        if validated[file] == before { return }
        validated.removeValue(forKey: file)
        try GGUFFileValidator.validate(at: file)
        guard try identity(of: file) == before else { throw LocalModelError.invalidFile }
        validated[file] = before
    }

    public func installedModelURL(for manifest: LocalModelManifest) throws -> URL {
        let file = destination(for: manifest)
        guard FileManager.default.fileExists(atPath: file.path) else { throw LocalModelError.notInstalled }
        try verify(file, using: manifest)
        return file
    }

    @discardableResult
    public func importModel(from source: URL, manifest: LocalModelManifest) throws -> URL {
        validated.removeAll()
        defer { validated.removeAll() }
        guard source.isFileURL else {
            throw LocalModelError.invalidSource
        }
        let destination = destination(for: manifest)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial", isDirectory: false)
        do {
            try Task.checkCancellation()
            try verify(source, using: manifest)
            try FileManager.default.copyItem(at: source, to: temporary)
            try verify(temporary, using: manifest)
            try Task.checkCancellation()
            // Same-directory rename is atomic and replaces an older owner-selected model.
            // Verification/copy failures never remove the previously installed file.
            let status = temporary.path.withCString { input in
                destination.path.withCString { output in rename(input, output) }
            }
            guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func removeModel(_ manifest: LocalModelManifest) throws {
        validated.removeAll()
        let file = destination(for: manifest)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

/// This abstraction is intentionally separate from networking and from action execution.
/// Production implementation must run an actual on-device inference engine.
public protocol OnDeviceInferenceRuntime: Sendable {
    func generate(prompt: String, modelURL: URL) async throws -> String
    func generate(prompt: String, modelURL: URL, onToken: @escaping AITokenHandler) async throws -> String
}

public extension OnDeviceInferenceRuntime {
    /// A non-streaming implementation emits its completed text once. Production
    /// llama.cpp overrides this to deliver real, sequential UTF-8 token deltas.
    func generate(prompt: String, modelURL: URL, onToken: @escaping AITokenHandler) async throws -> String {
        let text = try await generate(prompt: prompt, modelURL: modelURL)
        try Task.checkCancellation()
        try await onToken(text)
        try Task.checkCancellation()
        return text
    }
}

/// Removes only an explicit initial reasoning section, including split tags.
/// Visible answer text (including literal tags later in an answer) is preserved.
public struct VisibleResponseFilter: Sendable {
    private enum Phase: Sendable { case prefix, reasoning, visible }
    private var phase = Phase.prefix
    private var pending = ""
    private var visibleStarted = false
    public init() {}

    public mutating func append(_ delta: String) -> String {
        pending += delta
        while true {
            switch phase {
            case .prefix:
                pending = String(pending.drop(while: { $0.isWhitespace }))
                if pending.hasPrefix("<think>") {
                    pending.removeFirst("<think>".count)
                    phase = .reasoning
                } else if "<think>".hasPrefix(pending) { return "" }
                else { phase = .visible }
            case .reasoning:
                if let closing = pending.range(of: "</think>") {
                    pending = String(pending[closing.upperBound...])
                    phase = .visible
                } else {
                    pending = String(pending.suffix("</think>".count - 1))
                    return ""
                }
            case .visible:
                if !visibleStarted { pending = String(pending.drop(while: { $0.isWhitespace })) }
                let output = pending
                pending = ""
                if !output.isEmpty { visibleStarted = true }
                return output
            }
        }
    }

    public mutating func finish() -> String {
        defer { pending = "" }
        if case .prefix = phase { return pending }
        return ""
    }

    public static func answer(from text: String) -> String {
        var filter = Self()
        let output = filter.append(text) + filter.finish()
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TokenCallbackFailure: Error {
    let underlying: any Error
}

/// Serializes filter state without making UI/AVFoundation part of the runtime.
private actor VisibleTokenRelay {
    private var filter = VisibleResponseFilter()
    private let handler: AITokenHandler
    init(handler: @escaping AITokenHandler) { self.handler = handler }
    func append(_ delta: String) async throws {
        let output = filter.append(delta)
        if !output.isEmpty { try await handler(output) }
    }
    func finish() async throws {
        let output = filter.finish()
        if !output.isEmpty { try await handler(output) }
    }
}

/// Fail closed until a real llama.cpp/Metal (or equivalent) runtime is integrated.
public struct UnavailableOnDeviceRuntime: OnDeviceInferenceRuntime {
    public init() {}
    public func generate(prompt: String, modelURL: URL) async throws -> String {
        throw LocalModelError.runtimeUnavailable
    }
}

public struct LocalAIProvider: AIProvider {
    private let manager: OnDeviceModelManager
    private let manifest: LocalModelManifest
    private let runtime: any OnDeviceInferenceRuntime

    public init(manager: OnDeviceModelManager, manifest: LocalModelManifest,
                runtime: any OnDeviceInferenceRuntime = UnavailableOnDeviceRuntime()) {
        self.manager = manager
        self.manifest = manifest
        self.runtime = runtime
    }

    public func respond(to request: AIRequest) async throws -> AIResponse {
        try await perform(request, onToken: nil)
    }

    public func respond(to request: AIRequest, onToken: @escaping AITokenHandler) async throws -> AIResponse {
        try await perform(request, onToken: onToken)
    }

    private func perform(_ request: AIRequest, onToken: AITokenHandler?) async throws -> AIResponse {
        guard !Task.isCancelled else { throw AIProviderError.cancelled }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.context.allSatisfy({ !$0.id.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw AIProviderError.invalidRequest
        }
        let file: URL
        do { file = try await manager.installedModelURL(for: manifest) }
        catch LocalModelError.notInstalled { throw AIProviderError.notConfigured }
        catch { throw AIProviderError.invalidConfiguration }

        // Context remains untrusted user data; the model never receives tool authority.
        let context = request.context.enumerated().map { index, entry in
            "Bilgi \(index + 1) [\(entry.id)]: \(entry.text)"
        }.joined(separator: "\n")
        // The owner sets all behavioral instructions in the native runtime.
        // This layer transports the literal request and local memory data only.
        let prompt = context.isEmpty ? request.prompt :
            "Hafıza bağlamı (kaydedilmiş veri):\n" + context +
            "\n\nKullanıcının doğrudan isteği:\n" + request.prompt
        let raw: String
        do {
            if let onToken {
                let relay = VisibleTokenRelay(handler: onToken)
                raw = try await runtime.generate(prompt: prompt, modelURL: file) { delta in
                    do { try await relay.append(delta) }
                    catch { throw TokenCallbackFailure(underlying: error) }
                }
                do { try await relay.finish() }
                catch { throw TokenCallbackFailure(underlying: error) }
            } else {
                raw = try await runtime.generate(prompt: prompt, modelURL: file)
            }
        }
        catch let callback as TokenCallbackFailure { throw callback.underlying }
        catch LocalModelError.runtimeUnavailable { throw AIProviderError.notConfigured }
        catch let error as LocalModelError { throw error }
        catch is CancellationError { throw AIProviderError.cancelled }
        catch { throw AIProviderError.unavailable }
        guard !Task.isCancelled else { throw AIProviderError.cancelled }
        let text = VisibleResponseFilter.answer(from: raw)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.emptyResponse
        }
        return AIResponse(text: text, provider: "local-device", model: manifest.identifier,
                          generatedAt: Date(), sources: [], freshness: .unverified)
    }
}
