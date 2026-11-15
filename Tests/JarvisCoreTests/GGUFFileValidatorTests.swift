import Foundation
import XCTest
@testable import JarvisCore

/// A structurally valid one-tensor fixture. It is not a usable language model and these
/// preflight tests make no inference claim; real model/runtime tests are separate.
func structuralGGUFFixture(version: UInt32 = 3, value: Float = 1) -> Data {
    func u32(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    func u64(_ value: UInt64) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    func string(_ value: String) -> Data { u64(UInt64(value.utf8.count)) + Data(value.utf8) }
    var bytes = Data("GGUF".utf8) + u32(version) + u64(1) + u64(1)
    bytes += string("general.alignment") + u32(4) + u32(32)
    bytes += string("fixture.weight") + u32(1) + u64(1) + u32(0) + u64(0)
    while bytes.count % 32 != 0 { bytes.append(0) }
    bytes += u32(value.bitPattern)
    return bytes
}

final class GGUFFileValidatorTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func check(_ bytes: Data, file: URL) throws {
        try bytes.write(to: file)
        try GGUFFileValidator.validate(at: file)
    }
    func testVersionTwoAndThreeAndArbitraryFilename() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Özel sahibin modeli.txt")
        try check(structuralGGUFFixture(version: 2), file: file)
        try check(structuralGGUFFixture(version: 3), file: file)
    }
    func testTruncatedHeadersMetadataAndTensorPayloadAreRejected() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owner.gguf")
        let valid = structuralGGUFFixture()
        for count in [4, 8, 23, 24, 31, valid.count - 1] {
            try Data(valid.prefix(count)).write(to: file)
            XCTAssertThrowsError(try GGUFFileValidator.validate(at: file), "Truncation at \(count)")
        }
        try Data("GGUFtest".utf8).write(to: file)
        XCTAssertThrowsError(try GGUFFileValidator.validate(at: file))
    }
    func testInvalidVersionAlignmentAndOverflowCountsAreRejected() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owner.weights")
        XCTAssertThrowsError(try check(structuralGGUFFixture(version: 99), file: file))
        var overflowing = structuralGGUFFixture()
        overflowing.replaceSubrange(8..<16, with: [UInt8](repeating: 255, count: 8))
        XCTAssertThrowsError(try check(overflowing, file: file))
        var invalidAlignment = structuralGGUFFixture()
        // header24 + keyLength8 + key17 + metadataType4 = alignment at53.
        invalidAlignment.replaceSubrange(53..<57, with: [3, 0, 0, 0])
        XCTAssertThrowsError(try check(invalidAlignment, file: file))
    }
    func testSymlinkAndDirectoryCannotMasqueradeAsModels() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owner")
        try structuralGGUFFixture().write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try GGUFFileValidator.validate(at: link))
        XCTAssertThrowsError(try GGUFFileValidator.validate(at: root))
    }
}
