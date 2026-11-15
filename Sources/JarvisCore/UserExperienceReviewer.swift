import Foundation

/// The owner's judgment of a real, already recorded JARVIS task.
/// Labels express learning preferences. They never modify iOS capabilities,
/// system authorization, third-party permissions or the action allowlist.
public enum ExperienceVerdict: String, Codable, CaseIterable, Sendable {
    case correct
    case incorrect
    case privateInformation

    public var turkishName: String {
        switch self {
        case .correct: "doğru"
        case .incorrect: "yanlış"
        case .privateInformation: "mahrem"
        }
    }

    public init?(turkishName: String) {
        switch turkishName.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR")) {
        case "doğru": self = .correct
        case "yanlış": self = .incorrect
        case "mahrem": self = .privateInformation
        default: return nil
        }
    }
}

public enum ExperienceReviewError: Error, Equatable, Sendable {
    case missingRealExperience, incompleteExperience, invalidFeedback
    case duplicateReview, secretDetected
}

/// Learns from actual task outcome logs and explicit user labels, not from
/// covert surveillance, model opinions, or self-generated claims of success.
public actor UserExperienceReviewer {
    private let store: MemoryStore

    public init(store: MemoryStore) { self.store = store }

    @discardableResult
    public func review(experienceID: UUID, verdict: ExperienceVerdict,
                       lesson: String, now: Date = Date()) async throws -> UUID {
        let cleaned = lesson.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty,
              !cleaned.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { throw ExperienceReviewError.invalidFeedback }
        guard !CredentialFilter.containsCredential(cleaned) else {
            throw ExperienceReviewError.secretDetected
        }
        let snapshot = try await store.read(now: now)
        guard let original = snapshot.learning.experiences.first(where: {
            $0.id == experienceID
        }) else { throw ExperienceReviewError.missingRealExperience }
        guard original.outcome != .proposed else {
            throw ExperienceReviewError.incompleteExperience
        }

        let key = "experience.verdict." + experienceID.uuidString.lowercased()
        guard !snapshot.learning.records.contains(where: {
            $0.key == key
        }) else { throw ExperienceReviewError.duplicateReview }

        let text = verdict.turkishName + ": " + cleaned
        let record = LearnedMemory(
            kind: .suggestion, key: key, text: text, source: .userCorrection,
            createdAt: now, confidence: 1,
            sensitivity: verdict == .privateInformation ? .sensitive : .ordinary,
            provenance: LearningProvenance(
                sourceID: experienceID.uuidString, capturedAt: now,
                explanation: "Kullanıcının geçmiş bir gerçek görev sonucuna ilişkin açık değerlendirmesi")
        )
        try await store.proposeLearning(record, now: now)
        // The owner explicitly labeled this particular existing experience.
        // The verdict is a memory, not an authorization to repeat the task.
        try await store.confirmLearning(id: record.id, expectedText: text, now: now)
        return record.id
    }

    public func reviewedExperiences(now: Date = Date()) async throws -> [LearnedMemory] {
        let snapshot = try await store.read(now: now)
        return snapshot.learning.records.filter {
            $0.userConfirmed && $0.supersededBy == nil &&
                $0.key.hasPrefix("experience.verdict.")
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
}
