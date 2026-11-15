import Foundation

/// Speaker matching is informational. It never creates an action-approval or a device-
/// biometric credential; PermissionManager requires independent device authentication.
public enum SpeakerSecurityAvailability: Equatable, Sendable {
  case unavailable(reason: String)
  case notEnrolled
  case available
  case lockedOut
}
public struct SpeakerEnrollmentConsent: Equatable, Sendable {
  public let acceptedAt: Date
  public let policyVersion: String
  public init(acceptedAt: Date, policyVersion: String) {
    self.acceptedAt = acceptedAt
    self.policyVersion = policyVersion
  }
}
public struct SpeakerChallenge: Equatable, Sendable {
  public let id: UUID
  public let phrase: String
  public let expiresAt: Date
  public init(id: UUID = UUID(), phrase: String, expiresAt: Date) {
    self.id = id
    self.phrase = phrase
    self.expiresAt = expiresAt
  }
}
public enum SpeakerMatchResult: Equatable, Sendable {
  case matched, rejected, unavailable, lockedOut
}
public enum SpeakerRevocationResult: Equatable, Sendable { case removed, notEnrolled }
public enum SpeakerSecurityError: Error, Equatable { case notImplemented }

public protocol SpeakerSecurity: Sendable {
  func availability() async -> SpeakerSecurityAvailability
  func enroll(consent: SpeakerEnrollmentConsent, samples: [Data]) async throws
  func verify(challenge: SpeakerChallenge, sample: Data) async throws -> SpeakerMatchResult
  func revokeEnrollment() async throws -> SpeakerRevocationResult
}

/// Alpha 0.3 intentionally has no voice biometrics implementation. It neither collects
/// nor stores submitted samples and cannot report a successful enrollment or match.
public struct UnavailableSpeakerSecurity: SpeakerSecurity {
  public init() {}
  public func availability() async -> SpeakerSecurityAvailability {
    .unavailable(
      reason: "Konuşmacı kimlik doğrulaması etkin değil; doğrulanmış biyometrik modül henüz yok.")
  }
  public func enroll(consent: SpeakerEnrollmentConsent, samples: [Data]) async throws {
    throw SpeakerSecurityError.notImplemented
  }
  public func verify(challenge: SpeakerChallenge, sample: Data) async throws -> SpeakerMatchResult {
    throw SpeakerSecurityError.notImplemented
  }
  public func revokeEnrollment() async throws -> SpeakerRevocationResult { .notEnrolled }
}
