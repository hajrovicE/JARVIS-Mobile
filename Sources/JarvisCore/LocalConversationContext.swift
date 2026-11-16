import Foundation

/// Bounded, relevance-ranked context for a small on-device model.
///
/// A long, unranked memory dump makes decoding slower and can reduce answer
/// quality. This selector does not modify any saved memory or network consent.
public enum LocalConversationContext {
    public static let maxCharacters = 3_600
    public static let maxEntries = 7
    private static let perEntryLimit = 680

    private struct Candidate {
        let id: String
        let content: String
        let weight: Int
        let time: Date
    }

    public static func select(state: MemorySnapshot, query: String,
                              consent: AISharingConsent, now: Date = Date()) -> [AIContextEntry] {
        let queryTerms = words(query)
        var candidates: [Candidate] = []

        if consent.confirmedLearning {
            let confirmed = LocalLearningEngine().shareableContext(
                query: "", in: state.learning, now: now)
            for record in confirmed {
                let text = record.key + ": " + record.text
                let score = overlap(text, queryTerms: queryTerms)
                candidates.append(Candidate(id: "learning:\(record.id)", content: text,
                                            weight: 15 + score * 12, time: record.updatedAt))
            }
        }
        if consent.personalMemory {
            for item in state.personal {
                let score = overlap(item.text, queryTerms: queryTerms)
                candidates.append(Candidate(id: "personal:\(item.id)", content: item.text,
                                            weight: 8 + score * 12, time: item.createdAt))
            }
        }
        if consent.recentHistory {
            // Last two actual dialogues anchor pronouns and follow-up questions.
            // Older history is still in the encrypted store, not copied into
            // every inference prompt. Preference changes invalidate prior answers.
            for item in state.conversations.suffix(2) {
                candidates.append(Candidate(id: "conversation:\(item.id)",
                                            content: item.text, weight: 50,
                                            time: item.createdAt))
            }
            for item in state.generatedAnswers.suffix(2) {
                var allowed = true
                if !consent.personalMemory,
                   item.contextIDs.contains(where: { $0.hasPrefix("personal:") || $0 == "derived:personal" }) {
                    allowed = false
                }
                if !consent.confirmedLearning,
                   item.contextIDs.contains(where: { $0.hasPrefix("learning:") || $0 == "derived:learning" }) {
                    allowed = false
                }
                guard allowed else { continue }
                let text = "Kullanıcı: \(item.question)\nJARVIS: \(item.response.text)"
                candidates.append(Candidate(id: "answer:\(item.id)", content: text,
                                            weight: 60, time: item.savedAt))
            }
        }

        let ranked = candidates.sorted {
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            if $0.time != $1.time { return $0.time > $1.time }
            return $0.id < $1.id
        }

        var selected: [AIContextEntry] = []
        var used = 0
        var seen = Set<String>()
        for item in ranked {
            guard selected.count < maxEntries, used < maxCharacters else { break }
            let clipped = String(item.content.prefix(min(perEntryLimit, maxCharacters - used)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clipped.isEmpty, !seen.contains(clipped) else { continue }
            seen.insert(clipped)
            selected.append(AIContextEntry(id: item.id, text: clipped))
            used += clipped.count
        }
        return selected
    }

    private static func overlap(_ text: String, queryTerms: Set<String>) -> Int {
        guard !queryTerms.isEmpty else { return 0 }
        return words(text).intersection(queryTerms).count
    }

    private static func words(_ text: String) -> Set<String> {
        let normalized = text.lowercased(with: Locale(identifier: "tr_TR"))
        return Set(normalized.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 })
    }
}
