import Foundation

/// Deterministic turn-taking policy: iOS Speech callbacks can arrive twice or
/// after backgrounding; they must not launch duplicate conversations.
/// No microphone permission is granted by this state machine.
public struct NaturalVoiceTurnCoordinator: Sendable {
    public private(set) var conversationActive = false
    private var acceptedFinalID: UUID?

    public init() {}

    public mutating func acceptFinal(id: UUID, text: String, appInForeground: Bool,
                                     isBusy: Bool, autoSend: Bool,
                                     handsFree: Bool, speakReplies: Bool) -> Bool {
        guard appInForeground, !isBusy, autoSend,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              acceptedFinalID != id else { return false }
        acceptedFinalID = id
        conversationActive = handsFree && speakReplies
        return true
    }

    /// Reopens the mic only after the *last* naturally finished utterance,
    /// never after a TTS cancel/interruption or while a response is still running.
    public mutating func canResumeListening(speechFinishedNaturally: Bool,
                                            appInForeground: Bool, isBusy: Bool,
                                            handsFree: Bool, autoSend: Bool,
                                            speakReplies: Bool) -> Bool {
        guard speechFinishedNaturally, conversationActive, appInForeground,
              !isBusy, handsFree, autoSend, speakReplies else { return false }
        return true
    }

    public mutating func stopConversation() {
        conversationActive = false
    }
}
