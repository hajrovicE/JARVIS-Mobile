import Foundation

/// Bounded GGUF v2/v3 format preflight. This does not assert that an architecture or
/// quantization is supported by a runtime: llama.cpp must still load the actual model.
/// Owner filenames, provenance text, checksum and declared byteCount are not gates.
public enum GGUFFileValidator {
    public static func validate(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count >= 24 else { throw LocalModelError.invalidFile }
        let reader = try Reader(url: url, size: UInt64(count))
        defer { reader.close() }
        guard try reader.bytes(4) == Data([0x47, 0x47, 0x55, 0x46]),
              try [UInt32(2), 3].contains(reader.u32()) else { throw LocalModelError.invalidFile }
        let tensorCount = try reader.u64(), metadataCount = try reader.u64()
        // Every descriptor occupies at least these bytes; derive loop bounds from the file.
        guard metadataCount <= reader.remaining / 13,
              tensorCount <= reader.remaining / 24 else { throw LocalModelError.invalidFile }
        var alignment: UInt64 = 32
        var sawAlignment = false
        for _ in 0..<metadataCount {
            try Task.checkCancellation()
            let keyIsAlignment = try reader.isAlignmentKey()
            let type = try reader.u32()
            if keyIsAlignment {
                guard !sawAlignment, type == 4 else { throw LocalModelError.invalidFile }
                alignment = UInt64(try reader.u32()); sawAlignment = true
                guard alignment > 0, alignment.nonzeroBitCount == 1 else { throw LocalModelError.invalidFile }
            } else { try reader.value(type: type) }
        }
        guard tensorCount <= reader.remaining / 24 else { throw LocalModelError.invalidFile }
        var requiredPayload: UInt64 = 0
        for _ in 0..<tensorCount {
            try Task.checkCancellation()
            try reader.string()
            let dimensions = try reader.u32()
            // GGML_MAX_DIMS is four in the linked llama.cpp format.
            guard dimensions <= 4 else { throw LocalModelError.invalidFile }
            var elements: UInt64 = 1
            for _ in 0..<dimensions {
                let dimension = try reader.u64()
                guard dimension > 0 else { throw LocalModelError.invalidFile }
                let multiplied = elements.multipliedReportingOverflow(by: dimension)
                guard !multiplied.overflow else { throw LocalModelError.invalidFile }
                elements = multiplied.partialValue
            }
            let type = try reader.u32(), offset = try reader.u64()
            guard offset % alignment == 0 else { throw LocalModelError.invalidFile }
            // Raw scalar representations have exact sizes. Unknown/new quantizations are
            // left to the runtime rather than rejected by an app-owned format allowlist.
            let scalarBytes: UInt64?
            switch type {
            case 0, 26: scalarBytes = 4       // f32, i32
            case 1, 25, 30: scalarBytes = 2   // f16, i16, bf16
            case 24: scalarBytes = 1          // i8
            case 27, 28: scalarBytes = 8      // i64, f64
            default: scalarBytes = nil
            }
            let minimum: UInt64
            if let scalarBytes {
                let multiplied = elements.multipliedReportingOverflow(by: scalarBytes)
                guard !multiplied.overflow else { throw LocalModelError.invalidFile }
                minimum = multiplied.partialValue
            } else { minimum = 1 }
            let end = offset.addingReportingOverflow(minimum)
            guard !end.overflow else { throw LocalModelError.invalidFile }
            requiredPayload = max(requiredPayload, end.partialValue)
        }
        let remainder = reader.offset % alignment
        let padding = remainder == 0 ? 0 : alignment - remainder
        try reader.skip(padding)
        guard requiredPayload <= reader.remaining else { throw LocalModelError.invalidFile }
    }

    private final class Reader {
        let file: FileHandle
        let size: UInt64
        var offset: UInt64 = 0
        var remaining: UInt64 { size - offset }
        init(url: URL, size: UInt64) throws { file = try FileHandle(forReadingFrom: url); self.size = size }
        func close() { try? file.close() }
        func bytes(_ count: Int) throws -> Data {
            guard count >= 0, UInt64(count) <= remaining,
                  let data = try file.read(upToCount: count), data.count == count else { throw LocalModelError.invalidFile }
            offset += UInt64(count); return data
        }
        func skip(_ count: UInt64) throws {
            guard count <= remaining else { throw LocalModelError.invalidFile }
            offset += count; try file.seek(toOffset: offset)
        }
        func u32() throws -> UInt32 {
            let data = try bytes(4)
            return data.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << UInt32(8 * $1.offset) }
        }
        func u64() throws -> UInt64 {
            let data = try bytes(8)
            return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
        }
        func string() throws { let count = try u64(); try skip(count) }
        func isAlignmentKey() throws -> Bool {
            let count = try u64()
            let target = Data("general.alignment".utf8)
            if count == UInt64(target.count) { return try bytes(target.count) == target }
            try skip(count); return false
        }
        func value(type: UInt32) throws {
            switch type {
            case 0, 1: try skip(1)
            case 2, 3: try skip(2)
            case 4, 5, 6: try skip(4)
            case 7:
                guard try bytes(1)[0] <= 1 else { throw LocalModelError.invalidFile }
            case 8: try string()
            case 9:
                let element = try u32(), count = try u64()
                guard element != 9 else { throw LocalModelError.invalidFile }
                let width: UInt64
                switch element {
                case 0, 1, 7: width = 1
                case 2, 3: width = 2
                case 4, 5, 6: width = 4
                case 8, 10, 11, 12: width = 8
                default: throw LocalModelError.invalidFile
                }
                let size = count.multipliedReportingOverflow(by: width)
                guard !size.overflow, size.partialValue <= remaining else { throw LocalModelError.invalidFile }
                if element == 8 || element == 7 {
                    for _ in 0..<count { try Task.checkCancellation(); try value(type: element) }
                } else { try skip(size.partialValue) }
            case 10, 11, 12: try skip(8)
            default: throw LocalModelError.invalidFile
            }
        }
    }
}
