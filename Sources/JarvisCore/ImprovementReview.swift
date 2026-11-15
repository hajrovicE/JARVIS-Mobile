import Foundation

/// A candidate for improving JARVIS's reliability. It is an observation, not a
/// self-issued instruction to modify code, install a skill or execute a tool.
public struct ImprovementOpportunity: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let failureCount: Int
    public let risk: TaskRisk
    public let reason: String
}

public enum ImprovementReview {
    /// Only trusted ActionExecutor receipts and recorded failures enter this review.
    /// Unsupported or unrecognized action identifiers cannot cause a new ability.
    public static func opportunities(from state: LearningState, now: Date = Date()) -> [ImprovementOpportunity] {
        let safeNames: Set<String> = [
            "memory.remember", "memory.delete", "memory.deleteAll",
            "learning.delete", "memory.export"
        ]
        let recent = state.experiences.filter {
            let elapsed = now.timeIntervalSince($0.createdAt)
            return elapsed >= 0 && elapsed < 90 * 86400 &&
                safeNames.contains($0.action)
        }
        let grouped = Dictionary(grouping: recent, by: \.action)
        return grouped.compactMap { action, experiences -> ImprovementOpportunity? in
            let failures = experiences.filter { $0.outcome == .failed }.count
            guard failures >= 2 else { return nil }
            let risk: TaskRisk = experiences.contains(where: { $0.risk == .high }) ?
                .high : (experiences.contains(where: { $0.risk == .sensitive }) ? .sensitive : .low)
            return ImprovementOpportunity(
                id: "reliability." + action,
                title: action + " için güvenilirlik incelemesi",
                failureCount: failures, risk: risk,
                reason: "Bu işlem birkaç kez başarısız olmuş. İzin, test ve gerçek sonuç makbuzlarını incele; kullanıcı onayı olmadan işlemi tekrarlama."
            )
        }.sorted {
            if $0.failureCount != $1.failureCount { return $0.failureCount > $1.failureCount }
            return $0.id < $1.id
        }
    }
}
