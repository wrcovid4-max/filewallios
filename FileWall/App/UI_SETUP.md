# Wiring the main UI

The UI stage adds these files (all under `FileWall/`):

```
App/AppState.swift          hidden-vault lock, screenshot/obscure state
App/UI_SETUP.md             (this file)
Support/PlatformImage.swift Image(vaultData:) for iOS + macOS
Support/BiometricAuth.swift Face ID / Touch ID / passcode gate
Services/VaultContent.swift import / decrypt / preview-cache
Views/RootView.swift        tabs + screen protection
Views/VaultGridView.swift   grid, import, folders, per-file actions
Views/FileTile.swift        thumbnail tile
Views/ItemDetailView.swift  photo view + Quick Look + export
Views/StateListView.swift   Archive / Recently Deleted
Views/HiddenView.swift      Face ID gate → hidden grid
Views/SecurityView.swift    storage chart, lock, Google backup
```

## 1. Add the new files to the target

In Xcode: right-click the **FileWall** group ▸ **Add Files to "FileWall"…** ▸
select the `App`, `Support`, `Views` folders (and `Services/VaultContent.swift` if
not already in) ▸ ☑ target **FileWall** ▸ **Create groups** ▸ Add.

## 2. Replace `FileWallApp.swift` with this

```swift
import SwiftUI

@main
struct FileWallApp: App {
    @StateObject private var appState = AppState()

    init() {
        BackgroundBackup.registerHandler()      // scheduled Drive backup (iOS)
        PhoneWatchSession.activateSession()      // answer the watch (iOS)
        VaultService.wipePreviewCache()          // no stale plaintext survives a launch
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }
}
```

## 3. Delete the template `ContentView.swift`

The app now starts at `RootView`. Remove `ContentView.swift` (right-click ▸
Delete ▸ Move to Trash) so it doesn't sit unused.

## 4. Build & run

- ⌘R on an iOS 16 simulator.
- **Vault** tab: tap **+** ▸ Photos, pick an image → it encrypts in and appears in
  the grid. Tap it to view; pinch to zoom. ⋯ / long-press a tile for Rename, Move,
  Archive, Delete.
- **Archive** / **Recently Deleted** rows at the bottom open those states; Recently
  Deleted has **Empty**, and Delete Forever confirms.
- **Hidden** tab: Face ID / passcode gate, then its own grid.
- **Security** tab: storage chart, **Lock Hidden Vault Now**, biometrics-only
  toggle, **Sign in with Google** → **Back Up Now** / **Restore**.

## What's intentionally deferred (follow-ups)

- iPad `NavigationSplitView` (sidebar + grid + inspector) — currently the adaptive
  `TabView` runs on iPad too.
- Folder **cover images** (newest previewable file) — folders work today via the
  filter chips + Move.
- Drag & drop, keyboard shortcuts (⌘F/⌘L/space/⌫), Handoff, Live Activity, and
  Spotlight indexing toggles.
- Video playback via the encrypted `AVAssetResourceLoaderDelegate` (documents use
  Quick Look; video currently shows the "open" placeholder in detail).

These are additive — none change the crypto/storage/backup already verified.
