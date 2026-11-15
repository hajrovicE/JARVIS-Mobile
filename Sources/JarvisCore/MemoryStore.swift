import Foundation

public struct MemoryItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date
    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id; self.text = text; self.createdAt = createdAt
    }
}
public struct AnswerCache: Codable, Equatable, Sendable {
    public var question: String
    public var answer: String
    public var createdAt: Date
    public init(question: String, answer: String, createdAt: Date = Date()) {
        self.question = question; self.answer = answer; self.createdAt = createdAt
    }
}
public struct MemorySnapshot: Codable, Equatable, Sendable {
    public var version = 1
    public var conversations: [MemoryItem] = []
    public var answers: [AnswerCache] = []
    public var personal: [MemoryItem] = []
    public init() {}
}
public protocol SnapshotStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
}
public enum MemoryError: Error { case unsupportedVersion, missingMemory, emptyText }

/// All mutations persist first: failed writes never report success or alter the live snapshot.
public actor MemoryStore {
    private let storage: any SnapshotStorage
    private var snapshot: MemorySnapshot
    public init(storage: any SnapshotStorage, now: Date = Date()) throws {
        self.storage = storage
        var loaded = try storage.load().map { try JSONDecoder().decode(MemorySnapshot.self, from: $0) } ?? MemorySnapshot()
        // v0 used the same payload, without retention enforcement. Upgrade before exposing data.
        guard (0...1).contains(loaded.version) else { throw MemoryError.unsupportedVersion }
        loaded.version = 1
        Self.purge(&loaded, now: now)
        try storage.save(JSONEncoder().encode(loaded))
        self.snapshot = loaded
    }
    private static func purge(_ state: inout MemorySnapshot, now: Date) {
        state.conversations.removeAll { now.timeIntervalSince($0.createdAt) >= 90 * 86400 }
        state.answers.removeAll { now.timeIntervalSince($0.createdAt) >= 30 * 86400 }
    }
    private func commit(_ state: MemorySnapshot) throws {
        try storage.save(JSONEncoder().encode(state)); snapshot = state
    }
    public func read(now: Date = Date()) throws -> MemorySnapshot {
        var next = snapshot; Self.purge(&next, now: now)
        if next != snapshot { try commit(next) }; return next
    }
    public func remember(_ text: String, now: Date = Date()) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MemoryError.emptyText }
        var next = try read(now: now); next.personal.append(.init(text: text, createdAt: now)); try commit(next)
    }
    public func edit(id: UUID, text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MemoryError.emptyText }
        var next = snapshot
        guard let index = next.personal.firstIndex(where: { $0.id == id }) else { throw MemoryError.missingMemory }
        next.personal[index].text = text; try commit(next)
    }
    public func forget(id: UUID) throws {
        var next = snapshot
        guard next.personal.contains(where: { $0.id == id }) else { throw MemoryError.missingMemory }
        next.personal.removeAll { $0.id == id }; try commit(next)
    }
    public func record(_ text: String, now: Date = Date()) throws {
        var next = try read(now: now); next.conversations.append(.init(text: text, createdAt: now)); try commit(next)
    }
    public func cache(question: String, answer: String, timeSensitive: Bool, now: Date = Date()) throws {
        var next = try read(now: now); next.answers.removeAll { $0.question == question }
        if !timeSensitive { next.answers.append(.init(question: question, answer: answer, createdAt: now)) }
        try commit(next)
    }
    public func cachedAnswer(question: String, timeSensitive: Bool, now: Date = Date()) throws -> String? {
        let state = try read(now: now)
        return timeSensitive ? nil : state.answers.first { $0.question == question }?.answer
    }
    /// Explicit plaintext export, only for a user-initiated share action.
    public func export(now: Date = Date()) throws -> Data { try JSONEncoder().encode(read(now: now)) }
    public func deleteAll() throws { try commit(MemorySnapshot()) }
}
