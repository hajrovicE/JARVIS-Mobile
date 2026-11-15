import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Only explicitly selected, consented context belongs in a remote request.
public struct AIContextEntry: Codable, Equatable, Sendable {
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
}

public struct AIRequest: Codable, Equatable, Sendable {
    public let prompt: String
    public let context: [AIContextEntry]
    public init(prompt: String, context: [AIContextEntry] = []) {
        self.prompt = prompt; self.context = context
    }
}

public enum AIFreshness: String, Codable, Sendable { case unverified, verifiedStatic }

public struct AISource: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let retrievedAt: Date
    public init(id: String, title: String, url: URL, retrievedAt: Date) {
        self.id = id; self.title = title; self.url = url; self.retrievedAt = retrievedAt
    }
}

/// Provider output is untrusted content. It never authorizes or executes an action.
public struct AIResponse: Codable, Equatable, Sendable {
    public let text: String
    public let provider: String
    public let model: String
    public let generatedAt: Date
    public let sources: [AISource]
    public let freshness: AIFreshness
    public let expiresAt: Date?
    public init(text: String, provider: String, model: String, generatedAt: Date,
                sources: [AISource] = [], freshness: AIFreshness = .unverified,
                expiresAt: Date? = nil) {
        self.text = text; self.provider = provider; self.model = model; self.generatedAt = generatedAt
        self.sources = sources; self.freshness = freshness; self.expiresAt = expiresAt
    }
}

public enum AIProviderError: Error, Equatable, Sendable {
    case notConfigured, invalidConfiguration, invalidRequest, unauthorized, rateLimited
    case networkUnavailable, unavailable, invalidResponse, emptyResponse, cancelled
    public var userMessage: String {
        switch self {
        case .notConfigured: return "Gerçek model bağlantısı yapılandırılmadı. Yerel hafıza komutları kullanılabilir."
        case .invalidConfiguration: return "AI bağlantı ayarları geçersiz. HTTPS sunucu adresini ve erişim bilgilerini kontrol edin."
        case .invalidRequest: return "Soru veya paylaşılan bağlam desteklenen sınırları aşıyor. Metni kısaltıp tekrar deneyin."
        case .unauthorized: return "AI sunucusu erişim bilgisini kabul etmedi. Erişim bilgilerinizi yenileyin."
        case .rateLimited: return "AI sunucusunun istek sınırına ulaşıldı. Daha sonra tekrar deneyin."
        case .networkUnavailable: return "AI sunucusuna ulaşılamıyor. İnternet bağlantısını kontrol edin; yerel hafıza çalışmaya devam eder."
        case .unavailable: return "Gerçek model şu anda yanıt veremiyor. Yerel hafıza komutları kullanılabilir."
        case .invalidResponse: return "Model sunucusunun yanıtı doğrulanamadı. Bir cevap üretilmiş gibi gösterilmiyor."
        case .emptyResponse: return "Gerçek modelden yanıt alınamadı. Yeniden deneyebilirsiniz."
        case .cancelled: return "AI isteği iptal edildi."
        }
    }
}

public protocol AIProvider: Sendable {
    func respond(to request: AIRequest) async throws -> AIResponse
}

public struct UnavailableAIProvider: AIProvider {
    public init() {}
    public func respond(to request: AIRequest) async throws -> AIResponse { throw AIProviderError.notConfigured }
}

public protocol AIHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// A dedicated ephemeral session: no cookies, cached replies or ambient credentials.
public struct URLSessionAITransport: AIHTTPTransport {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: NoAIRedirects(), delegateQueue: nil)
    }
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIProviderError.invalidResponse }
        return (data, response)
    }
}

private final class NoAIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Never forward consented context or a bearer token to a different endpoint.
        completionHandler(nil)
    }
}

/// Talks to the user's configured relay, never directly to a model vendor from the binary.
/// `accessToken` is a revocable relay credential. Persist it in Keychain, not UserDefaults.
public struct HTTPRelayAIProvider: AIProvider {
    private let endpoint: URL
    private let accessToken: String
    private let transport: any AIHTTPTransport
    public init(endpoint: URL, accessToken: String,
                transport: any AIHTTPTransport = URLSessionAITransport()) throws {
        guard endpoint.scheme?.lowercased() == "https", let host = endpoint.host, !host.isEmpty,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              (32...8192).contains(accessToken.utf8.count),
              accessToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw AIProviderError.invalidConfiguration
        }
        self.endpoint = endpoint; self.accessToken = accessToken; self.transport = transport
    }
    public func respond(to request: AIRequest) async throws -> AIResponse {
        guard !Task.isCancelled else { throw AIProviderError.cancelled }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.prompt.count <= 8000, request.context.count <= 20,
              request.context.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 128 && !$0.text.isEmpty && $0.text.count <= 2000 }) else {
            throw AIProviderError.invalidRequest
        }
        var http = URLRequest(url: endpoint)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("application/json", forHTTPHeaderField: "Accept")
        http.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        http.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let body = try JSONEncoder().encode(request)
        guard body.count <= 131_072 else { throw AIProviderError.invalidRequest }
        http.httpBody = body
        let payload: Data
        let response: HTTPURLResponse
        do { (payload, response) = try await transport.data(for: http) }
        catch is CancellationError { throw AIProviderError.cancelled }
        catch let error as AIProviderError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw AIProviderError.cancelled }
            throw AIProviderError.networkUnavailable
        }
        catch { throw AIProviderError.unavailable }
        guard !Task.isCancelled else { throw AIProviderError.cancelled }
        guard response.url == endpoint else { throw AIProviderError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 401, 403: throw AIProviderError.unauthorized
        case 429: throw AIProviderError.rateLimited
        case 500...599: throw AIProviderError.unavailable
        default: throw AIProviderError.invalidResponse
        }
        guard payload.count <= 256_000 else { throw AIProviderError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw AIProviderError.invalidResponse }
            return date
        }
        let answer: AIResponse
        do { answer = try decoder.decode(AIResponse.self, from: payload) }
        catch { throw AIProviderError.invalidResponse }
        guard !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIProviderError.emptyResponse }
        guard !answer.provider.isEmpty, !answer.model.isEmpty, answer.text.count <= 60_000,
              answer.sources.count <= 20,
              answer.sources.allSatisfy({ $0.url.scheme?.lowercased() == "https" && $0.url.host != nil && $0.url.user == nil && $0.url.password == nil }),
              answer.generatedAt <= Date().addingTimeInterval(300) else { throw AIProviderError.invalidResponse }
        if answer.freshness == .verifiedStatic {
            // A model's prose cannot turn itself into fresh evidence.
            guard !answer.sources.isEmpty, let expiry = answer.expiresAt,
                  expiry > answer.generatedAt,
                  expiry <= answer.generatedAt.addingTimeInterval(30 * 86400),
                  answer.sources.allSatisfy({ $0.retrievedAt <= answer.generatedAt }) else {
                throw AIProviderError.invalidResponse
            }
        }
        return answer
    }
}
