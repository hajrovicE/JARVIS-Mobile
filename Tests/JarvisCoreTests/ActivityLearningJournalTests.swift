import Foundation
import XCTest
@testable import JarvisCore

private final class ActivityMemoryDisk: SnapshotStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    var shouldFail = false

    func load() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func save(_ value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        data = value
    }
}

final class ActivityLearningJournalTests: XCTestCase, @unchecked Sendable {
    private let t0 = Date(timeIntervalSince1970: 2_000_000_000)

    func testDisabledByDefaultAndOnlyOptInRecordsEvents() async throws {
        let disk = ActivityMemoryDisk()
        let journal = try ActivityLearningJournal(storage: disk, now: t0)
        try await journal.record(.typedCommand, at: t0)
        let beforeOptIn = try await journal.read(now: t0)
        XCTAssertTrue(beforeOptIn.observations.isEmpty)
        try await journal.setEnabled(true, now: t0)
        try await journal.record(.typedCommand, at: t0)
        let afterEnable = try await journal.read(now: t0)
        XCTAssertEqual(afterEnable.observations.count, 1)
        try await journal.setEnabled(false, now: t0)
        try await journal.record(.voiceInputFinished, at: t0)
        let afterDisable = try await journal.read(now: t0)
        XCTAssertEqual(afterDisable.observations.count, 1)
    }

    func testPersistenceAndCompleteErasure() async throws {
        let disk = ActivityMemoryDisk()
        let first = try ActivityLearningJournal(storage: disk, now: t0)
        try await first.setEnabled(true, now: t0)
        try await first.record(.learningProposed, at: t0)
        let second = try ActivityLearningJournal(storage: disk, now: t0)
        let before = try await second.read(now: t0)
        XCTAssertTrue(before.enabled)
        XCTAssertEqual(before.observations.map(\.kind), [.learningProposed])
        try await second.erase()
        let third = try ActivityLearningJournal(storage: disk, now: t0)
        let cleared = try await third.read(now: t0)
        XCTAssertFalse(cleared.enabled)
        XCTAssertTrue(cleared.observations.isEmpty)
    }

    func testObservationsPersistUntilExplicitErasure() async throws {
        let disk = ActivityMemoryDisk()
        let old = t0.addingTimeInterval(-30 * 86400)
        let recent = old.addingTimeInterval(1)
        let journal = try ActivityLearningJournal(storage: disk, now: old)
        try await journal.setEnabled(true, now: old)
        try await journal.record(.typedCommand, at: old)
        try await journal.record(.voiceInputFinished, at: recent)
        let visible = try await journal.read(now: t0)
        XCTAssertEqual(visible.observations.map(\.kind), [.typedCommand, .voiceInputFinished])
        let stillThere = try await journal.read(now: t0.addingTimeInterval(2))
        XCTAssertEqual(stillThere.observations.count, 2)
    }

    func testNoObservationCountCapAndNoFreeFormPayload() async throws {
        let journal = try ActivityLearningJournal(storage: ActivityMemoryDisk(), now: t0)
        try await journal.setEnabled(true, now: t0)
        for i in 0..<1_020 {
            try await journal.record(.typedCommand, at: t0.addingTimeInterval(Double(i)))
        }
        let snapshot = try await journal.read(now: t0.addingTimeInterval(1_020))
        XCTAssertEqual(snapshot.observations.count, 1_020)
        let data = try JSONEncoder().encode(snapshot)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("password"))
        XCTAssertFalse(encoded.contains("prompt"))
        XCTAssertFalse(encoded.contains("screen"))
    }

    func testInsightsNeedRepeatedEvidenceAndAreNotAutoApproved() async throws {
        let journal = try ActivityLearningJournal(storage: ActivityMemoryDisk(), now: t0)
        try await journal.setEnabled(true, now: t0)
        for _ in 0..<4 { try await journal.record(.voiceInputFinished, at: t0) }
        let tooEarly = try await journal.insights(now: t0)
        XCTAssertTrue(tooEarly.isEmpty)
        try await journal.record(.voiceInputFinished, at: t0)
        let insights = try await journal.insights(now: t0)
        XCTAssertEqual(insights.count, 1)
        XCTAssertEqual(insights.first?.id, "input.voice")
        XCTAssertEqual(insights.first?.evidenceCount, 5)
        // ActivityInsight has no userConfirmed field and no execution capability.
    }

    func testFailedDiskWriteCannotTurnOnCollectionOrPersistAnEvent() async throws {
        let disk = ActivityMemoryDisk()
        let journal = try ActivityLearningJournal(storage: disk, now: t0)
        disk.shouldFail = true
        do { try await journal.setEnabled(true, now: t0); XCTFail("Write must fail") }
        catch {}
        disk.shouldFail = false
        let afterFailedEnable = try await journal.read(now: t0)
        XCTAssertFalse(afterFailedEnable.enabled)
        try await journal.setEnabled(true, now: t0)
        disk.shouldFail = true
        do { try await journal.record(.typedCommand, at: t0); XCTFail("Write must fail") }
        catch {}
        disk.shouldFail = false
        let afterFailedRecord = try await journal.read(now: t0)
        XCTAssertTrue(afterFailedRecord.observations.isEmpty)
    }
}
