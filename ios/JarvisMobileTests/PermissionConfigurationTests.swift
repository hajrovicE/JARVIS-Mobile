import AVFoundation
import XCTest
@testable import JarvisMobile

/// Hosted iOS tests inspect the application's generated Info.plist, not a test fixture.
final class PermissionConfigurationTests: XCTestCase {
    func testTurkishMicrophoneAndSpeechUsageDescriptionsArePresent() throws {
        let microphone = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String)
        let speech = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String)
        XCTAssertFalse(microphone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(microphone.contains("Türkçe"))
        XCTAssertTrue(speech.contains("Türkçe"))
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription"))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDevelopmentRegion") as? String, "tr")
    }

    @MainActor
    func testSpeechOutputDelegateDistinguishesCompletionFromCancellation() {
        let events = SpeechOutputEvents()
        let delegate = SpeechOutputDelegate { id, finished in events.record(id, finished: finished) }
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: "Türkçe test")
        // Invoke the real adapter callbacks without producing audio or requesting permissions.
        delegate.speechSynthesizer(synthesizer, didFinish: utterance)
        delegate.speechSynthesizer(synthesizer, didCancel: utterance)
        XCTAssertEqual(events.finishedValues, [true, false])
        XCTAssertEqual(events.identities, [ObjectIdentifier(utterance), ObjectIdentifier(utterance)])
    }
}

private final class SpeechOutputEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(ObjectIdentifier, Bool)] = []
    func record(_ id: ObjectIdentifier, finished: Bool) {
        lock.lock(); defer { lock.unlock() }
        events.append((id, finished))
    }
    var finishedValues: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return events.map { $0.1 }
    }
    var identities: [ObjectIdentifier] {
        lock.lock(); defer { lock.unlock() }
        return events.map { $0.0 }
    }
}
