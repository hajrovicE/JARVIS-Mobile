import Foundation

public struct AISharingConsent: Equatable, Sendable {
    public var networkAllowed: Bool
    public var personalMemory: Bool
    public var confirmedLearning: Bool
    public var recentHistory: Bool
    public init(networkAllowed: Bool = false, personalMemory: Bool = false,
                confirmedLearning: Bool = false, recentHistory: Bool = false) {
        self.networkAllowed = networkAllowed; self.personalMemory = personalMemory
        self.confirmedLearning = confirmedLearning; self.recentHistory = recentHistory
    }
    var cacheScope: String { "\(personalMemory)-\(confirmedLearning)-\(recentHistory)" }
}
public struct StoredAIAnswer: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let question: String
    public let response: AIResponse
    public let savedAt: Date
    public let cacheUntil: Date?
    public let cacheScope: String
    public let contextIDs: [String]
    public init(id: UUID = UUID(), question: String, response: AIResponse, savedAt: Date,
                cacheUntil: Date?, cacheScope: String, contextIDs: [String]) {
        self.id = id; self.question = question; self.response = response; self.savedAt = savedAt
        self.cacheUntil = cacheUntil; self.cacheScope = cacheScope; self.contextIDs = contextIDs
    }
}
public struct AssistantReply: Sendable {
    public let text: String
    public let generated: StoredAIAnswer?
    public let fromCache: Bool
    public let historyWriteFailed: Bool
}
public enum AssistantError: Error, Equatable {
    case consentRequired, contextChanged, approvalRequired, credentialDetected
    public var userMessage: String {
        switch self {
        case .consentRequired: "Bulut AI kapalı. AI ayarlarından veri paylaşımını açıkça onaylayın. Yerel hafıza komutları çalışır."
        case .contextChanged: "İstek sırasında hafıza değişti veya temizlendi. Eski bağlamdan üretilen yanıt kaydedilmedi; yeniden deneyin."
        case .approvalRequired: "Silme işlemi için kullanıcı onayı ve cihaz biyometrisi gerekir. Hafıza sekmesini kullanın."
        case .credentialDetected: "Metinde erişim anahtarı veya parola olabilecek bir bilgi var. Sunucuya gönderilmedi; bu bilgiyi kaldırın."
        }
    }
}
public enum AnswerFreshnessPolicy {
    /// Conservative hints supplement provider evidence; they never establish freshness.
    public static func isDynamic(_ question: String) -> Bool {
        let text = question.lowercased(with: Locale(identifier: "tr_TR"))
        return ["bugün", "şimdi", "güncel", "son durum", "hava", "fiyat", "kur ", "dolar", "euro", "borsa", "hisse", "saat", "trafik", "haber", "yarın", "finans"].contains { text.contains($0) }
    }
    public static func cacheUntil(question: String, response: AIResponse, now: Date) -> Date? {
        guard !isDynamic(question), response.freshness == .verifiedStatic,
              !response.sources.isEmpty, let expiry = response.expiresAt, expiry > now,
              response.generatedAt <= now.addingTimeInterval(60),
              response.sources.allSatisfy({ $0.retrievedAt <= now && $0.retrievedAt.addingTimeInterval(30 * 86400) > now }) else { return nil }
        return min(expiry, now.addingTimeInterval(30 * 86400), response.generatedAt.addingTimeInterval(30 * 86400))
    }
}

/// Local commands always run first. Model output is display data, never an ActionRequest.
public struct AssistantService: Sendable {
    private let store: MemoryStore
    private let provider: any AIProvider
    private let providerScope: String
    public init(store: MemoryStore, provider: any AIProvider = UnavailableAIProvider(), providerScope: String = "unconfigured") {
        self.store = store; self.provider = provider; self.providerScope = providerScope
    }
    public func reply(to prompt: String, consent: AISharingConsent, now: Date = Date()) async throws -> AssistantReply {
        try Task.checkCancellation()
        let router = CommandRouter(store: store)
        if CommandRouter.isLocalCommand(prompt) {
            let result = try await router.executeWithHistory(prompt)
            return AssistantReply(text: result.reply, generated: nil, fromCache: false, historyWriteFailed: result.historyWriteFailed)
        }
        guard consent.networkAllowed else { throw AssistantError.consentRequired }
        guard !CredentialFilter.containsCredential(prompt) else { throw AssistantError.credentialDetected }
        let (state, epoch) = try await store.aiContextSnapshot(now: now)
        let scope = providerScope + "|" + consent.cacheScope
        if !consent.recentHistory, !AnswerFreshnessPolicy.isDynamic(prompt), let cached = state.generatedAnswers.last(where: {
            $0.question == prompt && $0.cacheScope == scope && ($0.cacheUntil ?? .distantPast) > now
        }) {
            try await store.validateAIContext(expectedEpoch: epoch)
            try Task.checkCancellation()
            return AssistantReply(text: cached.response.text, generated: cached, fromCache: true, historyWriteFailed: false)
        }
        var context: [AIContextEntry] = []
        var historyCategories: Set<String> = []
        if consent.confirmedLearning {
            let memories = LocalLearningEngine().shareableContext(query: "", in: state.learning, now: now)
            context += memories.prefix(10).map { AIContextEntry(id: "learning:\($0.id)", text: String("\($0.key): \($0.text)".prefix(1800))) }
        }
        if consent.personalMemory {
            context += state.personal.reversed().filter { !CredentialFilter.containsCredential($0.text) }.prefix(6)
                .map { AIContextEntry(id: "personal:\($0.id)", text: String($0.text.prefix(1800))) }
        }
        if consent.recentHistory {
            let local = state.conversations.map { ($0.createdAt, "conversation:\($0.id)", $0.text, Set<String>()) }
            let generated = state.generatedAnswers.compactMap { answer -> (Date, String, String, Set<String>)? in
                var categories: Set<String> = []
                if answer.contextIDs.contains(where: { $0.hasPrefix("personal:") || $0 == "derived:personal" }) { categories.insert("derived:personal") }
                if answer.contextIDs.contains(where: { $0.hasPrefix("learning:") || $0 == "derived:learning" }) { categories.insert("derived:learning") }
                guard (!categories.contains("derived:personal") || consent.personalMemory),
                      (!categories.contains("derived:learning") || consent.confirmedLearning) else { return nil }
                return (answer.savedAt, "answer:\(answer.id)", "Kullanıcı: \(answer.question)\nAI: \(answer.response.text)", categories)
            }
            let history = (local + generated).sorted { $0.0 < $1.0 }
                .filter { !CredentialFilter.containsCredential($0.2) }.suffix(4)
            context += history.map { AIContextEntry(id: $0.1, text: String($0.2.prefix(1800))) }
            history.forEach { historyCategories.formUnion($0.3) }
        }
        try Task.checkCancellation()
        let response = try await provider.respond(to: AIRequest(prompt: prompt, context: context))
        try Task.checkCancellation()
        let answer = StoredAIAnswer(question: prompt, response: response, savedAt: now,
            cacheUntil: consent.recentHistory ? nil : AnswerFreshnessPolicy.cacheUntil(question: prompt, response: response, now: now),
            cacheScope: scope, contextIDs: context.map(\.id) + historyCategories.sorted())
        try await store.recordGeneratedAnswer(answer, expectedEpoch: epoch)
        try Task.checkCancellation()
        return AssistantReply(text: response.text, generated: answer, fromCache: false, historyWriteFailed: false)
    }
}
