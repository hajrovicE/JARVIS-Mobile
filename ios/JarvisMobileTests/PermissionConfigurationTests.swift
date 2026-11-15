import XCTest

/// Hosted iOS tests inspect the application's generated Info.plist, not a test fixture.
final class PermissionConfigurationTests: XCTestCase {
    func testTurkishMicrophoneAndSpeechUsageDescriptionsArePresent() throws {
        let microphone = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String)
        let speech = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String)
        XCTAssertFalse(microphone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(speech.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(microphone.contains("Türkçe"))
        XCTAssertTrue(speech.contains("Türkçe"))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDevelopmentRegion") as? String, "tr")
    }
}
