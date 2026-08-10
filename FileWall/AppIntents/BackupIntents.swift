import AppIntents
import FileWallKit

/// Back up the vault to Google Drive. Encrypts to the shared `.fwvault` format and
/// uploads (create or replace) to the private `appDataFolder`.
///
/// Like every content intent this requires local device authentication — and that
/// unlock is also what makes the hidden side's key reachable, so a manual backup
/// can include the whole vault (`[.standard, .hidden]`). If there are no hidden
/// items, the hidden key is never touched.
struct BackUpVaultIntent: AppIntent {
    static var title: LocalizedStringResource = "Back Up Vault"
    static var description = IntentDescription(
        "Encrypt your vault and upload it to your Google Drive private app storage.")

    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let result = try await DriveBackupService.shared.backup(sides: [.standard, .hidden])
            let noun = result.items == 1 ? "file" : "files"
            return .result(dialog: "Backed up \(result.items) \(noun) to Google Drive.")
        } catch DriveBackupService.BackupError.notSignedIn {
            return .result(dialog: "Sign in to Google in FileWall first, then try backing up again.")
        }
    }
}

/// Start Google sign-in. Opens the app because `ASWebAuthenticationSession` needs
/// a foreground window (iOS 16 has no in-intent web-auth surface) — hence
/// `openAppWhenRun`, the iOS 16 stand-in for `needsToContinueInForegroundError()`.
struct SignInToGoogleIntent: AppIntent {
    static var title: LocalizedStringResource = "Sign in to Google"
    static var description = IntentDescription("Connect a Google account for Backup & Sync.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            try await GoogleAuth.shared.signIn()
            let who = await GoogleAuth.shared.email ?? "your account"
            return .result(dialog: "Signed in to Google as \(who).")
        } catch GoogleAuth.AuthError.cancelled {
            return .result(dialog: "Sign-in was cancelled.")
        } catch GoogleAuth.AuthError.notConfigured {
            return .result(dialog: "Google sign-in isn't configured in this build yet.")
        }
    }
}
