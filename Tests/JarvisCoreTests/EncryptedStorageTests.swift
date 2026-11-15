import Foundation
import XCTest
@testable import JarvisCore

final class PlainStorageTests: XCTestCase, @unchecked Sendable {
    private func fixture() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        return (directory, directory.appendingPathComponent("memory.json"))
    }

    func testOwnerMemoryIsStoredAsPlainJSONWithoutKeychain() throws {
        let (directory, url) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try PlainFileStorage(url: url)
        let text = Data("{\"value\":\"owner-history\"}".utf8)
        try storage.save(text)
        XCTAssertEqual(try storage.load(), text)
        XCTAssertEqual(try Data(contentsOf: url), text)
        let reopened = try PlainFileStorage(url: url)
        XCTAssertEqual(try reopened.load(), text)
        try reopened.save(Data("{\"value\":2}".utf8))
        XCTAssertEqual(try storage.load(), Data("{\"value\":2}".utf8))
    }

    func testOwnerMemoryStorePersistsWithPlainStorageAndCanBeErased() async throws {
        let (directory, url) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MemoryStore(storage: PlainFileStorage(url: url))
        try await store.remember("yerel veri")
        try await store.record("konuşma")
        let state = try await store.read()
        XCTAssertEqual(state.personal.first?.text, "yerel veri")
        let persisted = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(persisted.contains("yerel veri"))
        let reopened = try MemoryStore(storage: PlainFileStorage(url: url))
        let copy = try await reopened.read()
        XCTAssertEqual(copy.personal.first?.text, "yerel veri")
        try await reopened.deleteAll()
        let empty = try MemoryStore(storage: PlainFileStorage(url: url))
        let snapshot = try await empty.read()
        XCTAssertEqual(snapshot, MemorySnapshot())
    }

    func testPlainStorageNoLongerRequiresDeviceKeychainAccount() throws {
        let (directory, url) = fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try PlainFileStorage(url: url)
        XCTAssertNil(try disk.load())
        try disk.save(Data("direct".utf8))
        XCTAssertEqual(try disk.load(), Data("direct".utf8))
    }
}
