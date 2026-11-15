import Foundation

/// Local JSON snapshot storage selected by the owner. This is not encrypted
/// by the application and does not depend on a Keychain account.
public final class PlainFileStorage: SnapshotStorage, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) throws {
        self.url = url
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func save(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try data.write(to: url, options: .atomic)
    }
}
