# FileWall — Mac setup & verification

Everything in this project lives in this Git repo. Nothing is stored on your
Mac that isn't here. If you wipe the machine, `git clone` restores 100% of it.
So: **commit and push after every change** and you can always start over from a
bare macOS install.

- **Branch to use:** `claude/filewall-apple-platforms-bgnpui`
- **Toolchain:** Xcode 14.2, Swift 5.7.2. Xcode 14.2 needs **macOS 12.5+**.
- **What builds today:** the `FileWallKit` Swift package (crypto + storage) and
  it is **fully unit-tested from the command line — no Xcode project, no
  simulator needed.** That is the checkpoint below. The app/watch/widget targets
  don't exist yet.

---

## Part 1 — Verify the foundation (10 minutes, do this first)

This proves the crypto and storage core compiles and passes its ~40 tests before
we build any UI on top.

### 1. Install the toolchain (once)

- Install **Xcode 14.2** (from Apple's "More Downloads" page, or the App Store if
  it still offers it). Open it once so it finishes installing components.
- In Terminal, point the command-line tools at it and accept the license:
  ```sh
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept
  swift --version      # should print Swift 5.7.2
  ```

### 2. Clone the repo and check out the branch

```sh
git clone https://github.com/wrcovid4-max/filewallios.git
cd filewallios
git checkout claude/filewall-apple-platforms-bgnpui
```

### 3. Run the test suite

```sh
cd FileWallKit
swift test
```

**Expected:** a build, then tests run and pass. You'll see the Secure-Enclave
tests **skip** (they need a signed run on real hardware) — that is correct, not a
failure:

```
Test Suite 'All tests' passed at ...
     Executed NN tests, with 0 failures (0 unexpected) and 3 skipped ...
```

The suites that must be **green**:
- `ChunkedCipherTests` — chunk-boundary round-trips (0/1/1MiB-1/1MiB/1MiB+1),
  tamper rejection, random access, file-streaming parity.
- `PortableArchiveTests` — passphrase export/restore, cross-instance restore,
  wrong-passphrase + tamper rejection, PBKDF2 determinism.
- `VaultLifecycleTests` — delete/restore/archive/purge, storage accounting,
  hidden isolation, 30-day retention.
- `VaultQueryTests` — hidden unresolvable, trashed opt-in only, default = live.

`VaultKeyStoreTests` skipping is expected on the command line.

### 4. If something fails

The code was written without a compiler available, so the first real build may
surface a small API-shape issue. If you hit one:

- **Copy the exact error** (file, line, message) back to me and I'll fix it on
  the branch. That's the fastest path — don't hand-patch unless you want to.
- Common, low-risk suspects and their fixes are already noted in comments:
  - `import CommonCrypto` not found → the modulemap ships with the toolchain;
    make sure `xcode-select` points at Xcode 14.2, not the standalone CLT.
  - Any CryptoKit signature mismatch → tell me the line.
- When green, you don't need to do anything else in Part 1.

### 5. Keep it in the cloud

You won't have changed anything here, but as a habit:

```sh
cd ..
git status          # should be clean after a test run (build output is gitignored)
```

---

## Part 2 — Create the app project (when we're ready for UI)

> Do this **after** Part 1 is green. This is where the App Intents files
> (`FileWall/AppIntents/*`) get compiled into a real app target so Shortcuts can
> see them. Until then they're just source on disk.

The repo currently has **loose Swift files** under `FileWall/`, not an Xcode
project. We create the project once and add those files to it. The `.xcodeproj`
then gets committed so it, too, survives a wipe.

### 1. New project

