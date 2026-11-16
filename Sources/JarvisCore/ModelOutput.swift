import Foundation

/// Presentation helpers for locally generated text. These never change what the
/// model is asked to do; they only decide what part of its output is shown.
public enum ModelOutput {
    /// Removes a leading `<think>…</think>` reasoning block (Qwen3-style) so only the
    /// final answer is displayed or spoken. If nothing would remain, the original
    /// text is returned instead of an empty answer.
    public static func withoutReasoning(_ text: String) -> String {
        var remaining = text[...]
        var stripped = false
        while let open = remaining.range(of: "<think>") {
            let head = remaining[..<open.lowerBound]
            if let close = remaining.range(of: "</think>", range: open.upperBound..<remaining.endIndex) {
                remaining = head + remaining[close.upperBound...]
            } else {
                // Generation stopped while still reasoning.
                remaining = head
            }
            stripped = true
        }
        guard stripped else { return text }
        let visible = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        return visible.isEmpty ? text : visible
    }
}

/// Fits a tokenized chat turn into a finite context window.
public enum PromptWindow {
    /// Returns `prefix + body + suffix`, dropping the oldest `body` tokens when the
    /// total would exceed `limit`. Returns nil when even an empty body cannot fit.
    public static func fit<Token>(prefix: [Token], body: [Token], suffix: [Token],
                                  limit: Int) -> [Token]? {
        let fixed = prefix.count + suffix.count
        guard limit > fixed else { return nil }
        let room = limit - fixed
        let kept = body.count > room ? Array(body.suffix(room)) : body
        guard !kept.isEmpty || body.isEmpty else { return nil }
        return prefix + kept + suffix
    }
}
