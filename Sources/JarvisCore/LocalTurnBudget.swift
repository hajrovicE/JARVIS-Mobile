import Foundation

/// A device-local latency/quality tradeoff; never changes who can call a tool,
/// what data is sent over the network, or the owner's explicit generation caps.
public struct LocalTurnBudget: Equatable, Sendable {
    public let maxNewTokens: Int
    public let contextTokens: Int
    public let needsDetail: Bool

    public static func select(prompt: String, fastConversation: Bool,
                              ownerMaxNewTokens: Int,
                              ownerContextTokens: Int) -> LocalTurnBudget {
        let normalized = prompt.lowercased(with: Locale(identifier: "tr_TR"))
        let details = ["/think", "```", "swift", "python", "javascript", "sql", "algoritma", "kanıtla", "matematik", "debug", "hata ayıkla", "detaylı", "ayrıntılı", "adım adım", "karşılaştır", "analiz",
                       "kod yaz", "kodla", "örneklerle", "hesapla", "nedenini açıkla",
                       "plan hazırla", "incele", "araştır"].contains { normalized.contains($0) }
        let userTokens = ownerMaxNewTokens
        let userContext = ownerContextTokens
        // Invalid settings stay invalid so the native runtime can report them.
        // Raising a low owner cap here silently changes the requested behavior.
        guard fastConversation else {
            return LocalTurnBudget(maxNewTokens: userTokens,
                                   contextTokens: userContext, needsDetail: details)
        }
        return LocalTurnBudget(maxNewTokens: min(details ? 768 : 256, userTokens),
                               contextTokens: min(details ? 4096 : 3072, userContext),
                               needsDetail: details)
    }
}
