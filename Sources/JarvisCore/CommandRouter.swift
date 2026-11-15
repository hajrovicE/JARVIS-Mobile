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
        return ["ne hatırlıyorsun", "öğrendiklerin", "öğrenme raporu", "geçmiş", "hatırla ki", "bunu hatırla", "unut"].contains(text)
            || ["hatırla ki ", "bunu hatırla ", "unut ", "öğret: "].contains { text.hasPrefix($0) }
    }
    /// Read-only listings never copy their contents into newer conversations.
    /// Mutating memory commands leave only an operation marker, not another copy of a fact.
    public func executeWithHistory(_ input: String) async throws -> CommandExecution {
        let reply = try await execute(input)
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(with: Locale(identifier: "tr_TR"))
        if ["geçmiş", "ne hatırlıyorsun", "öğrendiklerin", "öğrenme raporu"].contains(normalized) {
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
            let fields = payload.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else {
                return "Öğretmek için 'öğret: konu = açıklama' biçimini kullan."
            }
            _ = try await UserGuidedLearning(store: store).teach(
                topic: String(fields[0]), text: String(fields[1]))
            return "Öğrendiğim ilke kaydedildi. Aynı konuyu tekrar öğretirsen eski bilgiyi düzelteceğim."
        }
        if normalized == "öğrenme raporu" {
            let report = try await UserGuidedLearning(store: store).report()
            let state = try await store.read()
            let opportunities = ImprovementReview.opportunities(from: state.learning)
            let improvements = opportunities.isEmpty ? "Gözlenen tekrarlı işlem hatası yok." :
                "İncelenmesi önerilen görev: " + opportunities.map { $0.title }.joined(separator: "; ")
            return "Onaylanan bilgi: \(report.confirmed) · Onay bekleyen: \(report.pending) · Başarılı görev: \(report.successfulTasks) · Başarısız görev: \(report.failedTasks). " + improvements
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
        return "Bu komut desteklenmiyor. Örneğin: öğret: yanıt_tarzı = kısa ve doğrudan ol, hatırla ki …, ne hatırlıyorsun, öğrenme raporu veya geçmiş."
    }
}
