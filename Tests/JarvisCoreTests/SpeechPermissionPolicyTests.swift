import XCTest
@testable import JarvisCore

final class SpeechPermissionPolicyTests: XCTestCase, @unchecked Sendable {
    func testSpeechIsRequestedBeforeMicrophone() async {
        var policy = SpeechPermissionPolicy(speech: .notDetermined, microphone: .notDetermined,
                                            onDeviceSupported: true, recognizerAvailable: true)
        XCTAssertEqual(policy.decision, .requestSpeech)
        policy.speech = .authorized
        XCTAssertEqual(policy.decision, .requestMicrophone)
        policy.microphone = .authorized
        XCTAssertEqual(policy.decision, .ready)
    }
    func testDeniedAndRestrictedDoNotRequestOtherPermissions() async {
        var policy = SpeechPermissionPolicy(speech: .denied, microphone: .notDetermined,
                                            onDeviceSupported: true, recognizerAvailable: true)
        XCTAssertEqual(policy.decision, .denied)
        policy.speech = .restricted
        XCTAssertEqual(policy.decision, .restricted)
        policy.speech = .authorized; policy.microphone = .denied
        XCTAssertEqual(policy.decision, .denied)
    }
    func testAuthorizedPermissionsCannotEnableCloudFallback() async {
        var policy = SpeechPermissionPolicy(speech: .authorized, microphone: .authorized,
                                            onDeviceSupported: false, recognizerAvailable: true)
        XCTAssertEqual(policy.decision, .unavailable)
        policy.onDeviceSupported = true; policy.recognizerAvailable = false
        XCTAssertEqual(policy.decision, .unavailable)
    }
}
