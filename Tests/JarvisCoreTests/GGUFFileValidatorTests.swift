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

/// Format-only quantized blocks; these bytes are not a trained language model.
private func quantizedGGUFFixture(type: UInt32, dimensions: [UInt64],
                                  payloadBytes: Int, offset: UInt64 = 0) -> Data {
    func u32(_ value: UInt32) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    func u64(_ value: UInt64) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
    let name = Data("quantized.weight".utf8)
    var bytes = Data("GGUF".utf8) + u32(3) + u64(1) + u64(0)
    bytes += u64(UInt64(name.count)) + name + u32(UInt32(dimensions.count))
    for dimension in dimensions { bytes += u64(dimension) }
    bytes += u32(type) + u64(offset)
    while bytes.count % 32 != 0 { bytes.append(0) }
    bytes.append(contentsOf: repeatElement(UInt8(0), count: payloadBytes))
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
    func testCachedURLSizeCannotApproveARewrittenTruncatedFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owner.weights")
        let valid = quantizedGGUFFixture(type: 2, dimensions: [32, 2], payloadBytes: 36)
        try valid.write(to: file)
        _ = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        try GGUFFileValidator.validate(at: file)
        try Data(valid.dropLast()).write(to: file)
        XCTAssertThrowsError(try GGUFFileValidator.validate(at: file))
        try valid.write(to: file)
        XCTAssertNoThrow(try GGUFFileValidator.validate(at: file))
    }

    func testKnownQuantizedBlockPayloadsAndFinalTensorTruncation() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owner.weights")
        // GGML wire layouts: type, values per block, serialized bytes per block.
        // Exercise two rows so payload sizing cannot accidentally validate one block only.
        let layouts: [(UInt32, UInt64, Int)] = [
            (2, 32, 18), (3, 32, 20), (6, 32, 22), (7, 32, 24),
            (8, 32, 34), (9, 32, 36), (10, 256, 84), (11, 256, 110),
            (12, 256, 144), (13, 256, 176), (14, 256, 210), (15, 256, 292)
        ]
        for (type, row, blockBytes) in layouts {
            let valid = quantizedGGUFFixture(type: type, dimensions: [row, 2], payloadBytes: 2 * blockBytes)
            try check(valid, file: file)
            XCTAssertThrowsError(try check(Data(valid.dropLast()), file: file),
                                 "Type \(type): missing final payload byte")
            let oneByte = quantizedGGUFFixture(type: type, dimensions: [row, 2], payloadBytes: 1)
            XCTAssertThrowsError(try check(oneByte, file: file),
                                 "A single payload byte cannot stand in for a quantized tensor")
        }
    }

    func testTruncatedQuantizedReplacementPreservesInstalledModel() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("owner.weights")
        let original = quantizedGGUFFixture(type: 2, dimensions: [32], payloadBytes: 18)
        try original.write(to: source)
        let manifest = try LocalModelManifest(identifier: "owner-model", revision: "r1",
            licenseIdentifier: "owner", byteCount: 0, sha256: "")
        let manager = try OnDeviceModelManager(directory: root.appendingPathComponent("installed"))
        let installed = try await manager.importModel(from: source, manifest: manifest)
        try Data(original.dropLast()).write(to: source)
        do {
            _ = try await manager.importModel(from: source, manifest: manifest)
            XCTFail("Truncated quantized replacement must fail before replacing a model")
        } catch let error as LocalModelError {
            XCTAssertEqual(error, .invalidFile)
        }
        XCTAssertEqual(try Data(contentsOf: installed), original)
    }

    func testQuantizedRowsRequireCompleteBlocksAndUnknownTypesRemainDelegated() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owner.weights")
        // Total element count is block-aligned, but each individual row is invalid.
        XCTAssertThrowsError(try check(quantizedGGUFFixture(
            type: 2, dimensions: [16, 2], payloadBytes: 18), file: file))
        XCTAssertThrowsError(try check(quantizedGGUFFixture(
            type: 12, dimensions: [128, 2], payloadBytes: 144), file: file))
        XCTAssertThrowsError(try check(quantizedGGUFFixture(
            type: 8, dimensions: [33], payloadBytes: 68), file: file))
        // No application-owned allowlist is introduced: a future type still reaches
        // the actual inference engine, which alone can establish runtime support.
        try check(quantizedGGUFFixture(type: UInt32.max, dimensions: [1], payloadBytes: 1), file: file)
    }

    func testQuantizedShapePayloadAndOffsetOverflowAreErrorsRatherThanTraps() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("owner.weights")
        for malformed in [
            quantizedGGUFFixture(type: 2, dimensions: [0], payloadBytes: 18),
            quantizedGGUFFixture(type: 2, dimensions: [32, UInt64.max], payloadBytes: 18),
            quantizedGGUFFixture(type: 15, dimensions: [256, UInt64.max / 256], payloadBytes: 1),
            quantizedGGUFFixture(type: 2, dimensions: [64], payloadBytes: 36, offset: UInt64.max - 31)
        ] {
            XCTAssertThrowsError(try check(malformed, file: file))
        }
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
