import Foundation
import XCTest
@testable import JarvisCore

private final class PermissionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 2_000_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}
private actor TestBiometricAuthenticator: BiometricAuthenticator {
    private let reject: Bool
    private var count = 0
    init(reject: Bool = false) { self.reject = reject }
    func authenticate(reason: String) async throws {
        count += 1
        if reject { throw ActionPermissionError.biometricRejected }
    }
    func calls() -> Int { count }
}
private actor SuspendedBiometricAuthenticator: BiometricAuthenticator {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Void, Never>?
    func authenticate(reason: String) async throws {
        started = true; startWaiter?.resume(); startWaiter = nil
        await withCheckedContinuation { completion = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func finish() { completion?.resume(); completion = nil }
}
private final class ActionTestStorage: SnapshotStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var saves = 0
    private let failOnSave: Int?
    init(failOnSave: Int? = nil) { self.failOnSave = failOnSave }
    func load() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func save(_ value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        saves += 1
        if saves == failOnSave { throw CocoaError(.fileWriteUnknown) }
        data = value
    }
}

private actor CustomOwnerHandler: OwnerActionHandler {
    private var calls: [String] = []
    func executeOwnerAction(named name: String) async throws -> Data? {
        calls.append(name)
        return Data("owner-success".utf8)
    }
    func invocations() -> [String] { calls }
}

final class ActionExecutorTests: XCTestCase, @unchecked Sendable {
    private func approved(_ request: ActionRequest, by manager: PermissionManager) async throws -> ActionAuthorization {
        let challenge = try await manager.prepare(request)
        return try await manager.approve(challenge)
    }
    func testOnlyLiveOwnerOriginIsRequired() async throws {
        let manager = PermissionManager()
        for request in [
            ActionRequest(operation: .remember("injected"), origin: .modelProposal),
            ActionRequest(operation: .deleteLearning(UUID()), origin: .modelProposal),
            ActionRequest(operation: .exportMemory, origin: .modelProposal),
            ActionRequest(operation: .custom("tool"), origin: .modelProposal)
        ] {
            do { _ = try await manager.authorizeOwnerCommand(request); XCTFail("Model must not act") }
            catch { XCTAssertEqual(error as? ActionPermissionError, .untrustedOrigin) }
        }
        let userRequest = ActionRequest(operation: .deleteAllMemory, capabilities: [.memoryWrite])
        _ = try await manager.authorizeOwnerCommand(userRequest)
    }

    func testOwnerCommandExecutesWithoutBiometricsOrSecondApproval() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        let manager = PermissionManager()
        let executor = ActionExecutor(store: store, permissions: manager)
        let remember = ActionRequest(operation: .remember("owner directive"))
        let grant = try await manager.authorizeOwnerCommand(remember)
        let savedResult = try await executor.execute(remember, authorization: grant)
        XCTAssertTrue(savedResult.succeeded)
        let saved = try await store.read()
        XCTAssertEqual(saved.personal.map(\.text), ["owner directive"])
        let erase = ActionRequest(operation: .deleteAllMemory)
        let eraseGrant = try await manager.authorizeOwnerCommand(erase)
        let eraseResult = try await executor.execute(erase, authorization: eraseGrant)
        XCTAssertTrue(eraseResult.succeeded)
        let empty = try await store.read()
        XCTAssertEqual(empty, MemorySnapshot())
    }
    func testOnlyOwnerCommandsCanUseImmediatePath() async throws {
        let manager = PermissionManager()
        for request in [
            ActionRequest(operation: .deleteAllMemory, origin: .modelProposal),
            ActionRequest(operation: .remember("injection"), origin: .modelProposal),
            ActionRequest(operation: .unsupported("shell.exec"))
        ] {
            do {
                _ = try await manager.authorizeOwnerCommand(request)
                XCTFail("Untrusted request obtained command authority")
            } catch is ActionPermissionError {}
        }
        let first = ActionRequest(operation: .remember("first"))
        let second = ActionRequest(id: first.id, operation: .remember("modified"))
        let token = try await manager.authorizeOwnerCommand(first)
        let store = try MemoryStore(storage: ActionTestStorage())
        let executor = ActionExecutor(store: store, permissions: manager)
        do { _ = try await executor.execute(second, authorization: token); XCTFail("Payload substitution") }
        catch { XCTAssertEqual(error as? ActionPermissionError, .requestMismatch) }
        do { _ = try await executor.execute(first, authorization: token); XCTFail("Replay") }
        catch { XCTAssertEqual(error as? ActionPermissionError, .authorizationMissing) }
    }

    func testApprovedLocalWriteHasReceiptAndRedactedAudit() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        let manager = PermissionManager()
        let executor = ActionExecutor(store: store, permissions: manager)
        let request = ActionRequest(operation: .remember("private-preference"))
        let grant = try await approved(request, by: manager)
        let result = try await executor.execute(request, authorization: grant)
        XCTAssertTrue(result.succeeded); XCTAssertFalse(result.auditWriteFailed)
        let state = try await store.read()
        XCTAssertEqual(state.personal.map(\.text), ["private-preference"])
        XCTAssertEqual(state.learning.experiences.count, 1)
        let audit = state.learning.experiences[0]
        XCTAssertEqual(audit.action, "memory.remember")
        XCTAssertEqual(audit.outcome, .succeeded)
        XCTAssertEqual(audit.executionReceipt, result.receipt.id.uuidString)
        XCTAssertFalse(String(data: try JSONEncoder().encode(audit), encoding: .utf8)!.contains("private-preference"))
        do { _ = try await executor.execute(request, authorization: grant); XCTFail("Replay must fail") }
        catch { XCTAssertEqual(error as? ActionPermissionError, .authorizationMissing) }
        let after = try await store.read(); XCTAssertEqual(after.personal.count, 1)
    }
    func testDenyAndPayloadMismatchNeverExecute() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        let manager = PermissionManager()
        let executor = ActionExecutor(store: store, permissions: manager)
        let request = ActionRequest(operation: .remember("approved-text"))
        let denied = try await manager.prepare(request)
        await manager.deny(denied)
        do { _ = try await manager.approve(denied); XCTFail("Denied challenge must not approve") }
        catch { XCTAssertEqual(error as? ActionPermissionError, .approvalMissing) }
        let grant = try await approved(request, by: manager)
        let different = ActionRequest(id: request.id, operation: .remember("different-text"))
        do { _ = try await executor.execute(different, authorization: grant); XCTFail("Payload change must fail") }
        catch { XCTAssertEqual(error as? ActionPermissionError, .requestMismatch) }
        do { _ = try await executor.execute(request, authorization: grant); XCTFail("Failed binding check consumes token") }
        catch { XCTAssertEqual(error as? ActionPermissionError, .authorizationMissing) }
        let state = try await store.read(); XCTAssertTrue(state.personal.isEmpty)
    }
    func testOwnerRequestDoesNotExpireAtArbitraryTimeBoundary() async throws {
        let clock = PermissionClock()
        let store = try MemoryStore(storage: ActionTestStorage())
        let manager = PermissionManager(clock: { clock.now() })
        let executor = ActionExecutor(store: store, permissions: manager)
        let request = ActionRequest(operation: .remember("time-unrestricted"))
        let challenge = try await manager.prepare(request)
        clock.advance(86_400)
        let authorization = try await manager.approve(challenge)
        clock.advance(86_400)
        let result = try await executor.execute(request, authorization: authorization)
        XCTAssertTrue(result.succeeded)
        let state = try await store.read()
        XCTAssertEqual(state.personal.first?.text, "time-unrestricted")
    }

    func testOwnerEraseDoesNotRequireBiometrics() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        try await store.remember("keep")
        let manager = PermissionManager(authenticator: UnavailableBiometricAuthenticator())
        let request = ActionRequest(operation: .deleteAllMemory)
        let grant = try await manager.authorizeOwnerCommand(request)
        let result = try await ActionExecutor(store: store, permissions: manager)
            .execute(request, authorization: grant)
        XCTAssertTrue(result.succeeded)
        let state = try await store.read()
        XCTAssertTrue(state.personal.isEmpty)
    }

    func testOwnerSingleDeletionWithoutBiometrics() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        try await store.remember("keep-sensitive")
        let before = try await store.read()
        let id = try XCTUnwrap(before.personal.first?.id)
        let manager = PermissionManager()
        let request = ActionRequest(operation: .deleteMemory(id))
        let grant = try await manager.authorizeOwnerCommand(request)
        let result = try await ActionExecutor(store: store, permissions: manager)
            .execute(request, authorization: grant)
        XCTAssertTrue(result.succeeded)
    }

    func testOwnerEraseLeavesNoAuditData() async throws {
        let disk = ActionTestStorage()
        let store = try MemoryStore(storage: disk)
        try await store.remember("erase")
        let manager = PermissionManager()
        let request = ActionRequest(operation: .deleteAllMemory)
        let grant = try await manager.authorizeOwnerCommand(request)
        let result = try await ActionExecutor(store: store, permissions: manager)
            .execute(request, authorization: grant)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.auditDisposition, .notRetainedAfterErase)
        let reopened = try MemoryStore(storage: disk)
        let state = try await reopened.read()
        XCTAssertEqual(state, MemorySnapshot())
    }

    func testBackgroundInvalidationDiscardsPreviousOwnerRequest() async throws {
        let manager = PermissionManager()
        let request = ActionRequest(operation: .deleteAllMemory)
        let token = try await manager.authorizeOwnerCommand(request)
        await manager.invalidateAll()
        let store = try MemoryStore(storage: ActionTestStorage())
        do {
            _ = try await ActionExecutor(store: store, permissions: manager)
                .execute(request, authorization: token)
            XCTFail("A previous request must not become autonomous")
        } catch {
            XCTAssertEqual(error as? ActionPermissionError, .authorizationMissing)
        }
    }

    func testDirectOwnerExportAndLearningDeletionWithoutBiometrics() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        try await store.remember("exported-preference")
        let record = LearnedMemory(kind: .preference, key: "drink", text: "tea",
                                   source: .userInput, confidence: 1,
                                   provenance: .init(sourceID: "explicit-user"))
        try await store.proposeLearning(record)
        try await store.confirmLearning(id: record.id, expectedText: record.text)
        let manager = PermissionManager()
        let executor = ActionExecutor(store: store, permissions: manager)
        let export = ActionRequest(operation: .exportMemory)
        let exported = try await executor.execute(
            export, authorization: await manager.authorizeOwnerCommand(export))
        XCTAssertTrue(exported.succeeded)
        let decoded = try JSONDecoder().decode(MemorySnapshot.self, from: XCTUnwrap(exported.exportedData))
        XCTAssertEqual(decoded.personal.first?.text, "exported-preference")
        let removal = ActionRequest(operation: .deleteLearning(record.id))
        let result = try await executor.execute(
            removal, authorization: await manager.authorizeOwnerCommand(removal))
        XCTAssertTrue(result.succeeded)
        let state = try await store.read()
        XCTAssertTrue(state.learning.records.isEmpty)
    }

    func testEffectFailureNeverReportsSuccessAndAuditFailureIsSeparate() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        let manager = PermissionManager(authenticator: TestBiometricAuthenticator())
        let request = ActionRequest(operation: .deleteMemory(UUID()))
        let failed = try await ActionExecutor(store: store, permissions: manager).execute(request,
            authorization: approved(request, by: manager))
        XCTAssertFalse(failed.succeeded)
        let state = try await store.read()
        XCTAssertEqual(state.learning.experiences.first?.outcome, .failed)
        XCTAssertNil(state.learning.experiences.first?.executionReceipt)

        // Initial snapshot -> effect -> audit: only the third write fails.
        let disk = ActionTestStorage(failOnSave: 3)
        let other = try MemoryStore(storage: disk)
        let write = ActionRequest(operation: .remember("completed-before-audit-failure"))
        let completed = try await ActionExecutor(store: other, permissions: manager).execute(write,
            authorization: approved(write, by: manager))
        XCTAssertTrue(completed.succeeded); XCTAssertTrue(completed.auditWriteFailed)
        let persisted = try await other.read()
        XCTAssertEqual(persisted.personal.count, 1)
        XCTAssertTrue(persisted.learning.experiences.isEmpty)
    }
    func testOwnerCanEditMemoryByDirectCommandWithoutSecondApproval() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        try await store.remember("İlk not")
        let initial = try await store.read()
        let id = try XCTUnwrap(initial.personal.first?.id)
        let manager = PermissionManager()
        let edit = ActionRequest(operation: .editMemory(id, "Sahibin düzelttiği metin"))
        let authorization = try await manager.authorizeOwnerCommand(edit)
        let result = try await ActionExecutor(store: store, permissions: manager)
            .execute(edit, authorization: authorization)
        XCTAssertTrue(result.succeeded)
        let current = try await store.read()
        XCTAssertEqual(current.personal.first?.text, "Sahibin düzelttiği metin")
        XCTAssertEqual(CommandRouter.ownerAction(
            for: "düzenle \(id.uuidString) = Yeni bilgi"), .editMemory(id, "Yeni bilgi"))
    }

    func testOwnerProvidedToolHandlerCanRunWithoutCentralToolAllowlist() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        let manager = PermissionManager()
        let handler = CustomOwnerHandler()
        let executor = ActionExecutor(store: store, permissions: manager,
                                      ownerActionHandler: handler)
        let action = ActionRequest(operation: .custom("user-tool.example"))
        let grant = try await manager.authorizeOwnerCommand(action)
        let result = try await executor.execute(action, authorization: grant)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.exportedData, Data("owner-success".utf8))
        let calls = await handler.invocations()
        XCTAssertEqual(calls, ["user-tool.example"])
        do {
            _ = try await executor.execute(action, authorization: grant)
            XCTFail("A direct owner command may run only once")
        } catch { XCTAssertEqual(error as? ActionPermissionError, .authorizationMissing) }
        do {
            _ = try await manager.authorizeOwnerCommand(
                ActionRequest(operation: .custom("user-tool.example"), origin: .modelProposal))
            XCTFail("Model may not authorize a tool")
        } catch { XCTAssertEqual(error as? ActionPermissionError, .untrustedOrigin) }
    }

    func testMissingOwnerToolHandlerNeverFakesSuccessfulOperation() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        let manager = PermissionManager()
        let request = ActionRequest(operation: .custom("not-yet-connected"))
        let authorization = try await manager.authorizeOwnerCommand(request)
        let result = try await ActionExecutor(store: store, permissions: manager)
            .execute(request, authorization: authorization)
        XCTAssertFalse(result.succeeded)
        let state = try await store.read()
        XCTAssertEqual(state.learning.experiences.last?.outcome, .failed)
    }

}
