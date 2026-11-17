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
    public let actionResult: ActionExecutionResult?
    public var exportedData: Data? { actionResult?.exportedData }
    public init(text: String, generated: StoredAIAnswer?, fromCache: Bool,
                historyWriteFailed: Bool, actionResult: ActionExecutionResult? = nil) {
        self.text = text; self.generated = generated; self.fromCache = fromCache
        self.historyWriteFailed = historyWriteFailed; self.actionResult = actionResult
    }
}
public enum AssistantError: Error, Equatable {
    case consentRequired, contextChanged, approvalRequired, credentialDetected
    public var userMessage: String {
        switch self {
        case .consentRequired: "Bulut AI kapalı. AI ayarlarından veri paylaşımını açıkça onaylayın. Yerel hafıza komutları çalışır."
        case .contextChanged: "İstek sırasında hafıza değişti veya temizlendi. Eski bağlamdan üretilen yanıt kaydedilmedi; yeniden deneyin."
        case .approvalRequired: "Bu işlem yalnızca doğrudan kullanıcı komutuyla gerçekleştirilebilir."
        case .credentialDetected: "Metinde erişim anahtarı veya parola olabilecek bir bilgi var. Sunucuya gönderilmedi; bu bilgiyi kaldırın."
        }
    }
}
public enum AnswerFreshnessPolicy {
    /// Conservative hints supplement provider evidence; they never establish freshness.
    public static func isDynamic(_ question: String) -> Bool {
        let text = question.lowercased(with: Locale(identifier: "tr_TR"))
        return ["bugün", "şimdi", "güncel", "son durum", "hava", "fiyat", "kur ", "dolar", "euro", "borsa", "hisse", "saat", "trafik", "haber", "yarın", "finans"].contains { text.contains($0) }
            || OfflineCurrentFactPolicy.requiresFreshEvidence(question)
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
public enum AIProcessingMode: Sendable { case remote, onDevice }

public struct AssistantService: Sendable {
    private let store: MemoryStore
    private let provider: any AIProvider
    private let providerScope: String
    private let processingMode: AIProcessingMode
    private let permissions: PermissionManager
    public init(store: MemoryStore, provider: any AIProvider = UnavailableAIProvider(),
                providerScope: String = "unconfigured", processingMode: AIProcessingMode = .remote,
                permissions: PermissionManager = PermissionManager()) {
        self.store = store
        self.provider = provider
        self.providerScope = providerScope
        self.processingMode = processingMode
        self.permissions = permissions
    }
    /// Entry point for a current owner message. Context and model replies are display data;
    /// they are never recursively submitted here as fresh owner instructions.
    public func reply(to prompt: String, consent: AISharingConsent,
                      origin: ActionOrigin = .userInterface, now: Date = Date(),
                      onToken: AITokenHandler? = nil) async throws -> AssistantReply {
        try Task.checkCancellation()
        guard origin == .userInterface else { throw ActionPermissionError.untrustedOrigin }
        if let operation = CommandRouter.ownerAction(for: prompt) {
            let request = ActionRequest(operation: operation, origin: origin)
            let authorization = try await permissions.authorizeOwnerCommand(request)
            let result = try await ActionExecutor(store: store, permissions: permissions)
                .execute(request, authorization: authorization)
            return AssistantReply(text: result.message, generated: nil, fromCache: false,
                                  historyWriteFailed: false, actionResult: result)
        }
        let router = CommandRouter(store: store)
        if CommandRouter.isLocalCommand(prompt) {
            let result = try await router.executeWithHistory(prompt)
            return AssistantReply(text: result.reply, generated: nil, fromCache: false, historyWriteFailed: result.historyWriteFailed)
        }
        // Local inference never needs network consent or a cloud token.
        guard processingMode == .onDevice || consent.networkAllowed else {
            throw AssistantError.consentRequired
        }
        let (state, epoch) = try await store.aiContextSnapshot(now: now)
        if processingMode == .onDevice {
            if let local = OfflineCurrentFactPolicy.clockReply(to: prompt, now: now) {
                return try await localFactReply(local, prompt: prompt, now: now)
            }
        }
        let scope = providerScope + "|" + consent.cacheScope
        if !consent.recentHistory, !AnswerFreshnessPolicy.isDynamic(prompt), let cached = state.generatedAnswers.last(where: {
            $0.question == prompt && $0.cacheScope == scope && $0.savedAt <= now && ($0.cacheUntil ?? .distantPast) > now
        }) {
            try await store.validateAIContext(expectedEpoch: epoch)
            try Task.checkCancellation()
            return AssistantReply(text: cached.response.text, generated: cached, fromCache: true, historyWriteFailed: false)
        }
        var context: [AIContextEntry] = []
        var historyCategories: Set<String> = []
        if processingMode == .onDevice {
            context = LocalConversationContext.select(
                state: state, query: prompt, consent: consent, now: now)
            let selectedIDs = Set(context.map(\.id))
            for answer in state.generatedAnswers where selectedIDs.contains("answer:\(answer.id)") {
                historyCategories.formUnion(answer.contextIDs.filter {
                    $0.hasPrefix("personal:") || $0.hasPrefix("learning:") || $0.hasPrefix("experience:")
                })
                if answer.contextIDs.contains(where: { $0.hasPrefix("personal:") || $0 == "derived:personal" }) {
                    historyCategories.insert("derived:personal")
                }
                if answer.contextIDs.contains(where: { $0.hasPrefix("learning:") || $0.hasPrefix("experience:") || $0 == "derived:learning" }) {
                    historyCategories.insert("derived:learning")
                }
            }
        } else {
        if consent.confirmedLearning {
            let memories = LocalLearningEngine().shareableContext(query: "", in: state.learning, now: now)
            context += memories.map { AIContextEntry(id: "learning:\($0.id)", text: "\($0.key): \($0.text)") }
        }
        if consent.personalMemory {
            context += state.personal.reversed()
                .map { AIContextEntry(id: "personal:\($0.id)", text: $0.text) }
        }
        if consent.recentHistory {
            let local = state.conversations.map { ($0.createdAt, "conversation:\($0.id)", $0.text, Set<String>()) }
            let generated = state.generatedAnswers.compactMap { answer -> (Date, String, String, Set<String>)? in
                var categories = Set(answer.contextIDs.filter {
                    $0.hasPrefix("personal:") || $0.hasPrefix("learning:") || $0.hasPrefix("experience:")
                })
                if answer.contextIDs.contains(where: { $0.hasPrefix("personal:") || $0 == "derived:personal" }) { categories.insert("derived:personal") }
                if answer.contextIDs.contains(where: { $0.hasPrefix("learning:") || $0.hasPrefix("experience:") || $0 == "derived:learning" }) { categories.insert("derived:learning") }
                guard (!categories.contains("derived:personal") || consent.personalMemory),
                      (!categories.contains("derived:learning") || consent.confirmedLearning) else { return nil }
                return (answer.savedAt, "answer:\(answer.id)", "Kullanıcı: \(answer.question)\nAI: \(answer.response.text)", categories)
            }
            let history = (local + generated).sorted { $0.0 < $1.0 }
            context += history.map { AIContextEntry(id: $0.1, text: $0.2) }
            history.forEach { historyCategories.formUnion($0.3) }
        }
        }
        if processingMode == .onDevice, OfflineCurrentFactPolicy.requiresFreshEvidence(prompt),
           !LocalConversationContext.hasFreshEvidence(state: state, query: prompt, consent: consent,
                                                       now: now, selectedContext: context) {
            return try await localFactReply(OfflineCurrentFactPolicy.unavailableMessage, prompt: prompt, now: now)
        }
        try Task.checkCancellation()
        let request = AIRequest(prompt: prompt, context: context)
        let response: AIResponse
        if let onToken {
            response = try await provider.respond(to: request) { delta in
                try Task.checkCancellation()
                try await store.validateAIContext(expectedEpoch: epoch)
                try await onToken(delta)
                try Task.checkCancellation()
                try await store.validateAIContext(expectedEpoch: epoch)
            }
        } else {
            response = try await provider.respond(to: request)
        }
        try Task.checkCancellation()
        let answer = StoredAIAnswer(question: prompt, response: response, savedAt: now,
            cacheUntil: consent.recentHistory ? nil : AnswerFreshnessPolicy.cacheUntil(question: prompt, response: response, now: now),
            cacheScope: scope, contextIDs: context.map(\.id) + historyCategories.sorted())
        try await store.recordGeneratedAnswer(answer, expectedEpoch: epoch)
        try Task.checkCancellation()
        return AssistantReply(text: response.text, generated: answer, fromCache: false, historyWriteFailed: false)
    }

    private func localFactReply(_ text: String, prompt: String, now: Date) async throws -> AssistantReply {
        try Task.checkCancellation()
        do {
            try await store.record("Siz: \(prompt)\nJARVIS: \(text)", now: now)
            return AssistantReply(text: text, generated: nil, fromCache: false, historyWriteFailed: false)
        } catch is CancellationError { throw CancellationError() }
        catch {
            return AssistantReply(text: text, generated: nil, fromCache: false, historyWriteFailed: true)
        }
    }
}

/// Current external facts need evidence; the device clock is available offline.
/// This application routing policy does not add or modify a model system prompt.
public enum OfflineCurrentFactPolicy {
    public static let unavailableMessage = "Bu güncel bilgiyi çevrimdışı doğrulayamıyorum. Güncel ve doğrulanmış bir kaynak olmadan kesin yanıt veremem."

    public static func requiresFreshEvidence(_ prompt: String) -> Bool {
        let text = prompt.lowercased(with: Locale(identifier: "tr_TR"))
        let words = Set(text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let current = ["bugün", "şimdi", "şu an", "güncel", "en son", "son dakika", "yarın", "anlık", "bu hafta"]
            .contains { text.contains($0) }
        let weather = text.contains("hava durumu") || text.contains("hava nasıl") ||
            text.contains("yağmur yağacak") || text.contains("kaç derece")
        let scientific = ["nasıl oluş", "nasıl hesap", "nasıl ölç", "neden oluş", "ne demek", "algoritma", "oluşur"]
            .contains { text.contains($0) }
        let programming = ["kod yaz", "kodla", "simülasyon", "örnek veri", "istemcisi", "nasıl çekilir"]
            .contains { text.contains($0) }
        if weather && !scientific && !programming { return true }
        let finances = !words.isDisjoint(with: ["dolar", "euro", "altın", "borsa", "hisse", "bitcoin", "kripto", "fiyat", "fiyatı", "kur", "kuru"])
        let priceQuestion = words.contains("kaç") || text.contains("ne kadar") || words.contains("kuru") || words.contains("fiyatı")
        if finances && (current || priceQuestion) && !scientific && !programming { return true }
        let liveTopic = !words.isDisjoint(with: ["haber", "haberler", "gündem", "trafik", "sonuçları", "sıcaklık"])
        return current && liveTopic && !scientific && !programming
    }

    public static func clockReply(to prompt: String, now: Date, timeZone: TimeZone = .current) -> String? {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased(with: Locale(identifier: "tr_TR"))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.timeZone = timeZone
        if ["saat kaç", "şimdi saat kaç", "şu an saat kaç"].contains(text) {
            formatter.dateFormat = "HH:mm"
            return "Cihaz saatine göre \(formatter.string(from: now))."
        }
        if ["bugünün tarihi", "bugünün tarihi ne", "bugün ayın kaçı", "bugün hangi gün"].contains(text) {
            formatter.dateFormat = "d MMMM yyyy, EEEE"
            return "Cihaz tarihine göre \(formatter.string(from: now))."
        }
        return nil
    }
}
