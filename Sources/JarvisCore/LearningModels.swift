import Foundation

public enum LearningKind: String, Codable, Sendable { case preference, rule, knowledge, suggestion }
public enum LearningSource: String, Codable, Sendable { case userInput, userCorrection, taskResult, externalSource }
public enum MemorySensitivity: String, Codable, Sendable { case ordinary, sensitive, secret }

/// Metadata for auditing a claim. This is evidence metadata, never an execution permission.
public struct LearningProvenance: Codable, Equatable, Sendable {
    public var sourceID: String
    public var sourceURL: URL?
    public var capturedAt: Date
    public var explanation: String
    public init(sourceID: String, sourceURL: URL? = nil, capturedAt: Date = Date(), explanation: String = "") {
        self.sourceID = sourceID; self.sourceURL = sourceURL
        self.capturedAt = capturedAt; self.explanation = explanation
    }
}

public struct LearnedMemory: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var kind: LearningKind
    /// A stable topic, such as `drink.preference`; conflicts are compared within this key.
    public var key: String
    public var text: String
    public var source: LearningSource
    public var createdAt: Date
    public var updatedAt: Date
    public var expiresAt: Date?
    public var confidence: Double
    public var userConfirmed: Bool
    public var sensitivity: MemorySensitivity
    public var provenance: LearningProvenance
    public var revision: Int
    public var supersededBy: UUID?
    public init(id: UUID = UUID(), kind: LearningKind, key: String, text: String,
                source: LearningSource, createdAt: Date = Date(), expiresAt: Date? = nil,
                confidence: Double, sensitivity: MemorySensitivity = .ordinary,
                provenance: LearningProvenance) {
        self.id = id; self.kind = kind; self.key = key; self.text = text; self.source = source
        self.createdAt = createdAt; self.updatedAt = createdAt; self.expiresAt = expiresAt
        self.confidence = confidence; self.userConfirmed = false; self.sensitivity = sensitivity
        self.provenance = provenance; self.revision = 1; self.supersededBy = nil
    }
}

public enum TaskRisk: String, Codable, Sendable { case low, sensitive, high }
public enum TaskOutcome: String, Codable, Sendable { case proposed, succeeded, failed, cancelled }
public struct TaskExperience: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var action: String
    public var permissionScope: [String]
    public var risk: TaskRisk
    public var outcome: TaskOutcome
    public var result: String?
    public var error: String?
    public var rollback: String?
    public var backupReference: String?
    public var executionReceipt: String?
    public var createdAt: Date
    /// An audit record cannot itself authorize or repeat an action.
    public init(id: UUID = UUID(), action: String, permissionScope: [String] = [],
                risk: TaskRisk, outcome: TaskOutcome = .proposed, result: String? = nil,
                error: String? = nil, rollback: String? = nil, backupReference: String? = nil,
                executionReceipt: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.action = action; self.permissionScope = permissionScope
        self.risk = risk; self.outcome = outcome; self.result = result; self.error = error
        self.rollback = rollback; self.backupReference = backupReference
        self.executionReceipt = executionReceipt; self.createdAt = createdAt
    }
}
public struct LearningState: Codable, Equatable, Sendable {
    public var records: [LearnedMemory] = []
    public var experiences: [TaskExperience] = []
    public init() {}
    /// Persist the resulting state on read; expired source-backed claims cannot be reused.
    public mutating func purgeExpired(now: Date) {
        records.removeAll { $0.expiresAt.map { $0 <= now } ?? false }
    }
}
