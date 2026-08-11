# watchOS target — setup

The watch app is a **viewfinder**, not a second vault: it holds no keys, stores
nothing, and only ever sees **live, non-hidden photos** the phone chooses to
answer with. Hidden/archived/trashed items are filtered on the phone
(`VaultService.watchLiveItems` / `watchThumbnailData`), so a lost watch cannot
even ask for them.

## Files

```
WatchSources/                       (files for the watchOS App target)
  FileWallWatchApp.swift            @main
  WatchConnectivityClient.swift     WCSession: request manifest / photo / open-on-phone
  WatchVaultView.swift              list of items + vault size
  WatchItemDetailView.swift         photo (Digital Crown zoom) or "Open on iPhone"

FileWall/Watch/PhoneWatchSession.swift   phone-side responder (iOS only)
FileWallKit/.../WatchTransfer.swift      shared DTOs + message keys
```

## Add the target in Xcode

1. **File ▸ New ▸ Target… ▸ watchOS ▸ App** (a *Watch App for iOS App* if it
   offers to pair it to FileWall — that wires the companion relationship).
   - Product Name: **FileWallWatch**
   - Interface: SwiftUI, Language: Swift
   - Bundle id will be `com.filewall.FileWall.watchkitapp` (a suffix of the phone
     id — leave it).
   - Min watchOS **9.0**.
2. Xcode creates a `FileWallWatch` group with its own `…App.swift`/`ContentView`.
   **Delete the generated `ContentView.swift` and the generated `…App.swift`**,
   then **Add Files to "FileWallWatch"…** and add the four `.swift` files from the
   repo's `WatchSources/` folder, ☑ target **FileWallWatch**.
3. Select the **FileWallWatch** target ▸ **General ▸ Frameworks, Libraries** ▸
   **+** ▸ add **FileWallKit** (the watch shares the DTOs).
4. On the **FileWall** (phone) target, make sure `FileWall/Watch/PhoneWatchSession.swift`
   is a member (it should be, since it's under the FileWall group).

## Wire activation (phone `FileWallApp.swift`)

In the phone app's `init()` — next to the background-task registration — add:

```swift
init() {
    BackgroundBackup.registerHandler()
    PhoneWatchSession.activateSession()   // start answering the watch
}
```

(`PhoneWatchSession.activateSession()` is a no-op on macOS, so this line is safe
in the multiplatform target.)

## Run it

- Select the **FileWallWatch** scheme + a paired **iPhone + Watch simulator**
  pair, or your devices. Launch the phone app once (so the vault has content and
  the session is active), then the watch.
- Empty vault → the watch says "Open FileWall on your iPhone to sync." Add a photo
  on the phone, and it appears on the watch; tap it to view, turn the Crown to
  zoom. A video/document shows **Open on iPhone**.

## Not yet: the complication

The watchOS 9 **complication is a WidgetKit widget**, which is its *own* widget
extension target (not part of this app target). It'll show the vault size on the
watch face. That's a small follow-up once the widgets stage lands — it reuses the
same `WatchVaultManifest.totalBytes` over the App Group. Left out here to keep
this target focused.

## Security recap (why this is safe)

- The watch never holds a key and never receives ciphertext — the phone decrypts
  and sends a **downsampled JPEG** only for photos.
- Every answer is scoped to the **standard side, live only** — hidden, archived
  and trashed items are never named or served.
- Photos are the only content shown on the watch; video/documents route back to
  the phone via a local notification.
