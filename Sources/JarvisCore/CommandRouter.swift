import Foundation

public struct CommandExecution: Sendable {
    public let reply: String
    public let historyWriteFailed: Bool
}

public struct CommandRouter: Sendable {
    public let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }
    public static func isLocalCommand(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
        return ["ne hatırlıyorsun", "öğrendiklerin", "geçmiş", "hatırla ki", "bunu hatırla", "unut"].contains(text)
            || ["hatırla ki ", "bunu hatırla ", "unut ", "öğret: "].contains { text.hasPrefix($0) }
    }
    /// Only explicit owner-entered text or a trusted UI gesture is an action request.
    /// A model's reply never calls this parser as an executable command.
    public static func ownerAction(for input: String) -> ActionOperation? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased(with: Locale(identifier: "tr_TR"))
        if normalized == "tüm hafızayı sil" || normalized == "bütün hafızayı sil" {
            return .deleteAllMemory
        }
        if normalized == "hafızayı dışa aktar" || normalized == "verilerimi dışa aktar" {
            return .exportMemory
        }
        if normalized.hasPrefix("unut "), let id = UUID(uuidString: String(text.dropFirst(5))) {
            return .deleteMemory(id)
        }
        if normalized.hasPrefix("öğrenmeyi sil "), let id = UUID(uuidString: String(text.dropFirst("öğrenmeyi sil ".count))) {
            return .deleteLearning(id)
        }
        return nil
    }
    /// Read-only listings never copy their contents into newer conversations.
    /// Mutating memory commands leave only an operation marker, not another copy of a fact.
    public func executeWithHistory(_ input: String) async throws -> CommandExecution {
        let reply = try await execute(input)
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
        if ["geçmiş", "ne hatırlıyorsun", "öğrendiklerin"].contains(normalized) {
            return CommandExecution(reply: reply, historyWriteFailed: false)
        }
        let isMemoryAction = ["hatırla ki ", "bunu hatırla ", "unut ", "öğret: "].contains { normalized.hasPrefix($0) }
        let entry = isMemoryAction ? "Kişisel hafıza komutu işlendi." : "Siz: \(input)\nJARVIS: \(reply)"
        do { try await store.record(entry); return CommandExecution(reply: reply, historyWriteFailed: false) }
        catch { return CommandExecution(reply: reply, historyWriteFailed: true) }
    }
    public func execute(_ input: String) async throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased(with: Locale(identifier: "tr_TR"))
        if normalized.hasPrefix("öğret: ") {
            let payload = String(text.dropFirst("öğret: ".count))
            let pieces = payload.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return "Kullanım: öğret: konu = öğrenilecek bilgi" }
            let topic = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(with: Locale(identifier: "tr_TR"))
            let lesson = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !topic.isEmpty && !lesson.isEmpty else {
                return "Kullanım: öğret: konu = öğrenilecek bilgi"
            }
            let snapshot = try await store.read()
            if let prior = snapshot.learning.records.first(where: { $0.key == topic && $0.supersededBy == nil }) {
                try await store.correctLearning(id: prior.id, text: lesson)
            } else {
                let record = LearnedMemory(kind: .rule, key: topic, text: lesson,
                    source: .userInput, confidence: 1,
                    provenance: .init(sourceID: "owner-command"))
                try await store.proposeLearning(record)
                try await store.confirmLearning(id: record.id, expectedText: lesson)
            }
            return "Öğrettiğiniz bilgi kaydedildi."
        }
        if let prefix = ["hatırla ki ", "bunu hatırla "].first(where: { normalized.hasPrefix($0) }) {
            try await store.remember(String(text.dropFirst(prefix.count)))
            return "Kişisel hafızaya kaydedildi."
        }
        if normalized == "ne hatırlıyorsun" {
            let items = try await store.read().personal
            return items.isEmpty ? "Kişisel hafıza boş." : items.map { "\($0.id): \($0.text)" }.joined(separator: "\n")
        }
        if normalized.hasPrefix("unut ") {
            guard let id = UUID(uuidString: String(text.dropFirst(5))) else { return "Silmek için hafıza kimliğini kullanın veya Hafıza sekmesini açın." }
            _ = id
            throw AssistantError.approvalRequired
        }
        if normalized == "öğrendiklerin" {
            let records = try await store.learnedMemories(query: "")
            return records.isEmpty ? "Onaylanmış öğrenme kaydı yok." : records.map { "\($0.key): \($0.text)" }.joined(separator: "\n")
        }
        if normalized == "geçmiş" {
            let items = try await store.read().conversations
            return items.isEmpty ? "Konuşma geçmişi boş." : items.map(\.text).joined(separator: "\n")
        }
        return "Bu komut desteklenmiyor. Hatırla ki …, ne hatırlıyorsun, unut <kimlik> veya geçmiş komutunu kullanabilirsiniz."
    }
}
