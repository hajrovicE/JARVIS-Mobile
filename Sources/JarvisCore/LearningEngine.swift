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
    func proposeTaskCorrection(experienceID: UUID, key: String, text: String, in state: LearningState, now: Date) throws -> LearningState
    func shareableContext(query: String, in state: LearningState, now: Date) -> [LearnedMemory]
}
public enum LearningError: Error, Equatable {
    case invalidRecord, secretNotAllowed, missingRecord, expired, conflictingRecord, missingReceipt, staleProposal
}

public struct LocalLearningEngine: LearningEngine {
    public init() {}
    public func propose(_ record: LearnedMemory, in state: LearningState, now: Date = Date()) throws -> LearningState {
        try validate(record, now: now)
        guard !state.records.contains(where: { $0.id == record.id }) else { throw LearningError.invalidRecord }
        var pending = record
        pending.userConfirmed = false; pending.supersededBy = nil; pending.revision = 1; pending.revisions = []
        pending.createdAt = now; pending.updatedAt = now
        pending.key = normalized(pending.key)
        var next = state; next.records.append(pending); return next
    }
    public func confirm(id: UUID, in state: LearningState, now: Date = Date()) throws -> LearningState {
        guard let index = state.records.firstIndex(where: { $0.id == id }) else { throw LearningError.missingRecord }
        let record = state.records[index]
        try validate(record, now: now)
        guard record.supersededBy == nil else { throw LearningError.conflictingRecord }
        // The owner's newest explicit confirmation supersedes earlier views of the same topic.
        var next = state
        for other in next.records.indices where other != index &&
            normalized(next.records[other].key) == normalized(record.key) {
            next.records[other].userConfirmed = false
            next.records[other].supersededBy = id
        }
        next.records[index].userConfirmed = true
        next.records[index].updatedAt = now
        return next
    }
    public func correct(id: UUID, text: String, in state: LearningState, now: Date = Date()) throws -> LearningState {
        guard let index = state.records.firstIndex(where: { $0.id == id }) else { throw LearningError.missingRecord }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LearningError.invalidRecord }
        var corrected = state.records[index]
        // Expired external information needs new evidence instead of silently extending freshness.
        try validate(corrected, now: now)
        var history = corrected.revisions ?? []
        history.append(LearningRevision(record: corrected))
        corrected.revisions = history
        corrected.text = text; corrected.source = .userCorrection; corrected.updatedAt = now
        corrected.userConfirmed = true; corrected.revision += 1; corrected.supersededBy = nil
        corrected.confidence = 1
        corrected.provenance = .init(sourceID: "user-correction", capturedAt: now, explanation: "Kullanıcı düzeltmesi")
        try validate(corrected, now: now)
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
        // Remove the full reverse supersession chain, including older Alpha data with chained links.
        // Deleting an old rejected claim does not erase its newer valid correction.
        var removedIDs: Set<UUID> = [id]
        var changed = true
        while changed {
            changed = false
            for record in next.records where record.supersededBy.map({ removedIDs.contains($0) }) == true {
                if removedIDs.insert(record.id).inserted { changed = true }
            }
        }
        let deletedRecords = next.records.filter { removedIDs.contains($0.id) }
        let sourceExperienceIDs = Set(deletedRecords.flatMap { record -> [UUID] in
            var ids: [UUID] = []
            if record.source == .taskResult, let id = UUID(uuidString: record.provenance.sourceID) { ids.append(id) }
            for revision in record.revisions ?? [] where revision.source == .taskResult {
                if let id = UUID(uuidString: revision.provenance.sourceID) { ids.append(id) }
            }
            return ids
        })
        next.records.removeAll { removedIDs.contains($0.id) }
        // Correction feedback may repeat the deleted fact; remove the linked audit record too.
        next.experiences.removeAll {
            sourceExperienceIDs.contains($0.id) || $0.correctionMemoryID.map({ removedIDs.contains($0) }) == true
        }
        return next
    }
    public func retrieve(query: String, in state: LearningState, now: Date = Date()) -> [LearnedMemory] {
        let search = normalized(query)
        return state.records.filter {
            $0.userConfirmed && $0.supersededBy == nil &&
            (search.isEmpty || normalized($0.key).contains(search) || normalized($0.text).contains(search))
        }.sorted {
            if ($0.source == .userCorrection) != ($1.source == .userCorrection) { return $0.source == .userCorrection }
            return $0.updatedAt > $1.updatedAt
        }
    }
    /// The owner decides whether learned context is shared with a remote provider.
    /// Sensitivity labels are metadata, not a prohibition on learning or retrieving.
    public func shareableContext(query: String, in state: LearningState, now: Date = Date()) -> [LearnedMemory] {
        retrieve(query: query, in: state, now: now).map {
            var selected = $0
            // Historic text is for the user's local audit/export, never implicit model context.
            selected.revisions = nil
            return selected
        }
    }
    /// A user correction becomes a proposed rule; task logs or model prose never confirm it.
    public func proposeTaskCorrection(experienceID: UUID, key: String, text: String,
                                      in state: LearningState, now: Date = Date()) throws -> LearningState {
        guard let index = state.experiences.firstIndex(where: { $0.id == experienceID }) else { throw LearningError.missingRecord }
        let record = LearnedMemory(kind: .rule, key: key, text: text, source: .taskResult,
            createdAt: now, confidence: 1,
            provenance: .init(sourceID: experienceID.uuidString, capturedAt: now,
                              explanation: "Kullanıcının görev düzeltmesi; onay bekliyor"))
        var next = try propose(record, in: state, now: now)
        // A new correction is independent until explicitly confirmed; old confirmed rules remain active.
        next.experiences[index].correctionMemoryID = record.id
        return next
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
        // Expiry, source hints and sensitivity are owner-controlled metadata.
        // Do not discard owner-supplied knowledge merely due to a category or age.
    }
    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
    }
}
