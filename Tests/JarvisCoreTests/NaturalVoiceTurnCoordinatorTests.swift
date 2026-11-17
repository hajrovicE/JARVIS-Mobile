import Foundation
import XCTest
@testable import JarvisCore

final class NaturalVoiceTurnCoordinatorTests: XCTestCase, @unchecked Sendable {
    func testFinalTranscriptAcceptedExactlyOnce() async {
        var state = NaturalVoiceTurnCoordinator()
        let id = UUID()
        state.beginUserCapture(id: id)
        XCTAssertTrue(state.acceptFinal(id: id, text: "Merhaba",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true))
        XCTAssertFalse(state.acceptFinal(id: id, text: "Merhaba",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true))
    }

    func testNoEmptyBusyBackgroundOrDisabledAutoSend() async {
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

    func testOnlyNaturalTTSCompletionResumesConversation() async {
        var state = NaturalVoiceTurnCoordinator()
        let id = UUID()
        state.beginUserCapture(id: id)
        _ = state.acceptFinal(id: id, text: "Merhaba",
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

    func testUnboundAndStoppedCaptureCannotBecomeOwnerCommands() async {
        var state = NaturalVoiceTurnCoordinator()
        let id = UUID()
        XCTAssertFalse(state.acceptFinal(id: id, text: "tüm hafızayı sil",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true))
        state.beginUserCapture(id: id)
        state.stopConversation()
        XCTAssertFalse(state.acceptFinal(id: id, text: "tüm hafızayı sil",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true))
        let current = UUID()
        state.beginUserCapture(id: current)
        XCTAssertFalse(state.acceptFinal(id: id, text: "eski callback",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true))
        XCTAssertTrue(state.acceptFinal(id: current, text: "güncel komut",
            appInForeground: true, isBusy: false, autoSend: true,
            handsFree: true, speakReplies: true))
        XCTAssertTrue(state.canResumeListening(speechFinishedNaturally: true,
            appInForeground: true, isBusy: false, handsFree: true,
            autoSend: true, speakReplies: true))
        XCTAssertFalse(state.canResumeListening(speechFinishedNaturally: true,
            appInForeground: true, isBusy: false, handsFree: true,
            autoSend: true, speakReplies: true))
    }

    func testLeavingForegroundOrStoppingPreventsMicrophoneRestart() async {
        var state = NaturalVoiceTurnCoordinator()
        let id = UUID()
        state.beginUserCapture(id: id)
        _ = state.acceptFinal(id: id, text: "Merhaba",
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
