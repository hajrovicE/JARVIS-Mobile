import Foundation

public enum ActionOrigin: String, Sendable { case userInterface, modelProposal }
public enum ActionCapability: String, CaseIterable, Sendable {
    case memoryWrite = "memory.write"
    case memoryDelete = "memory.delete"
    case memoryDeleteAll = "memory.deleteAll"
    case learningDelete = "learning.delete"
    case memoryExport = "memory.export"
}
public enum ActionOperation: Equatable, Sendable {
    case remember(String)
    case deleteMemory(UUID)
    case deleteAllMemory
    case deleteLearning(UUID)
    case exportMemory
    /// Unknown tools remain unexecutable even when presented by a model or imported data.
    case unsupported(String)
}
public struct ActionRequest: Equatable, Sendable {
    public let id: UUID
    public let operation: ActionOperation
    public let origin: ActionOrigin
    public let capabilities: Set<ActionCapability>
    public init(id: UUID = UUID(), operation: ActionOperation,
                origin: ActionOrigin = .userInterface, capabilities: Set<ActionCapability>? = nil) {
        self.id = id; self.operation = operation; self.origin = origin
        self.capabilities = capabilities ?? ActionDescriptor.capabilities(for: operation)
    }
}

/// Only a trusted platform authenticator may satisfy the biometric requirement.
/// Speech, model output and caller-provided `verified` flags are not accepted.
public protocol BiometricAuthenticator: Sendable {
    func authenticate(reason: String) async throws
}
public struct UnavailableBiometricAuthenticator: BiometricAuthenticator {
    public init() {}
    public func authenticate(reason: String) async throws { throw ActionPermissionError.biometricUnavailable }
}
public enum ActionPermissionError: Error, Equatable, Sendable {
    case actionNotAllowed, untrustedOrigin, capabilityMismatch, invalidPayload
    case approvalMissing, approvalExpired, authorizationMissing, authorizationExpired
    case requestMismatch, invalidated, biometricUnavailable, biometricRejected
}

public struct ActionApprovalChallenge: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let summary: String
    public let risk: TaskRisk
    public let capabilities: Set<ActionCapability>
    public let expiresAt: Date
    // No public initializer: an arbitrary serialized proposal cannot manufacture approval.
    init(id: UUID, requestID: UUID, summary: String, risk: TaskRisk,
         capabilities: Set<ActionCapability>, expiresAt: Date) {
        self.id = id; self.requestID = requestID; self.summary = summary; self.risk = risk
        self.capabilities = capabilities; self.expiresAt = expiresAt
    }
}
public struct ActionAuthorization: Equatable, Sendable {
    let token: UUID
    // Opaque, process-local, one-use authority; never Codable or persisted.
    init(token: UUID) { self.token = token }
}

struct ActionDescriptor: Sendable {
    let identifier: String
    let summary: String
    let risk: TaskRisk
    let capabilities: Set<ActionCapability>
    static func capabilities(for operation: ActionOperation) -> Set<ActionCapability> {
        switch operation {
        case .remember: [.memoryWrite]
        case .deleteMemory: [.memoryDelete]
        case .deleteAllMemory: [.memoryDeleteAll]
        case .deleteLearning: [.learningDelete]
        case .exportMemory: [.memoryExport]
        case .unsupported: []
        }
    }
    static func resolve(_ request: ActionRequest) throws -> ActionDescriptor {
        guard request.origin == .userInterface else { throw ActionPermissionError.untrustedOrigin }
        let descriptor: ActionDescriptor
        switch request.operation {
        case .remember(let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionPermissionError.invalidPayload
            }
            descriptor = .init(identifier: "memory.remember", summary: "Bu metni kişisel hafızaya kaydet", risk: .low, capabilities: [.memoryWrite])
        case .deleteMemory:
            descriptor = .init(identifier: "memory.delete", summary: "Seçilen kişisel hafıza kaydını kalıcı olarak sil", risk: .sensitive, capabilities: [.memoryDelete])
        case .deleteAllMemory:
            descriptor = .init(identifier: "memory.deleteAll", summary: "Tüm JARVIS konuşmalarını, önbelleği, kişisel hafızayı ve öğrenme kayıtlarını sil", risk: .high, capabilities: [.memoryDeleteAll])
        case .deleteLearning:
            descriptor = .init(identifier: "learning.delete", summary: "Seçilen öğrenme kaydını ve ilişkili eski iddialarını sil", risk: .sensitive, capabilities: [.learningDelete])
        case .exportMemory:
            descriptor = .init(identifier: "memory.export", summary: "JARVIS verilerini şifrelenmemiş JSON olarak dışa aktar", risk: .sensitive, capabilities: [.memoryExport])
        case .unsupported:
            throw ActionPermissionError.actionNotAllowed
        }
        guard request.capabilities == descriptor.capabilities else { throw ActionPermissionError.capabilityMismatch }
        return descriptor
    }
}

