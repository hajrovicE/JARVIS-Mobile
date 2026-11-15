import Foundation

/// Local JSON snapshot storage selected by the owner. This is not encrypted
/// by the application and does not depend on a Keychain account.
public final class PlainFileStorage: SnapshotStorage, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private static let migrationLock = NSLock()

    public init(url: URL) throws {
        self.url = url
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Reads legacy encrypted bytes only when no JSON snapshot exists. The loader
    /// stays lazy so normal launches never touch Keychain or require an old key.
    /// A valid atomically-written JSON snapshot is the migration commit point.
    public static func migratingLegacySnapshot(
        to jsonURL: URL, legacyURL: URL, loadLegacy: () throws -> Data?
    ) throws -> PlainFileStorage {
        migrationLock.lock(); defer { migrationLock.unlock() }
        guard jsonURL.isFileURL, legacyURL.isFileURL,
              jsonURL.standardizedFileURL != legacyURL.standardizedFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let plain = try PlainFileStorage(url: jsonURL)
        if let current = try plain.load() {
            _ = try MemorySnapshot.decodeSupported(from: current)
            // A previous launch can have stopped after committing JSON but before
            // deleting the legacy copy. Retry cleanup without decrypting old data.
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                try FileManager.default.removeItem(at: legacyURL)
            }
            return plain
        }
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return plain }
        guard let legacy = try loadLegacy() else { throw MigrationError.emptyLegacy }
        var snapshot = try MemorySnapshot.decodeSupported(from: legacy)
        snapshot.version = 3
        try plain.save(JSONEncoder().encode(snapshot))
        // Only remove the source after a complete, validated JSON commit. Failing
        // writes leave legacy data untouched; failing cleanup is retried next launch.
        try FileManager.default.removeItem(at: legacyURL)
        return plain
    }

    public enum MigrationError: Error { case emptyLegacy }

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
