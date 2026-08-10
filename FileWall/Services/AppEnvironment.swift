import Foundation

/// App-wide locations and identifiers. Centralised so the App Group id lives in
/// exactly one place — it must match the App Group capability you add to every
/// target (app, widgets, watch, App Intents) in Xcode.
///
/// The App Group lets the widget and watch extension read vault *metadata*. It
/// must never carry keys: the wrapped vault key stays in the Keychain access
/// group, which is a separate sharing mechanism.
enum AppEnvironment {

    /// TODO(Xcode): set this to the App Group you create under
    /// Signing & Capabilities. Keep it identical across all targets.
    static let appGroupID = "group.com.filewall.shared"

    /// Where encrypted blobs and the metadata store live. In the App Group
    /// container so widgets/watch can read metadata; falls back to Application
    /// Support if the group container isn't provisioned yet (e.g. first run in a
    /// fresh checkout before capabilities are wired).
    static var vaultDirectory: URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vault", isDirectory: true)
    }

    /// Keychain access group for the wrapped vault key, shared across targets.
    /// Must match the Keychain Sharing capability's group (Xcode prefixes it with
    /// your team id at runtime).
    static let keychainAccessGroup = "com.filewall.shared"
}