/// `approve` must be called only by the explicit confirmation button in trusted UI.
/// There is no automatic approval path for model/tool output. Every action uses the same
/// binding checks, and sensitive/high-risk approval additionally invokes the platform authenticator.
public actor PermissionManager {
    private struct Pending: Sendable { let request: ActionRequest; let challenge: ActionApprovalChallenge }
    private struct Authorized: Sendable { let request: ActionRequest; let expiresAt: Date }
    private let authenticator: any BiometricAuthenticator
    private let clock: @Sendable () -> Date
    private var pending: [UUID: Pending] = [:]
    private var authorized: [UUID: Authorized] = [:]
    private var generation = UUID()
    public init(authenticator: any BiometricAuthenticator = UnavailableBiometricAuthenticator(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.authenticator = authenticator; self.clock = clock
    }
    public func prepare(_ request: ActionRequest) throws -> ActionApprovalChallenge {
        let descriptor = try ActionDescriptor.resolve(request)
        purgeExpired()
        let challenge = ActionApprovalChallenge(id: UUID(), requestID: request.id,
            summary: descriptor.summary, risk: descriptor.risk, capabilities: descriptor.capabilities,
            expiresAt: clock().addingTimeInterval(60))
        pending[challenge.id] = Pending(request: request, challenge: challenge)
        return challenge
    }
    /// A challenge is consumed before any asynchronous biometric prompt, preventing reuse.
    public func approve(_ challenge: ActionApprovalChallenge) async throws -> ActionAuthorization {
        guard let approval = pending.removeValue(forKey: challenge.id) else { throw ActionPermissionError.approvalMissing }
        guard approval.challenge == challenge else { throw ActionPermissionError.requestMismatch }
        guard challenge.expiresAt > clock() else { throw ActionPermissionError.approvalExpired }
        let currentGeneration = generation
        if challenge.risk != .low {
            do { try await authenticator.authenticate(reason: challenge.summary + ". Cihaz biyometrisiyle doğrulayın.") }
            catch let error as ActionPermissionError { throw error }
            catch { throw ActionPermissionError.biometricRejected }
        }
        guard generation == currentGeneration else { throw ActionPermissionError.invalidated }
        guard challenge.expiresAt > clock() else { throw ActionPermissionError.approvalExpired }
        let token = UUID()
        authorized[token] = Authorized(request: approval.request,
            expiresAt: min(challenge.expiresAt, clock().addingTimeInterval(30)))
        return ActionAuthorization(token: token)
    }
    public func deny(_ challenge: ActionApprovalChallenge) { pending.removeValue(forKey: challenge.id) }
    /// Call when the app backgrounds, locks, logs out, or its security context changes.
    public func invalidateAll() {
        pending.removeAll(); authorized.removeAll(); generation = UUID()
    }
    func consume(_ authorization: ActionAuthorization, for request: ActionRequest) throws -> ActionDescriptor {
        guard let grant = authorized.removeValue(forKey: authorization.token) else { throw ActionPermissionError.authorizationMissing }
        guard grant.expiresAt > clock() else { throw ActionPermissionError.authorizationExpired }
        guard grant.request == request else { throw ActionPermissionError.requestMismatch }
        return try ActionDescriptor.resolve(request)
    }
    private func purgeExpired() {
        let now = clock()
        pending = pending.filter { $0.value.challenge.expiresAt > now }
        authorized = authorized.filter { $0.value.expiresAt > now }
    }
}
