# FileWall (Apple platforms)

An encrypted file vault for iOS 16, iPadOS 16 and watchOS 9. Encryption keys
never leave the device. No account, no server, no sign-up. A second "hidden"
vault sits behind biometrics, and cloud backup uploads a blob Apple cannot read.

App Intents, Siri, Spotlight and Shortcuts are primary surfaces, not bolt-ons.

**Toolchain:** Xcode 14.2 / Swift 5.7.2. No SwiftData, no `@Observable`, no
Swift 6 concurrency, no third-party dependencies, no visionOS (its SDK needs
Xcode 15.2). App Store submission needs Xcode 16 — this toolchain is for
development and sideloading to registered devices.

## Start here

- **[MACOS_SETUP.md](MACOS_SETUP.md)** — clone the branch, run the tests, and
  (later) create the Xcode app project. Read this first.
- **[FileWallKit/README.md](FileWallKit/README.md)** — the crypto + storage core
  and its test suite. This is the foundation; it builds and tests on macOS with
  no simulator.
- **[FileWall/AppIntents/APP_INTENTS.md](FileWall/AppIntents/APP_INTENTS.md)** —
  the App Intents layer and the Shortcuts "Find Files" action it generates.
- **[FileWall/Google/BACKUP_SYNC.md](FileWall/Google/BACKUP_SYNC.md)** — Google
  sign-in + Drive "Backup & Sync" (native OAuth, no SDK), and how to configure it.
- **[BACKUP_FORMAT.md](BACKUP_FORMAT.md)** — the cross-platform `.fwvault` wire
  format shared with the Android app. The contract; match it byte-for-byte.

## Layout

```
FileWallKit/     Swift package: crypto, storage, models. No UI. Tested on macOS.
FileWall/        iOS + iPadOS app source (App Intents live here, not in the kit).
                 The Xcode project is created during Mac setup — see MACOS_SETUP.
```

Everything lives in this repo and is developed on the branch
`claude/filewall-apple-platforms-bgnpui`. Nothing is stored locally that isn't
committed — a fresh `git clone` restores the whole project.
