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
    public var version = 2
    public var conversations: [MemoryItem] = []
    public var answers: [AnswerCache] = []
    public var personal: [MemoryItem] = []
    public var learning = LearningState()
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, conversations, answers, personal, learning }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        conversations = try values.decode([MemoryItem].self, forKey: .conversations)
        answers = try values.decode([AnswerCache].self, forKey: .answers)
        personal = try values.decode([MemoryItem].self, forKey: .personal)
        // v0/v1 did not contain learning state. Do not hide malformed v2 payloads.
        learning = version < 2 ? LearningState() : try values.decode(LearningState.self, forKey: .learning)
    }
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
    private let learningEngine: any LearningEngine
    public init(storage: any SnapshotStorage, now: Date = Date(), learningEngine: any LearningEngine = LocalLearningEngine()) throws {
        self.storage = storage
        self.learningEngine = learningEngine
        var loaded = try storage.load().map { try JSONDecoder().decode(MemorySnapshot.self, from: $0) } ?? MemorySnapshot()
        // v0 used the same payload, without retention enforcement. Upgrade before exposing data.
        guard (0...2).contains(loaded.version) else { throw MemoryError.unsupportedVersion }
        loaded.version = 2
        Self.purge(&loaded, now: now)
        try storage.save(JSONEncoder().encode(loaded))
        self.snapshot = loaded
    }
    private static func purge(_ state: inout MemorySnapshot, now: Date) {
        state.learning.purgeExpired(now: now)
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
    public func proposeLearning(_ record: LearnedMemory, now: Date = Date()) throws {
        var next = try read(now: now)
        next.learning = try learningEngine.propose(record, in: next.learning, now: now)
        try commit(next)
    }
    public func confirmLearning(id: UUID, now: Date = Date()) throws {
        var next = try read(now: now)
        next.learning = try learningEngine.confirm(id: id, in: next.learning, now: now)
        try commit(next)
    }
    public func correctLearning(id: UUID, text: String, now: Date = Date()) throws {
        var next = try read(now: now)
        next.learning = try learningEngine.correct(id: id, text: text, in: next.learning, now: now)
        try commit(next)
    }
    public func deleteLearning(id: UUID, now: Date = Date()) throws {
        var next = try read(now: now)
        next.learning = try learningEngine.delete(id: id, in: next.learning)
        try commit(next)
    }
    public func learnedMemories(query: String, now: Date = Date()) throws -> [LearnedMemory] {
        let state = try read(now: now)
        return learningEngine.retrieve(query: query, in: state.learning, now: now)
    }
    public func recordExperience(_ experience: TaskExperience, now: Date = Date()) throws {
        var next = try read(now: now)
        next.learning = try learningEngine.recordExperience(experience, in: next.learning)
        try commit(next)
    }
    public func deleteAll() throws { try commit(MemorySnapshot()) }
}
