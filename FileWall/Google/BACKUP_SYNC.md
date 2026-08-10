# Google Sign-In + Drive Backup & Sync (iOS)

Sign-in-only cloud backup, no passphrase, sharing **one backup** with the Android
app. Native OAuth (ASWebAuthenticationSession + PKCE) and raw Drive REST over
URLSession — **no GoogleSignIn SDK, no AppAuth, no third-party dependencies**.

The wire format is the contract in [`BACKUP_FORMAT.md`](../../BACKUP_FORMAT.md)
(mirrored into this repo from the Android project). The interop codec that
implements it lives in `FileWallKit/Sources/FileWallKit/Interop/`.

## Files

```
FileWall/Google/
  GoogleConfig.swift        client ID, reversed ID, redirect URI, scopes, endpoints
  GoogleAuth.swift          PKCE OAuth via ASWebAuthenticationSession; token refresh; Keychain
  DriveClient.swift         Drive v3 REST against appDataFolder (find/create/patch/download)
  DriveBackupService.swift  managedPassphrase(), backup(sides:), restore(), autoBackupIfSafe()
  BackgroundBackup.swift    BGProcessingTaskRequest scheduling + handler
FileWall/AppIntents/
  BackupIntents.swift       BackUpVaultIntent (auth-gated) + SignInToGoogleIntent
FileWallKit/Sources/FileWallKit/Interop/
  InteropArchive.swift      the FWARCH01 container (PBKDF2 → AES-256-CTR + HMAC over a ZIP)
  InteropCrypto.swift       PBKDF2-64 / AES-CTR (CommonCrypto) + HMAC (CryptoKit)
  ZipArchive.swift          minimal ZIP (stored write; stored+deflate read via Compression)
  CRC32.swift, BackupManifest.swift
```

## Console setup (once, by hand)

Use the **same Google Cloud project as Android** — Drive's `appDataFolder` is
scoped per user *per project*, and a shared project is what makes the backup
shared. In that project → Credentials → Create OAuth client ID → **iOS**, set the
app's Bundle ID, copy the **iOS client ID** (`NNN-xxxx.apps.googleusercontent.com`).
The Drive API and consent screen are already set up from Android. (Full detail:
`IOS_GOOGLE_SETUP.md` in the Android repo.)

## Info.plist (add these)

1. **OAuth client ID** — key `GoogleOAuthClientID` = your iOS client ID. (Or edit
   the fallback constant in `GoogleConfig.swift`.)
2. **Redirect URL scheme** — `CFBundleURLTypes` → one URL type whose
   `CFBundleURLSchemes` contains your **reversed** client ID
   (`com.googleusercontent.apps.NNN-xxxx`). This is how the OAuth redirect returns.
3. **Background task id** — `BGTaskSchedulerPermittedIdentifiers` (array) →
   `com.filewall.autobackup`.
4. `ITSAppUsesNonExemptEncryption` = NO (already needed for the main app).

Example:
```xml
<key>GoogleOAuthClientID</key>
<string>NNN-xxxx.apps.googleusercontent.com</string>
<key>CFBundleURLTypes</key>
<array><dict>
  <key>CFBundleURLSchemes</key>
  <array><string>com.googleusercontent.apps.NNN-xxxx</string></array>
</dict></array>
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array><string>com.filewall.autobackup</string></array>
```

## Capabilities

- **Background Modes** → Background processing (for the auto-backup task).
- App Groups + Keychain Sharing are already added for the main app; the refresh
  token uses its own service and does not need the group.

## Wiring at launch

```swift
// App init / didFinishLaunching:
BackgroundBackup.registerHandler()      // must run before launch finishes
// After a successful sign-in (and after each run) call:
BackgroundBackup.schedule()
```

`GoogleAuth.shared` is `@MainActor` and `ObservableObject` — bind `isSignedIn` /
`email` in the Settings UI. Sign-in, backup and restore are all `async`.

## How it works

- **Auth:** PKCE (S256), `access_type=offline` + `prompt=consent` so a
  `refresh_token` is issued. Refresh token → Keychain
  (`AfterFirstUnlockThisDeviceOnly`, never iCloud). Access token in memory,
  refreshed a minute before expiry. **No client secret** (public client).
- **Managed key:** `DriveBackupService.managedPassphrase()` reads
  `filewall-backup.key` from `appDataFolder`, or mints 32 random bytes, Base64
  (no wrap), uploads it, and uses that text — identical to Android. The user is
  never asked for a Drive passphrase.
- **Backup:** decrypt each device blob (chunked-GCM) → plaintext temp → zip with
  `manifest.json` → PBKDF2/AES-CTR/HMAC container → upload (create or PATCH).
- **Restore:** download → verify HMAC → decrypt → unzip → for each item
  re-encrypt plaintext into the device format and register with its exact
  hidden/archived/deleted state (30-day purge clock resumes from `deletedAt`).

## Security notes

- **"As safe as your Google account."** The managed key sits beside the data in
  the account's private `appDataFolder`; whoever can reach that folder can
  restore. Google only ever stores the encrypted `.fwvault` and an opaque key
  file — never plaintext.
- No client secret in the app; PKCE is the proof-of-possession. Refresh token is
  device-only and never synced to iCloud.
- The header (magic/salt/iterations/iv) is deliberately **not** MAC-covered — the
  MAC is over ciphertext only, matching Android. Wrong passphrase and tampering
  both surface as one opaque `wrongPassphraseOrDamaged`.

## Honest limitations (read before shipping)

1. **Not yet compiled.** Written against the iOS 16 SDK without a compiler
   available. The interop codec (`FileWallKit/.../Interop`) is unit-tested on
   macOS; the Google/Drive layer needs a device run. Expect to fix a small API
   shape or two — send me the error.
2. **Auto-backup and the hidden vault.** The background task can't read the
   biometry-gated hidden key, so `autoBackupIfSafe()` **declines** (uploads
   nothing) when hidden items exist, to avoid clobbering a fuller manual backup
   with a standard-only one. Users with a hidden vault should back up manually
   (BackUpVaultIntent / the Settings button) after unlocking. A future option is
   an Android-style sealed auto-backup secret for the device key.
3. **Restore is additive.** It creates items/folders; it does not de-duplicate
   against what's already in the vault. Restoring twice doubles items. A
   merge/replace policy is a follow-up.

## Interop test (the acceptance criterion)

1. On **Android**, back up to Drive (same Google account, same Cloud project).
2. On **iOS**, sign in with the same account → Restore. Every file, folder, and
   the hidden / archived / deleted state must come back.
3. Reverse it: back up on iOS, restore on Android.

If either direction fails, the archive bytes or managed-key handling diverged
from `BACKUP_FORMAT.md` — that file is the source of truth; match it.
