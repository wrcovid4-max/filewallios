# App Intents — Stage 3 (first slice)

This is the App Intents layer's foundation: the file **entity**, its **query**
(all three conformances), and a **FindFilesIntent**. These files must be members
of the **app target**, never FileWallKit — Xcode 14.2's App Intents metadata
extractor only scans the app target, and an intent defined in a framework
compiles but silently never appears in Shortcuts.

```
FileWall/
  AppIntents/
    VaultAppEnums.swift    FileCategoryAppEnum, FileStateAppEnum
    VaultFileEntity.swift  VaultFileEntity: AppEntity
    VaultFileQuery.swift   VaultFileQuery: EntityQuery + EntityStringQuery + EntityPropertyQuery
    FindFilesIntent.swift  FindFilesIntent: AppIntent
  Services/
    VaultService.swift     the only bridge into FileWallKit (standard side only)
    AppEnvironment.swift   App Group id, container URLs, keychain group
```

## The Shortcuts action `EntityPropertyQuery` generates

Conforming `VaultFileQuery` to `EntityPropertyQuery` makes Shortcuts synthesise a
**Find Files in FileWall** action with no per-query intent written by hand. From
`properties` and `sortingOptions` the user gets:

```
┌────────────────────────────────────────────────────────────┐
│  Find  All ▾  Files in FileWall  where                      │
│                                                             │
│     [ Name ▾ ]        [ contains ▾ ]   [ ______________ ]   │
│                        · is                                 │
│                        · contains                           │
│     [ Category ▾ ]    [ is ▾ ]         [ Photo ▾ ]          │
│     [ Size ▾ ]        [ is greater… ▾] [ ____ ] bytes       │
│     [ Date Added ▾ ]  [ is after ▾ ]   [ date picker ]      │
│     [ State ▾ ]       [ is ▾ ]         [ In Vault ▾ ]       │
│                                                             │
│  Sort by [ Date Added ▾ ]  Order [ Newest First ▾ ]        │
│  Limit  [ ____ ]                                            │
└────────────────────────────────────────────────────────────┘
        ↳ Output: List of Vault Files  →  pipe into any action
```

- **Name** — `contains` / `is` (case- & diacritic-insensitive).
- **Category** — `is`, picker of Photo / Video / Document / Other.
- **Size** — `is greater than` / `is less than`, in bytes.
- **Date Added** — `is after` / `is before` (and Shortcuts derives "within" from a
  relative date).
- **State** — `is`, picker of In Vault / Archived / Recently Deleted. **Omitted ⇒
  In Vault only.** Archived and Recently Deleted never appear unless explicitly
  chosen.
- **Sort by** Date Added / Name / Size, ascending or descending.

The `All ▾ / Any ▾` toggle is `ComparatorMode` (`.and` / `.or`); the query ANDs or
ORs the content predicates accordingly, then the store always ANDs in the
standard-side (non-hidden) scope on top.

Because the output is `[VaultFileEntity]`, a user can chain it — e.g. *Find Files
where Category is Photo* → *Repeat with each* → *Export File* — without any code
from us. That composability is the highest-leverage part of the whole
integration.

## Where the privacy guarantees live

Not in the UI — in what can become an entity:

- **No hidden item, ever.** `VaultService` queries `side: .standard` exclusively.
  `VaultFileEntity` is only ever built from a standard-side snapshot, so a hidden
  file is never resolved (`entities(for:)`), suggested (`suggestedEntities`),
  string-matched (`EntityStringQuery`), or returned (`EntityPropertyQuery`). Proven
  by `VaultQueryTests.testHiddenIdIsUnresolvable` and
  `testHiddenNeverLeaksThroughAContentPredicate`.
- **No trashed item by default.** Every default path passes `states: [.live]`.
  Trashed items appear only when the user adds a `State is Recently Deleted`
  filter. Proven by `testDefaultQueryReturnsOnlyLiveStandardItems` and
  `testTrashedIsReturnedOnlyWhenExplicitlyRequested`.
- **Reads require auth.** `FindFilesIntent.authenticationPolicy` is
  `.requiresLocalDeviceAuthentication`.

## Verify on the Mac (Xcode 14.2) — the spots the compiler must confirm

I can't compile CryptoKit/AppIntents here, so three things need an eyeball once
this is in an app target:

1. **`AppEntity.typeDisplayName`.** Used per the iOS 16.0 SDK. If Xcode wants
   `typeDisplayRepresentation` instead, swap the one line (comment in
   `VaultFileEntity.swift`). The reverse swap applies to `AppEnum` if needed.
2. **`entities(matching:mode:sortedBy:limit:)` sort element type.** Written as
   `EntityQuerySort<VaultFileEntity>`. If the SDK declares `Sort<VaultFileEntity>`,
   rename — the body is identical (see comment in `VaultFileQuery.swift`).
3. **`AppShortcut.shortTitle`** (added in the next slice) may not exist in the
   16.0 SDK; the `intent:phrases:systemImageName:` initialiser is the fallback.

These are declaration-shape confirmations, not logic changes.

## Not yet wired (later slices)

- `AppShortcutsProvider` with the five phrases (each must contain
  `\(.applicationName)`), and the remaining intents (Open, Import, Rename, Move,
  Hide/Unhide, Archive/Unarchive, Delete/Restore/DeleteForever/Empty, Lock,
  UnlockHidden, BackUp, VaultStatus, Export).
- `ShowsSnippetView` result cards (need the SwiftUI app).
- Opt-in thumbnails in `DisplayRepresentation` (need the Spotlight/UI stage).
- The hidden-vault intents deliberately stay OUT of `AppShortcutsProvider`.
