import Foundation

/// Pure state transitions: the caller persists the returned state before exposing success.
/// No model training, networking, external execution, or biometric authorization occurs here.
public protocol LearningEngine: Sendable {
    func propose(_ record: LearnedMemory, in state: LearningState, now: Date) throws -> LearningState
    func confirm(id: UUID, in state: LearningState, now: Date) throws -> LearningState
    func correct(id: UUID, text: String, in state: LearningState, now: Date) throws -> LearningState
    func delete(id: UUID, in state: LearningState) throws -> LearningState
    func retrieve(query: String, in state: LearningState, now: Date) -> [LearnedMemory]
    func recordExperience(_ experience: TaskExperience, in state: LearningState) throws -> LearningState
}
public enum LearningError: Error, Equatable {
    case invalidRecord, secretNotAllowed, missingRecord, expired, conflictingRecord, missingReceipt
}

public struct LocalLearningEngine: LearningEngine {
    public init() {}
    public func propose(_ record: LearnedMemory, in state: LearningState, now: Date = Date()) throws -> LearningState {
        try validate(record, now: now)
        guard !state.records.contains(where: { $0.id == record.id }) else { throw LearningError.invalidRecord }
        var pending = record
        pending.userConfirmed = false; pending.supersededBy = nil; pending.revision = 1
        pending.createdAt = now; pending.updatedAt = now
        pending.key = normalized(pending.key)
        var next = state; next.records.append(pending); return next
    }
    public func confirm(id: UUID, in state: LearningState, now: Date = Date()) throws -> LearningState {
        guard let index = state.records.firstIndex(where: { $0.id == id }) else { throw LearningError.missingRecord }
        let record = state.records[index]
        try validate(record, now: now)
        guard record.supersededBy == nil else { throw LearningError.conflictingRecord }
        // Conflicting claims remain pending; an explicit user correction resolves the conflict.
        guard !state.records.contains(where: {
            $0.id != id && normalized($0.key) == normalized(record.key) && $0.userConfirmed &&
            $0.supersededBy == nil && ($0.expiresAt == nil || $0.expiresAt! > now) && $0.text != record.text
        }) else { throw LearningError.conflictingRecord }
        var next = state; next.records[index].userConfirmed = true
        next.records[index].updatedAt = now; return next
    }
    public func correct(id: UUID, text: String, in state: LearningState, now: Date = Date()) throws -> LearningState {
        guard let index = state.records.firstIndex(where: { $0.id == id }) else { throw LearningError.missingRecord }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LearningError.invalidRecord }
        var corrected = state.records[index]
        // Expired external information needs new evidence instead of silently extending freshness.
        try validate(corrected, now: now)
        corrected.text = text; corrected.source = .userCorrection; corrected.updatedAt = now
        corrected.userConfirmed = true; corrected.revision += 1; corrected.supersededBy = nil
        corrected.confidence = 1
        corrected.provenance = .init(sourceID: "user-correction", capturedAt: now, explanation: "Kullanıcı düzeltmesi")
        var next = state
        for other in next.records.indices where other != index && normalized(next.records[other].key) == normalized(corrected.key) {
            next.records[other].userConfirmed = false
            next.records[other].supersededBy = id
        }
        next.records[index] = corrected; return next
    }
    public func delete(id: UUID, in state: LearningState) throws -> LearningState {
        guard state.records.contains(where: { $0.id == id }) else { throw LearningError.missingRecord }
        var next = state
        // Remove superseded claims for the topic too; deleting a correction must not resurrect old content.
        next.records.removeAll { $0.id == id || $0.supersededBy == id }
        return next
    }
    public func retrieve(query: String, in state: LearningState, now: Date = Date()) -> [LearnedMemory] {
        let search = normalized(query)
        return state.records.filter {
            $0.userConfirmed && $0.supersededBy == nil && $0.sensitivity != .secret &&
            ($0.expiresAt == nil || $0.expiresAt! > now) &&
            (search.isEmpty || normalized($0.key).contains(search) || normalized($0.text).contains(search))
        }.sorted {
            if ($0.source == .userCorrection) != ($1.source == .userCorrection) { return $0.source == .userCorrection }
            return $0.updatedAt > $1.updatedAt
        }
    }
    /// Audit-only schema; successful execution must have an actual receipt supplied by a trusted executor.
    public func recordExperience(_ experience: TaskExperience, in state: LearningState) throws -> LearningState {
        guard !experience.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !state.experiences.contains(where: { $0.id == experience.id }) else { throw LearningError.invalidRecord }
        if experience.outcome == .succeeded,
           experience.executionReceipt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw LearningError.missingReceipt
        }
        var next = state; next.experiences.append(experience); return next
    }
    private func validate(_ record: LearnedMemory, now: Date) throws {
        guard !record.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.provenance.sourceID.isEmpty,
              record.confidence.isFinite, (0...1).contains(record.confidence) else { throw LearningError.invalidRecord }
        guard record.sensitivity != .secret else { throw LearningError.secretNotAllowed }
        if let expiry = record.expiresAt, expiry <= now { throw LearningError.expired }
        // Source-backed external knowledge is always bounded, at most 30 days after retrieval.
        if record.source == .externalSource {
            guard record.provenance.sourceURL != nil, record.provenance.capturedAt <= now, let expiry = record.expiresAt,
                  expiry <= record.provenance.capturedAt.addingTimeInterval(30 * 86400) else { throw LearningError.invalidRecord }
        }
        // A durable preference/rule remains until explicitly changed or deleted.
        if record.kind == .preference || record.kind == .rule {
            guard record.expiresAt == nil else { throw LearningError.invalidRecord }
        }
    }
    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
    }
}
