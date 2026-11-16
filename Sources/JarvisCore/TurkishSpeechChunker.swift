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
