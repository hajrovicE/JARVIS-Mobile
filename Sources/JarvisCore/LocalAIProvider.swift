import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A local GGUF's identity must be pinned before the file can be used for inference.
/// Manifests are metadata, not a model download instruction.
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
              byteCount > 0, sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
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
    case mismatchedSize, mismatchedDigest, digestUnavailable
    case runtimeUnavailable, emptyOutput
}

public protocol LocalModelDigestChecking: Sendable {
    func sha256(of fileURL: URL) throws -> String
}

/// Uses incremental hashing so even gigabyte-sized model files are not loaded into RAM.
public struct PlatformSHA256Checker: LocalModelDigestChecking {
    public init() {}
    public func sha256(of fileURL: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        throw LocalModelError.digestUnavailable
        #endif
    }
}

/// Imports a user-provided model file into an app-private directory.
/// Does not download models, use a network connection, or execute a model.
public actor OnDeviceModelManager {
    private let directory: URL
    private let digester: any LocalModelDigestChecking

    public init(directory: URL, digester: any LocalModelDigestChecking = PlatformSHA256Checker()) throws {
        guard directory.isFileURL else { throw LocalModelError.invalidSource }
        self.directory = directory
        self.digester = digester
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func destination(for manifest: LocalModelManifest) -> URL {
        directory.appendingPathComponent(manifest.identifier + ".gguf", isDirectory: false)
    }

    private func verify(_ file: URL, using manifest: LocalModelManifest) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalModelError.invalidFile
        }
        // GGUF is identified by file content, not the filename or extension.
        let source = try FileHandle(forReadingFrom: file)
        defer { try? source.close() }
        guard try source.read(upToCount: 4) == Data([0x47, 0x47, 0x55, 0x46]) else {
            throw LocalModelError.invalidFile
        }
        guard Int64(values.fileSize ?? -1) == manifest.byteCount else {
            throw LocalModelError.mismatchedSize
        }
        guard try digester.sha256(of: file) == manifest.sha256 else {
            throw LocalModelError.mismatchedDigest
        }
    }

    public func installedModelURL(for manifest: LocalModelManifest) throws -> URL {
        let file = destination(for: manifest)
        guard FileManager.default.fileExists(atPath: file.path) else { throw LocalModelError.notInstalled }
        try verify(file, using: manifest)
        return file
    }

    @discardableResult
    public func importModel(from source: URL, manifest: LocalModelManifest) throws -> URL {
        guard source.isFileURL else {
            throw LocalModelError.invalidSource
        }
        let destination = destination(for: manifest)
        if FileManager.default.fileExists(atPath: destination.path) {
            return try installedModelURL(for: manifest)
        }
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".partial", isDirectory: false)
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            try verify(temporary, using: manifest)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public func removeModel(_ manifest: LocalModelManifest) throws {
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
        let text: String
        do { text = try await runtime.generate(prompt: prompt, modelURL: file) }
        catch LocalModelError.runtimeUnavailable { throw AIProviderError.notConfigured }
        catch is CancellationError { throw AIProviderError.cancelled }
        catch { throw AIProviderError.unavailable }
        guard !Task.isCancelled else { throw AIProviderError.cancelled }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.emptyResponse
        }
        return AIResponse(text: text, provider: "local-device", model: manifest.identifier,
                          generatedAt: Date(), sources: [], freshness: .unverified)
    }
}
