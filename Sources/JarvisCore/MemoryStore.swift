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
    /// Reuse metadata, not a deletion/retention policy. Optional for older snapshots.
    public var invalidated: Bool?
    public init(question: String, answer: String, createdAt: Date = Date(), invalidated: Bool = false) {
        self.question = question; self.answer = answer; self.createdAt = createdAt
        self.invalidated = invalidated
    }
}
public struct MemorySnapshot: Codable, Equatable, Sendable {
    public var version = 3
    public var conversations: [MemoryItem] = []
    public var answers: [AnswerCache] = []
    public var personal: [MemoryItem] = []
    public var learning = LearningState()
    public var generatedAnswers: [StoredAIAnswer] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, conversations, answers, personal, learning, generatedAnswers }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        conversations = try values.decode([MemoryItem].self, forKey: .conversations)
        answers = try values.decode([AnswerCache].self, forKey: .answers)
        personal = try values.decode([MemoryItem].self, forKey: .personal)
        // v0/v1 did not contain learning state. Do not hide malformed v2 payloads.
        learning = version < 2 ? LearningState() : try values.decode(LearningState.self, forKey: .learning)
        generatedAnswers = version < 3 ? [] : try values.decode([StoredAIAnswer].self, forKey: .generatedAnswers)
    }
    /// Validate the version before decoding version-specific fields. Unsupported future
    /// schemas must remain untouched, not become an empty current snapshot.
    static func decodeSupported(from data: Data) throws -> MemorySnapshot {
        struct Header: Decodable { let version: Int }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard (0...3).contains(header.version) else { throw MemoryError.unsupportedVersion }
        return try JSONDecoder().decode(MemorySnapshot.self, from: data)
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
    private var contextEpoch = UUID()
    private let learningEngine: any LearningEngine
    public init(storage: any SnapshotStorage, now: Date = Date(), learningEngine: any LearningEngine = LocalLearningEngine()) throws {
        self.storage = storage
        self.learningEngine = learningEngine
        let persisted = try storage.load()
        var loaded = try persisted.map { try MemorySnapshot.decodeSupported(from: $0) } ?? MemorySnapshot()
        let requiresUpgrade = loaded.version != 3
        loaded.version = 3
        Self.purge(&loaded, now: now)
        // Opening valid owner history must not require a gratuitous write. This also
        // keeps readable data available for viewing/export when the disk becomes full.
        if persisted == nil || requiresUpgrade {
            try storage.save(JSONEncoder().encode(loaded))
        }
        self.snapshot = loaded
    }
    /// Owner history is durable. Freshness for reuse is checked by AssistantService,
    /// but stored records are removed only through an explicit owner erase.
    private static func purge(_ state: inout MemorySnapshot, now: Date) {
        // Intentionally no automatic deletion.
    }
    private func commit(_ state: MemorySnapshot, changesContext: Bool = true) throws {
        var next = state
        // A context change invalidates reuse and in-flight responses, never history.
        if changesContext {
            for index in next.answers.indices { next.answers[index].invalidated = true }
            next.generatedAnswers = next.generatedAnswers.map {
                StoredAIAnswer(id: $0.id, question: $0.question, response: $0.response,
                    savedAt: $0.savedAt, cacheUntil: nil, cacheScope: $0.cacheScope, contextIDs: $0.contextIDs)
            }
        }
        try storage.save(JSONEncoder().encode(next)); snapshot = next
        if changesContext { contextEpoch = UUID() }
    }
    public func read(now: Date = Date()) throws -> MemorySnapshot {
        var next = snapshot; Self.purge(&next, now: now)
        if next != snapshot { try commit(next, changesContext: next.learning != snapshot.learning || next.conversations != snapshot.conversations) }; return snapshot
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
        // A cache bookkeeping write is not new owner context.
        try commit(next, changesContext: false)
    }
    public func cachedAnswer(question: String, timeSensitive: Bool, now: Date = Date()) throws -> String? {
        let state = try read(now: now)
        guard !timeSensitive else { return nil }
        return state.answers.last {
            $0.question == question && $0.invalidated != true &&
            now.timeIntervalSince($0.createdAt) >= 0 && now.timeIntervalSince($0.createdAt) < 30 * 86400
        }?.answer
    }
    /// Explicit plaintext export, only for a user-initiated share action.
    public func export(now: Date = Date()) throws -> Data { try JSONEncoder().encode(read(now: now)) }
    public func proposeLearning(_ record: LearnedMemory, now: Date = Date()) throws {
        var next = try read(now: now)
        next.learning = try learningEngine.propose(record, in: next.learning, now: now)
        try commit(next)
    }
    public func confirmLearning(id: UUID, expectedText: String, now: Date = Date()) throws {
        var next = try read(now: now)
        guard let record = next.learning.records.first(where: { $0.id == id }) else { throw LearningError.missingRecord }
        guard record.text == expectedText else { throw LearningError.staleProposal }
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
    public func invalidatePendingAI() { contextEpoch = UUID() }
    public func aiContextSnapshot(now: Date = Date()) throws -> (MemorySnapshot, UUID) {
        let state = try read(now: now); return (state, contextEpoch)
    }
    public func validateAIContext(expectedEpoch: UUID) throws {
        try Task.checkCancellation()
        guard contextEpoch == expectedEpoch else { throw AssistantError.contextChanged }
    }
    public func recordGeneratedAnswer(_ answer: StoredAIAnswer, expectedEpoch: UUID) throws {
        try Task.checkCancellation()
        guard contextEpoch == expectedEpoch else { throw AssistantError.contextChanged }
        var next = snapshot; next.generatedAnswers.append(answer)
        try commit(next, changesContext: false)
    }
    public func proposeTaskCorrection(experienceID: UUID, key: String, text: String, now: Date = Date()) throws {
        var next = try read(now: now)
        next.learning = try learningEngine.proposeTaskCorrection(experienceID: experienceID, key: key, text: text, in: next.learning, now: now)
        try commit(next)
    }
    public func deleteAll() throws { try commit(MemorySnapshot()) }
}
