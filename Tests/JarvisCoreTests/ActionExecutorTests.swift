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
    func testAllowlistOriginAndExactCapabilitiesAreRequired() async throws {
        let manager = PermissionManager()
        for request in [
            ActionRequest(operation: .unsupported("shell.exec")),
            ActionRequest(operation: .remember("injected"), origin: .modelProposal),
            ActionRequest(operation: .deleteLearning(UUID()), origin: .modelProposal),
            ActionRequest(operation: .exportMemory, origin: .modelProposal),
            ActionRequest(operation: .deleteAllMemory, capabilities: [.memoryWrite]),
        ] {
            do { _ = try await manager.prepare(request); XCTFail("Untrusted/mismatched request must be rejected") }
            catch is ActionPermissionError {} catch { XCTFail("Unexpected error category") }
        }
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
    func testApprovalAndAuthorizationExpireAtExactBoundary() async throws {
        let clock = PermissionClock()
        let store = try MemoryStore(storage: ActionTestStorage())
        let manager = PermissionManager(clock: { clock.now() })
        let executor = ActionExecutor(store: store, permissions: manager)
        let request = ActionRequest(operation: .remember("time-bound"))
        let challenge = try await manager.prepare(request)
        clock.advance(60)
        do { _ = try await manager.approve(challenge); XCTFail("Challenge must expire at 60 seconds") }
        catch { XCTAssertEqual(error as? ActionPermissionError, .approvalExpired) }
        let grant = try await approved(request, by: manager)
        clock.advance(30)
        do { _ = try await executor.execute(request, authorization: grant); XCTFail("Grant must expire at 30 seconds") }
        catch { XCTAssertEqual(error as? ActionPermissionError, .authorizationExpired) }
        let state = try await store.read(); XCTAssertTrue(state.personal.isEmpty)
    }
    func testEraseFailsClosedWithoutBiometrics() async throws {
        let authenticators: [any BiometricAuthenticator] = [UnavailableBiometricAuthenticator(), TestBiometricAuthenticator(reject: true)]
        for authenticator in authenticators {
            let store = try MemoryStore(storage: ActionTestStorage())
            try await store.remember("keep")
            let manager = PermissionManager(authenticator: authenticator)
            let request = ActionRequest(operation: .deleteAllMemory)
            let challenge = try await manager.prepare(request)
            XCTAssertEqual(challenge.risk, .high)
            do { _ = try await manager.approve(challenge); XCTFail("Biometric failure must not authorize") }
            catch is ActionPermissionError {} catch { XCTFail("Unexpected error") }
            let state = try await store.read(); XCTAssertEqual(state.personal.map(\.text), ["keep"])
        }
    }
    func testSensitiveSingleDeletionAlsoRequiresBiometrics() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        try await store.remember("keep-sensitive")
        let snapshot = try await store.read()
        let id = try XCTUnwrap(snapshot.personal.first?.id)
        let manager = PermissionManager()
        let request = ActionRequest(operation: .deleteMemory(id))
        let challenge = try await manager.prepare(request)
        XCTAssertEqual(challenge.risk, .sensitive)
        do { _ = try await manager.approve(challenge); XCTFail("Sensitive deletion must require biometrics") }
        catch { XCTAssertEqual(error as? ActionPermissionError, .biometricUnavailable) }
        let unchanged = try await store.read()
        XCTAssertEqual(unchanged.personal.count, 1)
    }
    func testEraseAfterBiometricsDoesNotRecreateDeletedAuditData() async throws {
        let disk = ActionTestStorage(); let store = try MemoryStore(storage: disk)
        try await store.remember("erase")
        let authenticator = TestBiometricAuthenticator()
        let manager = PermissionManager(authenticator: authenticator)
        let request = ActionRequest(operation: .deleteAllMemory)
        let result = try await ActionExecutor(store: store, permissions: manager).execute(request,
            authorization: approved(request, by: manager))
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.auditDisposition, .notRetainedAfterErase)
        let calls = await authenticator.calls(); XCTAssertEqual(calls, 1)
        let reopened = try MemoryStore(storage: disk)
        let state = try await reopened.read(); XCTAssertEqual(state, MemorySnapshot())
    }
    func testBackgroundInvalidationCancelsOutstandingBiometricApproval() async throws {
        let authenticator = SuspendedBiometricAuthenticator()
        let manager = PermissionManager(authenticator: authenticator)
        let challenge = try await manager.prepare(ActionRequest(operation: .deleteAllMemory))
        let task = Task { try await manager.approve(challenge) }
        await authenticator.waitUntilStarted()
        await manager.invalidateAll()
        await authenticator.finish()
        do { _ = try await task.value; XCTFail("Backgrounded prompt must not create a new grant") }
        catch { XCTAssertEqual(error as? ActionPermissionError, .invalidated) }
    }
    func testExportAndLearningDeletionRequireAuthorizedBiometrics() async throws {
        let store = try MemoryStore(storage: ActionTestStorage())
        try await store.remember("exported-preference")
        let record = LearnedMemory(kind: .preference, key: "drink", text: "tea", source: .userInput,
            confidence: 1, provenance: .init(sourceID: "explicit-user"))
        try await store.proposeLearning(record)
        try await store.confirmLearning(id: record.id, expectedText: record.text)
        let authenticator = TestBiometricAuthenticator()
        let manager = PermissionManager(authenticator: authenticator)
        let executor = ActionExecutor(store: store, permissions: manager)
        let export = ActionRequest(operation: .exportMemory)
        let exported = try await executor.execute(export, authorization: approved(export, by: manager))
        XCTAssertTrue(exported.succeeded)
        let decoded = try JSONDecoder().decode(MemorySnapshot.self, from: XCTUnwrap(exported.exportedData))
        XCTAssertEqual(decoded.personal.first?.text, "exported-preference")
        XCTAssertEqual(decoded.learning.records.first?.text, "tea")
        let deletion = ActionRequest(operation: .deleteLearning(record.id))
        let removed = try await executor.execute(deletion, authorization: approved(deletion, by: manager))
        XCTAssertTrue(removed.succeeded); XCTAssertNil(removed.exportedData)
        let snapshot = try await store.read()
        XCTAssertTrue(snapshot.learning.records.isEmpty)
        let auditJSON = String(data: try JSONEncoder().encode(snapshot.learning.experiences), encoding: .utf8)!
        XCTAssertFalse(auditJSON.contains("exported-preference"))
        XCTAssertFalse(auditJSON.contains("tea"))
        let calls = await authenticator.calls(); XCTAssertEqual(calls, 2)
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
