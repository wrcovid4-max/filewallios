import Foundation
import LocalAuthentication

/// Face ID / Touch ID gate for the hidden vault.
///
/// Default policy is `.deviceOwnerAuthentication` — biometrics **with device
/// passcode fallback** — so a user with no enrolled biometrics, or a failed scan,
/// can still get in with the passcode (matching the Android build's
/// device-credential fallback). The Security screen offers a "require biometrics
/// only" toggle that switches to `.deviceOwnerAuthenticationWithBiometrics`.
enum BiometricAuth {
    static func authenticate(reason: String, biometricsOnly: Bool) async -> Bool {
        let context = LAContext()
        let policy: LAPolicy = biometricsOnly
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication

        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else { return false }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
