import Foundation

public enum ActionExecutionOutcome: String, Sendable { case succeeded, failed }
public enum ActionAuditDisposition: String, Sendable {
    case persisted, writeFailed, notRetainedAfterErase
}
public struct ActionExecutionReceipt: Sendable {
    public let id: UUID
    public let requestID: UUID
    public let action: String
    public let outcome: ActionExecutionOutcome
    public let completedAt: Date
}
public struct ActionExecutionResult: Sendable {
    public let receipt: ActionExecutionReceipt
    public let auditDisposition: ActionAuditDisposition
    /// Plaintext is returned only after explicit authorization; never included in the audit.
    public let exportedData: Data?
    public init(receipt: ActionExecutionReceipt, auditDisposition: ActionAuditDisposition, exportedData: Data? = nil) {
        self.receipt = receipt; self.auditDisposition = auditDisposition; self.exportedData = exportedData
    }
    public var succeeded: Bool { receipt.outcome == .succeeded }
    public var auditWriteFailed: Bool { auditDisposition == .writeFailed }
    public var message: String {
        guard succeeded else { return "İşlem gerçekleştirilemedi. Başarı olarak kaydedilmedi." }
        if auditWriteFailed { return "İşlem tamamlandı; denetim kaydı kaydedilemedi." }
        return receipt.action == "memory.deleteAll" ? "Tüm kayıtlar silindi." : "İşlem tamamlandı."
    }
}

/// Owners may supply additional handlers without modifying the core permission cases.
/// Only current trusted owner commands receive one-time authorization.
public protocol OwnerActionHandler: Sendable {
    func executeOwnerAction(named name: String) async throws -> Data?
}

/// A registered owner's tool can run only after an exact, one-use owner request.
/// Model text and imported data never grant authorization.
public actor ActionExecutor {
    private let store: MemoryStore
    private let permissions: PermissionManager
    private let ownerActionHandler: (any OwnerActionHandler)?
    public init(store: MemoryStore, permissions: PermissionManager,
                ownerActionHandler: (any OwnerActionHandler)? = nil) {
        self.store = store; self.permissions = permissions
        self.ownerActionHandler = ownerActionHandler
    }
    public func execute(_ request: ActionRequest, authorization: ActionAuthorization) async throws -> ActionExecutionResult {
        try Task.checkCancellation()
        let descriptor = try await permissions.consume(authorization, for: request)
        try Task.checkCancellation()
        let outcome: ActionExecutionOutcome
        var exportedData: Data?
        do {
            switch request.operation {
            case .remember(let text): try await store.remember(text)
            case .editMemory(let id, let text): try await store.edit(id: id, text: text)
            case .custom(let name):
                guard let ownerActionHandler else { throw ActionPermissionError.actionNotAllowed }
                exportedData = try await ownerActionHandler.executeOwnerAction(named: name)
            case .deleteMemory(let id): try await store.forget(id: id)
            case .deleteAllMemory: try await store.deleteAll()
            case .deleteLearning(let id): try await store.deleteLearning(id: id)
            case .exportMemory: exportedData = try await store.export()
            case .unsupported: throw ActionPermissionError.actionNotAllowed
            }
            outcome = .succeeded
        } catch { outcome = .failed }
        let receipt = ActionExecutionReceipt(id: UUID(), requestID: request.id,
            action: descriptor.identifier, outcome: outcome, completedAt: Date())
        // A successful erase must remain erased. Return an in-memory receipt only;
        // persisting a new learning/audit record would recreate deleted local data.
        if request.operation == .deleteAllMemory, outcome == .succeeded {
            return ActionExecutionResult(receipt: receipt, auditDisposition: .notRetainedAfterErase)
        }
        let audit = TaskExperience(action: descriptor.identifier,
            permissionScope: descriptor.capabilities.map(\.rawValue).sorted(), risk: descriptor.risk,
            outcome: outcome == .succeeded ? .succeeded : .failed,
            result: outcome == .succeeded ? "completed" : nil,
            error: outcome == .failed ? "operation_failed" : nil,
            executionReceipt: outcome == .succeeded ? receipt.id.uuidString : nil,
            createdAt: receipt.completedAt)
        do {
            try await store.recordExperience(audit)
            return ActionExecutionResult(receipt: receipt, auditDisposition: .persisted, exportedData: exportedData)
        } catch {
            // The effect may already have happened. Never claim it was rolled back or
            // repeat the side effect automatically just because its audit write failed.
            return ActionExecutionResult(receipt: receipt, auditDisposition: .writeFailed, exportedData: exportedData)
        }
    }
}
