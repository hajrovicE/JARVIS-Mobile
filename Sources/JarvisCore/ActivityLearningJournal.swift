import Foundation

/// Events are fixed, non-content-bearing action names. Free-form text, app names,
/// addresses, keystrokes, screen contents and credentials never enter this journal.
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case typedCommand
    case voiceInputStarted
    case voiceInputFinished
    case modelImportStarted
    case modelImportCompleted
    case memoryEdited
    case learningProposed
    case learningConfirmed
    case actionSucceeded
}

public struct ActivityObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: ActivityKind
    public let recordedAt: Date

    public init(id: UUID = UUID(), kind: ActivityKind, recordedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.recordedAt = recordedAt
    }
}

public struct ActivityJournalSnapshot: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var enabled: Bool = false
    public var observations: [ActivityObservation] = []

    public init() {}
}

public enum ActivityJournalError: Error, Equatable, Sendable {
    case unsupportedVersion
}

/// Suggested habits are NOT confirmed preferences and never grant tool permissions.
public struct ActivityInsight: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let explanation: String
    public let evidenceCount: Int
}

public enum ActivityInsights {
    public static func infer(from observations: [ActivityObservation], now: Date = Date()) -> [ActivityInsight] {
        let recent = observations.filter { $0.recordedAt <= now }
        let voice = recent.filter { $0.kind == .voiceInputFinished }.count
        let typed = recent.filter { $0.kind == .typedCommand }.count
        if voice > typed {
            return [.init(id: "input.voice", title: "Sesli giriş daha sık kullanılıyor",
                          explanation: "Kayıtlı etkinliklerde sesli komutlar daha fazla görülüyor; bu bir davranış gözlemidir.",
                          evidenceCount: voice)]
        }
        if typed > voice {
            return [.init(id: "input.typed", title: "Yazılı giriş daha sık kullanılıyor",
                          explanation: "Kayıtlı etkinliklerde yazılı komutlar daha fazla görülüyor; bu bir davranış gözlemidir.",
                          evidenceCount: typed)]
        }
        return []
    }
}

/// Records only allowlisted events from inside JARVIS. No screen recording,
/// keyboard interception, other-app monitoring, network request or background watcher.
public actor ActivityLearningJournal {
    // User-enabled observations persist until explicitly erased; no automatic count or age cut-off.

    private let storage: any SnapshotStorage
    private var snapshot: ActivityJournalSnapshot

    public init(storage: any SnapshotStorage, now: Date = Date()) throws {
        self.storage = storage
        let persisted = try storage.load()
        var loaded = try persisted.map {
            try JSONDecoder().decode(ActivityJournalSnapshot.self, from: $0)
        } ?? ActivityJournalSnapshot()
        guard loaded.version == 1 else { throw ActivityJournalError.unsupportedVersion }
        Self.purge(&loaded, now: now)
        if persisted == nil { try storage.save(JSONEncoder().encode(loaded)) }
        snapshot = loaded
    }

    private static func purge(_ state: inout ActivityJournalSnapshot, now: Date) {
        // Clock corrections can make a real prior event appear to be in the future.
        // Preserve it; insights already exclude future-dated evidence until appropriate.
    }

    private func commit(_ updated: ActivityJournalSnapshot) throws {
        try storage.save(JSONEncoder().encode(updated))
        snapshot = updated
    }

    public func read(now: Date = Date()) throws -> ActivityJournalSnapshot {
        var updated = snapshot
        Self.purge(&updated, now: now)
        if updated != snapshot { try commit(updated) }
        return snapshot
    }

    public func setEnabled(_ enabled: Bool, now: Date = Date()) throws {
        var updated = try read(now: now)
        updated.enabled = enabled
        try commit(updated)
    }

    public func record(_ kind: ActivityKind, at now: Date = Date()) throws {
        var updated = try read(now: now)
        guard updated.enabled else { return }
        updated.observations.append(.init(kind: kind, recordedAt: now))
        Self.purge(&updated, now: now)
        try commit(updated)
    }

    /// A full activity-data erasure also stops collection. Existing user-confirmed
    /// memories are separately managed by MemoryStore and cannot be implicitly deleted.
    public func erase() throws {
        try commit(ActivityJournalSnapshot())
    }

    public func insights(now: Date = Date()) throws -> [ActivityInsight] {
        ActivityInsights.infer(from: try read(now: now).observations, now: now)
    }
}
