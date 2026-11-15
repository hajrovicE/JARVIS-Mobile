import Foundation

/// Permission policy shared by the iOS adapter and platform-independent tests.
/// Speech authorization never grants microphone access or speaker identity verification.
public struct SpeechPermissionPolicy: Equatable, Sendable {
  public enum Authorization: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted
  }
  public enum Decision: Equatable, Sendable {
    case requestSpeech, requestMicrophone, ready, denied, restricted, unavailable
  }
  public var speech: Authorization
  public var microphone: Authorization
  public var onDeviceSupported: Bool
  public var recognizerAvailable: Bool
  public init(
    speech: Authorization, microphone: Authorization,
    onDeviceSupported: Bool, recognizerAvailable: Bool
  ) {
    self.speech = speech
    self.microphone = microphone
    self.onDeviceSupported = onDeviceSupported
    self.recognizerAvailable = recognizerAvailable
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

/// A permission result belongs to one user gesture. Releasing the gesture, backgrounding,
/// or cancelling its Task must prevent a delayed authorization callback from opening audio.
public struct SpeechCaptureGate: Equatable, Sendable {
  private var requestID: UUID?
  public init() {}
  public mutating func begin() -> UUID {
    let id = UUID()
    requestID = id
    return id
  }
  public mutating func cancel() { requestID = nil }
  public func isCurrent(_ id: UUID) -> Bool { requestID == id }
  public func canStart(_ id: UUID, taskCancelled: Bool) -> Bool {
    !taskCancelled && isCurrent(id)
  }
}
