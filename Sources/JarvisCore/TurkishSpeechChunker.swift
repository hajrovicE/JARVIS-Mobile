import Foundation

/// Splits a completed response into spoken phrases, without changing content.
/// The SwiftUI/AVSpeechSynthesizer frontend may enqueue the resulting utterances.
/// Works offline and never accesses private audio or external services.
public enum TurkishSpeechChunker {
    public static func chunks(_ input: String, maxCharacters: Int = 180) -> [String] {
        let limit = max(40, maxCharacters)
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Collapse spacing for speech only; never overwrite the answer stored in memory.
        let normalized = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        let characters = Array(normalized)
        let abbreviations: Set<String> = ["dr", "prof", "doç", "sn", "bkz", "örn", "vb", "vs", "say"]
        var units: [String] = []
        var start = 0

        for i in characters.indices {
            guard ".!?;:".contains(characters[i]) else { continue }
            let isFinal = i == characters.count - 1
            if !isFinal && characters[i + 1] != " " { continue }
            if characters[i] == "." {
                let left = i > 0 ? characters[i - 1] : " "
                let right = !isFinal ? characters[i + 1] : " "
                if left.isNumber && right.isNumber { continue }
                let prefix = String(characters[start..<i])
                let finalWord = prefix.split(whereSeparator: { $0 == " " }).last.map(String.init)?
                    .lowercased(with: Locale(identifier: "tr_TR")) ?? ""
                if abbreviations.contains(finalWord) { continue }
            }
            let sentence = String(characters[start...i]).trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { units.append(sentence) }
            start = i + 1
        }
        if start < characters.count {
            let tail = String(characters[start...]).trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty { units.append(tail) }
        }

        var result: [String] = []
        var buffer = ""
        for unit in units {
            if !buffer.isEmpty && buffer.count + unit.count + 1 > limit {
                result.append(buffer)
                buffer = ""
            }
            // Very long sentences: split at word boundaries without dropping words.
            if unit.count > limit {
                if !buffer.isEmpty { result.append(buffer); buffer = "" }
                for word in unit.split(separator: " ") {
                    let word = String(word)
                    if !buffer.isEmpty && buffer.count + word.count + 1 > limit {
                        result.append(buffer)
                        buffer = ""
                    }
                    if word.count > limit {
                        if !buffer.isEmpty { result.append(buffer); buffer = "" }
                        // Keep punctuation and Unicode grapheme clusters intact.
                        let chars = Array(word)
                        for offset in stride(from: 0, to: chars.count, by: limit) {
                            result.append(String(chars[offset..<min(offset + limit, chars.count)]))
                        }
                    } else {
                        buffer = buffer.isEmpty ? word : buffer + " " + word
                    }
                }
            } else {
                buffer = buffer.isEmpty ? unit : buffer + " " + unit
            }
        }
        if !buffer.isEmpty { result.append(buffer) }
        return result
    }
}

/// Incremental speech-only rendering. A trailing period is held until its
/// following character establishes a boundary; partial abbreviations, URLs,
/// decimals, thought tags and code fences cannot cause premature speech.
/// The model's stored/displayed response is not modified by this renderer.
public struct TurkishSpeechStream: Sendable {
    private var source = ""
    private var pendingSpeech = ""
    private var inThought = false
    private var inFence = false
    private var inlineDelimiter: String?
    private var finished = false
    private static let abbreviations: Set<String> = [
        "dr", "prof", "doç", "sn", "bkz", "örn", "vb", "vs", "say", "av", "müh", "no", "t.c", "s"
    ]

    public init() {}

    public mutating func append(_ delta: String) -> [String] {
        guard !finished else { return [] }
        source += delta
        renderSource(final: false)
        return readySentences(final: false)
    }

    public mutating func finish() -> [String] {
        guard !finished else { return [] }
        finished = true
        renderSource(final: true)
        var result = readySentences(final: true)
        let tail = normalized(pendingSpeech)
        pendingSpeech = ""
        if !tail.isEmpty { result += TurkishSpeechChunker.chunks(tail) }
        return result
    }

