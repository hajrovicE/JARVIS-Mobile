import Foundation

public struct CommandRouter: Sendable {
    public let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }
    public func execute(_ input: String) async throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.lowercased(with: Locale(identifier: "tr_TR"))
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
            try await store.forget(id: id); return "Kayıt silindi."
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
