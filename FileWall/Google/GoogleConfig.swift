import Foundation

/// Google OAuth / Drive configuration.
///
/// The **iOS client ID must be created under the same Google Cloud project as the
/// Android client** — Drive's `appDataFolder` is scoped per user *per project*,
/// so a shared project is what makes iOS and Android see the same
/// `filewall-backup.fwvault`. See IOS_GOOGLE_SETUP.md.
enum GoogleConfig {

    /// Read from Info.plist key `GoogleOAuthClientID` if present, else the
    /// constant below. Set ONE of them to your console value; keep the constant as
    /// a fallback so a fresh checkout is obviously unconfigured rather than
    /// silently wrong.
    /// The iOS OAuth client ID. Baked in as the default (client IDs are public,
    /// not secrets — Google ships this same string in every app's
    /// GoogleService-Info.plist), overridable via the Info.plist key
    /// `GoogleOAuthClientID` if you ever rotate it. Registered against bundle ID
    /// `com.filewall.FileWall`.
    static var clientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "331932361656-40gb7jj90e235nfib3d5j4l8caun7o2q.apps.googleusercontent.com"
    }

    /// The reversed client ID, e.g. `com.googleusercontent.apps.NNN-xxxx`. This is
    /// also the URL scheme that must be registered in Info.plist (CFBundleURLTypes)
    /// so the OAuth redirect returns to the app.
    static var reversedClientID: String {
        let suffix = ".apps.googleusercontent.com"
        let prefix = clientID.hasSuffix(suffix) ? String(clientID.dropLast(suffix.count)) : clientID
        return "com.googleusercontent.apps.\(prefix)"
    }

    /// Redirect URI, per the spec: "<reversedClientID>:/oauth2redirect".
    static var redirectURI: String { "\(reversedClientID):/oauth2redirect" }

    /// The scheme ASWebAuthenticationSession watches for the callback.
    static var callbackScheme: String { reversedClientID }

    /// openid + email (for display) + Drive app-data (app-private). `drive.appdata`
    /// is non-sensitive and needs no Google verification.
    static let scope = "openid email https://www.googleapis.com/auth/drive.appdata"

    static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    static var isConfigured: Bool { !clientID.hasPrefix("REPLACE_WITH_") }
}