    private mutating func renderSource(final: Bool) {
        while !source.isEmpty {
            if inThought {
                if let close = source.range(of: "</think>") {
                    source.removeSubrange(..<close.upperBound)
                    inThought = false
                    pendingSpeech += " "
                } else {
                    source = final ? "" : String(source.suffix(7))
                    return
                }
                continue
            }
            if inFence {
                if let close = source.range(of: "```") {
                    source.removeSubrange(..<close.upperBound)
                    inFence = false
                    pendingSpeech += " "
                } else {
                    source = final ? "" : String(source.suffix(2))
                    return
                }
                continue
            }
            if let delimiter = inlineDelimiter {
                if let close = source.range(of: delimiter) {
                    source.removeSubrange(..<close.upperBound)
                    inlineDelimiter = nil
                    pendingSpeech += " "
                } else {
                    source = final ? "" : String(source.suffix(max(0, delimiter.count - 1)))
                    return
                }
                continue
            }
            if source.hasPrefix("<think>") {
                source.removeFirst(7); inThought = true
                continue
            }
            if source.hasPrefix("```") {
                source.removeFirst(3); inFence = true
                continue
            }
            // Hold prefixes across token boundaries. An unterminated markup
            // prefix at EOS is omitted instead of being read aloud.
            if ["<think>", "```"].contains(where: { $0.hasPrefix(source) }) {
                if final { source = "" }
                return
            }
            if source.hasPrefix("``") {
                source.removeFirst(2); inlineDelimiter = "``"
                continue
            }
            if source.hasPrefix("`") {
                source.removeFirst(); inlineDelimiter = "`"
                continue
            }
            pendingSpeech.append(source.removeFirst())
        }
    }

    private mutating func readySentences(final: Bool) -> [String] {
        let chars = Array(pendingSpeech)
        var start = 0
        var consumed = 0
        var result: [String] = []
        var index = 0
        while index < chars.count {
            defer { index += 1 }
            guard ".!?".contains(chars[index]) else { continue }
            if chars[index] == "." {
                let prefix = String(chars[start..<index])
                let word = prefix.split(whereSeparator: { $0.isWhitespace }).last.map(String.init)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“‘([{*"))
                    .lowercased(with: Locale(identifier: "tr_TR")) ?? ""
                if Self.abbreviations.contains(word) { continue }
                if word.count == 1, word.first?.isLetter == true { continue }
                if !word.isEmpty, word.count <= 2, word.allSatisfy(\.isNumber) { continue }
            }
            var end = index + 1
            while end < chars.count && ".!?\"'”’)]}".contains(chars[end]) { end += 1 }
            guard end < chars.count || final else { continue }
            guard end == chars.count || chars[end].isWhitespace else { continue }
            let sentence = normalized(String(chars[start..<end]))
            if !sentence.isEmpty { result += TurkishSpeechChunker.chunks(sentence) }
            start = end
            consumed = end
            index = end - 1
        }
        if consumed > 0 { pendingSpeech = String(chars[consumed...]) }
        return result
    }

    private func normalized(_ input: String) -> String {
        input.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Device-independent queue handshake used by SpeechController. An empty audio
/// queue while generation is still open is not a finished response.
public struct SpeechResponseQueue: Sendable {
    public enum Outcome: Equatable, Sendable {
        case ignored, waiting, completed(UUID), cancelled(UUID), empty(UUID)
    }
    public private(set) var responseID: UUID?
    private var pending: Set<UUID> = []
    private var inputFinished = false
    private var hadSpeech = false
    public var isActive: Bool { responseID != nil }
    public var hasPendingUtterances: Bool { !pending.isEmpty }

    public init() {}
    public mutating func begin() -> UUID {
        let id = UUID()
        responseID = id; pending = []; inputFinished = false; hadSpeech = false
        return id
    }
    public mutating func enqueue(responseID: UUID) -> UUID? {
        guard self.responseID == responseID, !inputFinished else { return nil }
        let id = UUID(); pending.insert(id); hadSpeech = true
        return id
    }
    public mutating func complete(utteranceID: UUID, responseID: UUID, finished: Bool) -> Outcome {
        guard self.responseID == responseID, pending.remove(utteranceID) != nil else { return .ignored }
        if !finished {
            cancel()
            return .cancelled(responseID)
        }
        return completionIfReady()
    }
    public mutating func finishInput(responseID: UUID) -> Outcome {
        guard self.responseID == responseID, !inputFinished else { return .ignored }
        inputFinished = true
        return completionIfReady()
    }
    public mutating func cancel() {
        responseID = nil; pending.removeAll(); inputFinished = false; hadSpeech = false
    }
    private mutating func completionIfReady() -> Outcome {
        guard inputFinished, pending.isEmpty, let id = responseID else { return .waiting }
        let outcome: Outcome = hadSpeech ? .completed(id) : .empty(id)
        responseID = nil
        return outcome
    }
}
