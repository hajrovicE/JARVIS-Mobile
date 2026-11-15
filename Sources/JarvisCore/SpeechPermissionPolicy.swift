/// Permission policy shared by the iOS adapter and platform-independent tests.
/// Speech authorization never grants microphone access or speaker identity verification.
public struct SpeechPermissionPolicy: Equatable, Sendable {
    public enum Authorization: Equatable, Sendable { case notDetermined, authorized, denied, restricted }
    public enum Decision: Equatable, Sendable {
        case requestSpeech, requestMicrophone, ready, denied, restricted, unavailable
    }
    public var speech: Authorization
    public var microphone: Authorization
    public var onDeviceSupported: Bool
    public var recognizerAvailable: Bool
    public init(speech: Authorization, microphone: Authorization,
                onDeviceSupported: Bool, recognizerAvailable: Bool) {
        self.speech = speech; self.microphone = microphone
        self.onDeviceSupported = onDeviceSupported; self.recognizerAvailable = recognizerAvailable
    }
    public var decision: Decision {
        if speech == .restricted || microphone == .restricted { return .restricted }
        if speech == .denied || microphone == .denied { return .denied }
        if speech == .notDetermined { return .requestSpeech }
        if microphone == .notDetermined { return .requestMicrophone }
        guard onDeviceSupported && recognizerAvailable else { return .unavailable }
        return .ready
    }
}
