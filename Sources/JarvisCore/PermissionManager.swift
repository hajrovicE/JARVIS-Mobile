import Foundation

public enum ActionOrigin: String, Sendable { case userInterface, modelProposal }
public enum ActionCapability: String, CaseIterable, Sendable {
    case memoryWrite = "memory.write"
    case memoryDelete = "memory.delete"
    case memoryDeleteAll = "memory.deleteAll"
    case learningDelete = "learning.delete"
    case memoryExport = "memory.export"
    case memoryEdit = "memory.edit"
    case ownerCustom = "owner.custom"
}
public enum ActionOperation: Equatable, Sendable {
    case remember(String)
    case editMemory(UUID, String)
    case deleteMemory(UUID)
    case deleteAllMemory
    case deleteLearning(UUID)
    case exportMemory
    /// Extensible owner-triggered operation; an actual registered implementation is required.
    case custom(String)
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
        case .editMemory: [.memoryEdit]
        case .custom: [.ownerCustom]
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
        case .editMemory(_, let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionPermissionError.invalidPayload
            }
            descriptor = .init(identifier: "memory.edit", summary: "Seçilen hafıza kaydını güncelle", risk: .low, capabilities: [.memoryEdit])
        case .custom(let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ActionPermissionError.invalidPayload
            }
            descriptor = .init(identifier: "owner.custom", summary: "Sahibin doğrudan seçtiği kayıtlı aracı çalıştır", risk: .low, capabilities: [.ownerCustom])
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
        // Capabilities describe the operation; they are not an extra owner approval gate.
        return descriptor
    }
}

/// The only authorization condition is a present, directly issued owner command.
/// No time-to-live, second approval, biometric challenge, or scoped capability gate.
/// A bound request is consumed once so old commands cannot cause new autonomous actions.
public actor PermissionManager {
    private let clock: @Sendable () -> Date
    private var pending: [UUID: ActionRequest] = [:]
    private var authorized: [UUID: ActionRequest] = [:]

    public init(authenticator: any BiometricAuthenticator = UnavailableBiometricAuthenticator(),
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
        _ = authenticator
    }

    public func authorizeOwnerCommand(_ request: ActionRequest) throws -> ActionAuthorization {
        _ = try ActionDescriptor.resolve(request)
        let token = UUID()
        authorized[token] = request
        return ActionAuthorization(token: token)
    }

    /// Compatibility for legacy direct UI buttons: no additional approval is required.
    public func prepare(_ request: ActionRequest) throws -> ActionApprovalChallenge {
        let descriptor = try ActionDescriptor.resolve(request)
        let challenge = ActionApprovalChallenge(
            id: UUID(), requestID: request.id, summary: descriptor.summary,
            risk: descriptor.risk, capabilities: descriptor.capabilities,
            expiresAt: .distantFuture)
        pending[challenge.id] = request
        return challenge
    }

    public func approve(_ challenge: ActionApprovalChallenge) throws -> ActionAuthorization {
        guard let request = pending.removeValue(forKey: challenge.id),
              request.id == challenge.requestID else { throw ActionPermissionError.approvalMissing }
        return try authorizeOwnerCommand(request)
    }

    public func deny(_ challenge: ActionApprovalChallenge) {
        pending.removeValue(forKey: challenge.id)
    }

    public func invalidateAll() {
        pending.removeAll()
        authorized.removeAll()
    }

    func consume(_ authorization: ActionAuthorization, for request: ActionRequest) throws -> ActionDescriptor {
        guard let authorizedRequest = authorized.removeValue(forKey: authorization.token)
        else { throw ActionPermissionError.authorizationMissing }
        guard authorizedRequest == request else { throw ActionPermissionError.requestMismatch }
        return try ActionDescriptor.resolve(request)
    }
}