- Xcode → **File ▸ New ▸ Project… ▸ iOS ▸ App**.
- Product Name: **FileWall**
- Interface: **SwiftUI**, Language: **Swift**, Storage: **None** (we use Core
  Data via FileWallKit, not the template's boilerplate).
- Save it **inside the repo root** (`filewallios/`). Let it create
  `filewallios/FileWall.xcodeproj`. When Xcode offers to create a Git repo,
  **decline** — we already have one.
- Set **Minimum Deployments ▸ iOS 16.0** in the target's General tab.

### 2. Add FileWallKit as a local package

- **File ▸ Add Packages… ▸ Add Local…**, choose the `FileWallKit` folder in the
  repo.
- On the FileWall target ▸ **General ▸ Frameworks, Libraries** — confirm
  `FileWallKit` is listed. Now `import FileWallKit` resolves.

### 3. Add the existing app source to the target

- In Finder you already have `FileWall/AppIntents/*.swift` and
  `FileWall/Services/*.swift`.
- In Xcode, **right-click the FileWall group ▸ Add Files to "FileWall"…**, select
  those files, and make sure **"Add to target: FileWall" is checked** (this is
  the step that matters — App Intents must be in the app target).
- Delete the template's placeholder `ContentView.swift` later when we add the
  real UI; for now it can stay.

### 4. Capabilities (Signing & Capabilities tab)

Add these — they're referenced by the code and by `AppEnvironment.swift`:

- **App Groups** → create/enable `group.com.filewall.shared`. Update
  `AppEnvironment.appGroupID` to match if you choose a different id.
- **Keychain Sharing** → add group `com.filewall.shared`. Update
  `AppEnvironment.keychainAccessGroup` to match.
- **Info.plist** → add `ITSAppUsesNonExemptEncryption` = **NO**. Without this
  every build stalls on export-compliance. (The app uses standard OS crypto and
  qualifies for the exemption.)

### 5. Build

- Select an **iOS 16 Simulator** (or your registered device) and **⌘B**.
- The App Intents shapes I flagged will surface here if any need the alternate
  form. Three to watch (all documented in `FileWall/AppIntents/APP_INTENTS.md`):
  1. `AppEntity.typeDisplayName` vs `typeDisplayRepresentation`.
  2. `entities(matching:…sortedBy:…)` — `EntityQuerySort` vs `Sort`.
  3. `AppShortcut.shortTitle` (only when we add `AppShortcutsProvider`).
- Paste any error back to me; these are one-line declaration fixes.

### 6. See the Shortcuts action

Once it builds and runs once on the simulator/device:
- Open **Shortcuts ▸ + ▸ search "FileWall"** → you'll see **Find Files in
  FileWall** (from the `EntityPropertyQuery`) and **Find Files** (the explicit
  intent). The action's filter rows match the diagram in `APP_INTENTS.md`.

### 7. Commit the project

```sh
git add FileWall.xcodeproj FileWall
git commit -m "Add Xcode app project and wire App Intents into the app target"
git push
```

---

## Two standing constraints (from the project brief)

- **visionOS can't be built** on Xcode 14.2 (SDK first shipped in 15.2). iOS,
  iPadOS, watchOS only.
- **App Store / TestFlight submission is closed** on this toolchain (Apple
  requires Xcode 16 + iOS 18 SDK since April 2025). You can still develop, run on
  your **registered devices**, and sideload. Moving to Xcode 16 later unblocks
  submission without throwing any of this code away.

## What's built so far (all on the branch)

| Stage | Location | Status |
|-------|----------|--------|
| Chunked AES-GCM crypto | `FileWallKit/Sources/.../ChunkedCipher.swift` | code + tests |
| Secure Enclave key wrap | `FileWallKit/Sources/.../VaultKeyStore.swift` | code (device test) |
| Portable `.fwvault` archive | `FileWallKit/Sources/.../PortableArchive.swift` | code + tests |
| Core Data lifecycle engine | `FileWallKit/Sources/.../VaultStore.swift` | code + tests |
| App Intents (first slice) | `FileWall/AppIntents/*` | code (needs app target) |

Not yet built: the SwiftUI app UI, watchOS app, widgets, Spotlight indexing,
encrypted video playback, the remaining ~18 intents, and cloud/CloudKit backup.
