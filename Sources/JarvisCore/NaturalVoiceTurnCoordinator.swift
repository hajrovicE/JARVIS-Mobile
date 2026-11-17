import Foundation

/// Turn permissions originate in an explicit foreground microphone start, never
/// in model text. IDs bind Speech's late/duplicate callbacks to that capture.
public struct NaturalVoiceTurnCoordinator: Sendable {
    public private(set) var conversationActive = false
    private var activeCaptureID: UUID?
    private var acceptedFinalID: UUID?
    private var resumeConsumed = true

    public init() {}

    /// Called by the UI only for a user gesture or a permitted hands-free resume.
    public mutating func beginUserCapture(id: UUID) {
        guard id != acceptedFinalID else { return }
        activeCaptureID = id
        resumeConsumed = true
    }

    public mutating func acceptFinal(id: UUID, text: String, appInForeground: Bool,
                                     isBusy: Bool, autoSend: Bool,
                                     handsFree: Bool, speakReplies: Bool) -> Bool {
        guard appInForeground, !isBusy, autoSend,
              activeCaptureID == id, acceptedFinalID != id,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        acceptedFinalID = id
        activeCaptureID = nil
        conversationActive = handsFree && speakReplies
        resumeConsumed = false
        return true
    }

    /// A response may finish speaking before generation's final bookkeeping.
    /// A busy check does not consume the permit; a later foreground check can.
    public mutating func canResumeListening(speechFinishedNaturally: Bool,
                                            appInForeground: Bool, isBusy: Bool,
                                            handsFree: Bool, autoSend: Bool,
                                            speakReplies: Bool) -> Bool {
        guard speechFinishedNaturally, conversationActive, !resumeConsumed,
              appInForeground, !isBusy, handsFree, autoSend, speakReplies else { return false }
        resumeConsumed = true
        return true
    }

    public mutating func stopConversation() {
        conversationActive = false
        activeCaptureID = nil
        resumeConsumed = true
    }
}
