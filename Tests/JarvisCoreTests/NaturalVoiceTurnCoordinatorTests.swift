import Foundation
import XCTest
@testable import JarvisCore

final class NaturalVoiceTurnCoordinatorTests: XCTestCase {
    func testFinalTranscriptAcceptedExactlyOnce() {
        var state = NaturalVoiceTurnCoordinator()
        let id = UUID()
        XCTAssertTrue(state.acceptFinal(id: id, text: "Merhaba",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true))
        XCTAssertFalse(state.acceptFinal(id: id, text: "Merhaba",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true))
    }

    func testNoEmptyBusyBackgroundOrDisabledAutoSend() {
        var state = NaturalVoiceTurnCoordinator()
        XCTAssertFalse(state.acceptFinal(id: UUID(), text: " ",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true))
        XCTAssertFalse(state.acceptFinal(id: UUID(), text: "Merhaba",
            appInForeground: false, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true))
        XCTAssertFalse(state.acceptFinal(id: UUID(), text: "Merhaba",
            appInForeground: true, isBusy: true, autoSend: true,
            handsFree: true, speakReplies: true))
        XCTAssertFalse(state.acceptFinal(id: UUID(), text: "Merhaba",
            appInForeground: true, isBusy: false, autoSend: false,
            handsFree: true, speakReplies: true))
    }

    func testOnlyNaturalTTSCompletionResumesConversation() {
        var state = NaturalVoiceTurnCoordinator()
        _ = state.acceptFinal(id: UUID(), text: "Merhaba",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true)
        XCTAssertFalse(state.canResumeListening(speechFinishedNaturally: false,
            appInForeground: true, isBusy: false, handsFree: true,
            autoSend: true, speakReplies: true))
        XCTAssertFalse(state.canResumeListening(speechFinishedNaturally: true,
            appInForeground: true, isBusy: true, handsFree: true,
            autoSend: true, speakReplies: true))
        XCTAssertTrue(state.canResumeListening(speechFinishedNaturally: true,
            appInForeground: true, isBusy: false, handsFree: true,
            autoSend: true, speakReplies: true))
    }

    func testLeavingForegroundOrStoppingPreventsMicrophoneRestart() {
        var state = NaturalVoiceTurnCoordinator()
        _ = state.acceptFinal(id: UUID(), text: "Merhaba",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true)
        XCTAssertFalse(state.canResumeListening(speechFinishedNaturally: true,
            appInForeground: false, isBusy: false, handsFree: true,
            autoSend: true, speakReplies: true))
        state.stopConversation()
        XCTAssertFalse(state.canResumeListening(speechFinishedNaturally: true,
            appInForeground: true, isBusy: false, handsFree: true,
            autoSend: true, speakReplies: true))
    }
}
