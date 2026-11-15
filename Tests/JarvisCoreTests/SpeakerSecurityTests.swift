import Foundation
import XCTest

@testable import JarvisCore

final class SpeakerSecurityTests: XCTestCase, @unchecked Sendable {
  func testUnavailableModuleNeverClaimsEnrollmentOrMatch() async throws {
    let module = UnavailableSpeakerSecurity()
    guard case .unavailable = await module.availability() else {
      return XCTFail("Must remain unavailable")
    }
    do {
      try await module.enroll(
        consent: .init(acceptedAt: Date(), policyVersion: "alpha-0.3"), samples: [Data([1])])
      XCTFail("Cannot enroll with an unimplemented module")
    } catch { XCTAssertEqual(error as? SpeakerSecurityError, .notImplemented) }
    do {
      _ = try await module.verify(
        challenge: .init(phrase: "örnek meydan okuma", expiresAt: Date().addingTimeInterval(60)),
        sample: Data([1]))
      XCTFail("Cannot report a match with an unimplemented module")
    } catch { XCTAssertEqual(error as? SpeakerSecurityError, .notImplemented) }
    let removed = try await module.revokeEnrollment()
    XCTAssertEqual(removed, .notEnrolled)
  }
}
