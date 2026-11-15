import Foundation
import LocalAuthentication
import JarvisCore

/// Device biometrics are independent from Turkish Speech and speaker identity.
/// No passcode fallback or caller-provided biometric-success flag is accepted.
struct DeviceBiometricAuthenticator: BiometricAuthenticator {
    func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw ActionPermissionError.biometricUnavailable
        }
        do {
            let accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                                           localizedReason: reason)
            guard accepted else { throw ActionPermissionError.biometricRejected }
        } catch { throw ActionPermissionError.biometricRejected }
    }
}
