import SwiftUI
import FileWallKit

/// App-wide UI state that isn't tied to one screen: the hidden-vault lock, and
/// the "obscure the screen" flags for the app switcher / screen recording.
@MainActor
final class AppState: ObservableObject {
    /// True only while the user has passed biometrics this session. Reset on
    /// background — the vault locks on backgrounding regardless of any timer.
    @Published var hiddenUnlocked = false

    /// Blur the whole UI: set while the app is inactive (so the app-switcher
    /// snapshot shows nothing) and while the screen is being captured/mirrored.
    @Published var isObscured = false

    /// One-shot alert after the user takes a screenshot of vault content — iOS
    /// can't block it, so we tell them plainly that a copy now exists in Photos.
    @Published var showScreenshotAlert = false

    /// "Require biometrics only" — switches the hidden-vault policy from
    /// biometrics-with-passcode-fallback to biometrics-only. Persisted.
    var biometricsOnly: Bool {
        get { UserDefaults.standard.bool(forKey: "biometricsOnly") }
        set { UserDefaults.standard.set(newValue, forKey: "biometricsOnly"); objectWillChange.send() }
    }

    func unlockHidden() async -> Bool {
        let ok = await BiometricAuth.authenticate(reason: "Unlock your hidden vault",
                                                  biometricsOnly: biometricsOnly)
        if ok { hiddenUnlocked = true }
        return ok
    }

    /// Seal the hidden side immediately and wipe the preview cache — the UI twin
    /// of LockVaultIntent, independent of any inactivity timer.
    func lockHidden() {
        hiddenUnlocked = false
        VaultService.wipePreviewCache()
    }

    /// Called when the app backgrounds: lock the hidden side and wipe plaintext.
    func handleBackgrounding() {
        lockHidden()
    }
}
