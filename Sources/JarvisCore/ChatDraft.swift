import Foundation

/// An in-progress draft is independent of an earlier submitted request. Async
/// replies may clear their own unchanged draft, never a newer typed/voice edit.
public struct ChatDraft: Sendable {
    public private(set) var text: String
    private var revision = UUID()

    public init(text: String = "") { self.text = text }

    public mutating func edit(_ text: String) {
        self.text = text
        revision = UUID()
    }

    public struct Submission: Sendable {
        public let text: String
        fileprivate let revision: UUID
    }

    public func submission() -> Submission { Submission(text: text, revision: revision) }

    /// Re-entering the same text after an edit is still a new draft (the ABA case).
    @discardableResult
    public mutating func complete(_ submission: Submission) -> Bool {
        guard revision == submission.revision else { return false }
        edit("")
        return true
    }
}
