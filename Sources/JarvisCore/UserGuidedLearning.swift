import Foundation

/// User-owned conversation settings are not permissions. They may change
/// response presentation, but never grant access to iOS, accounts or tools.
public enum AnswerStyle: String, Codable, CaseIterable, Sendable {
    case direct
    case analytical
    case concise
}

public struct PersonalAIPreferences: Codable, Equatable, Sendable {
    public var answerStyle: AnswerStyle
    public var questionAssumptions: Bool
    public var offerUnconventionalIdeas: Bool

    public init(answerStyle: AnswerStyle = .direct,
                questionAssumptions: Bool = true,
                offerUnconventionalIdeas: Bool = true) {
        self.answerStyle = answerStyle
        self.questionAssumptions = questionAssumptions
        self.offerUnconventionalIdeas = offerUnconventionalIdeas
    }

    /// Presentation guidance only. Never spliced into executable instructions
    /// or a tool's permission policy.
    public func localPresentationGuidance() -> String {
        let style: String
        switch answerStyle {
        case .direct: style = "Doğrudan, net ve gerekçeli yanıt ver."
        case .analytical: style = "Alternatifleri, varsayımları ve kanıt düzeyini analiz et."
        case .concise: style = "Özü kısa ve anlaşılır biçimde anlat."
        }
        return [
            style,
            questionAssumptions ? "Yerinde olduğunda kullanıcının varsayımlarını sorgula." : "",
            offerUnconventionalIdeas ? "Uygunsa yaratıcı ve alışılmadık fikirler de öner." : "",
            "Bilmediğin bilgiyi uydurma. Kullanıcı tercihleri araç veya cihaz yetkisi değildir."
        ].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public enum GuidedLearningError: Error, Equatable, Sendable {
    case invalidTopic, invalidTeaching, secretDetected, ambiguousTopic
}

public struct LearningProgressReport: Equatable, Sendable {
    public let confirmed: Int
    public let pending: Int
    public let successfulTasks: Int
    public let failedTasks: Int
    public let suggestedFixes: Int
    public let generatedAt: Date
}

/// Continually improves its retrieval memory from **explicit user teaching**
/// and actual completed task receipts, not from invented execution success.
/// Model weights are NOT trained by this component.
public actor UserGuidedLearning {
    private let store: MemoryStore
    private let prefix = "user.lesson."

    public init(store: MemoryStore) {
        self.store = store
    }

    /// A complete, user-authored "teach" command is explicit consent to store
    /// this ordinary preference. Re-teaching the same topic creates a revision;
    /// deleting that record removes its revision history.
    @discardableResult
    public func teach(topic: String, text: String, now: Date = Date()) async throws -> UUID {
        let normalized = topic.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "tr_TR"))
        let validCharacters = CharacterSet.letters.union(.decimalDigits)
            .union(CharacterSet(charactersIn: "._-"))
        guard (1...64).contains(normalized.count),
              normalized.unicodeScalars.allSatisfy({ validCharacters.contains($0) }),
              !normalized.hasPrefix("."), !normalized.hasSuffix(".") else {
            throw GuidedLearningError.invalidTopic
        }
        let lesson = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lesson.isEmpty, lesson.count <= 500,
              !lesson.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GuidedLearningError.invalidTeaching
        }
        if CredentialFilter.containsCredential(lesson) || CredentialFilter.containsCredential(normalized) {
            throw GuidedLearningError.secretDetected
        }

        let key = prefix + normalized
        let state = try await store.read(now: now)
        let matching = state.learning.records.filter {
            $0.key == key && $0.userConfirmed && $0.supersededBy == nil
        }
        guard matching.count <= 1 else { throw GuidedLearningError.ambiguousTopic }
        if let existing = matching.first {
            if existing.text != lesson {
                try await store.correctLearning(id: existing.id, text: lesson, now: now)
            }
            return existing.id
        }

        let record = LearnedMemory(
            kind: .rule, key: key, text: lesson, source: .userInput,
            createdAt: now, confidence: 1, sensitivity: .ordinary,
            provenance: .init(sourceID: "explicit-user-teaching", capturedAt: now,
                              explanation: "Kullanıcının doğrudan öğretme komutu"))
        try await store.proposeLearning(record, now: now)
        // Explicit teaching is a direct user instruction, unlike model-derived
        // suggestions, which continue to require a separate confirmation.
        try await store.confirmLearning(id: record.id, expectedText: lesson, now: now)
        return record.id
    }

    public func report(now: Date = Date()) async throws -> LearningProgressReport {
        let state = try await store.read(now: now)
        let active = state.learning.records.filter { $0.supersededBy == nil }
        return LearningProgressReport(
            confirmed: active.filter(\.userConfirmed).count,
            pending: active.filter { !$0.userConfirmed }.count,
            successfulTasks: state.learning.experiences.filter { $0.outcome == .succeeded }.count,
            failedTasks: state.learning.experiences.filter { $0.outcome == .failed }.count,
            suggestedFixes: active.filter { $0.source == .taskResult && !$0.userConfirmed }.count,
            generatedAt: now
        )
    }
}
