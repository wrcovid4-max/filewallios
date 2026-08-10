# FileWall backup format (`.fwvault`) — cross-platform spec

This is the **wire format** for FileWall's portable backup and for Google Drive "Backup &
Sync". Android writes it today; the iOS/iPadOS/watchOS app must read and write **exactly**
this so a backup made on one platform restores on the other. Treat every constant here as
load-bearing.

## Where it lives

- **Local export / import:** a single `.fwvault` file the user saves anywhere.
- **Cloud:** the same bytes, uploaded to the user's Google **Drive `appDataFolder`** under the
  fixed name **`filewall-backup.fwvault`**. Backup replaces that one file; sync/restore reads
  it back.
- OAuth scope: `https://www.googleapis.com/auth/drive.appdata` (app-private; Google never sees
  plaintext, and the app cannot see the user's other Drive files).

### The one requirement for iOS ↔ Android sync to share a backup
Drive's `appDataFolder` is scoped **per user, per Google Cloud project** — not per OAuth
client. So the iOS client ID and the Android client ID **must be created under the same
Google Cloud project**. Same project → both platforms see the same `filewall-backup.fwvault`.
Different projects → two separate, invisible-to-each-other backups. Also register each
platform's OAuth client (Android: package name + signing SHA-1; iOS: bundle ID) in that
project, or sign-in fails with a developer-config error.

## Byte layout

```
┌────────────┬──────────┬─────────────────┬─────────┬────────────────────────┬───────────────┐
│ magic 8B   │ salt 16B │ iterations 4B   │ iv 16B  │ AES-256-CTR( ZIP body ) │ HMAC-SHA256   │
│ "FWARCH01" │ random   │ uint32 big-end  │ random  │ …ciphertext…            │ 32B trailer   │
└────────────┴──────────┴─────────────────┴─────────┴────────────────────────┴───────────────┘
```

- **magic** — ASCII `FWARCH01`. Reject anything else.
- **salt** — 16 random bytes, per export.
- **iterations** — PBKDF2 round count, big-endian `uint32`. Writers use **210000**. Readers
  accept `1000…2000000` and use the value from the header (so the count can rise later without
  breaking old files).
- **iv** — 16 random bytes, the AES-CTR initial counter.
- **ciphertext** — AES-256-CTR of the ZIP body (see below). CTR, no padding.
- **HMAC** — final 32 bytes: HMAC-SHA256 **over the ciphertext only** (encrypt-then-MAC). The
  8+16+4+16 header is *not* covered by the MAC — do not MAC it, or verification fails against
  Android. Compare in constant time.

## Key derivation

```
dk        = PBKDF2-HMAC-SHA256(passphrase (UTF-8), salt, iterations, dkLen = 64 bytes)
aesKey    = dk[0..32]     // AES-256
macKey    = dk[32..64]    // HMAC-SHA256
```

Minimum passphrase length enforced on **write** is 8; reads accept any length (the MAC is what
actually gates a bad passphrase — a wrong passphrase yields a wrong `macKey` and the trailer
comparison fails with "wrong passphrase or damaged archive").

### Two ways the "passphrase" is supplied

The container is identical either way — only where the passphrase comes from differs:

1. **Local `.fwvault` export / import** — the user types a passphrase. Nothing else is stored;
   they must remember it. This is the portable, zero-knowledge path.
2. **Drive "Backup & Sync" (sign-in only)** — there is no user passphrase. A random 256-bit key
   is generated once and stored, Base64 (`NO_WRAP`) as UTF-8 text, in a **second file in the
   same `appDataFolder`**:

   ```
   filewall-backup.key      Base64 of 32 random bytes — the passphrase for the archive
   filewall-backup.fwvault  the archive, keyed from that
   ```

   Any device signed into the account downloads `filewall-backup.key`, uses its text as the
   passphrase (fed to the same PBKDF2), and decrypts. First backup on an account mints the key
   if it is absent. This is deliberately **"as safe as the Google account"**: the key sits
   beside the data, so whoever can read the `appDataFolder` can restore. It never leaves that
   private folder. **iOS must follow the same rule** — read `filewall-backup.key` from
   `appDataFolder` and use its contents as the passphrase; only fall back to prompting if you
   are restoring a *local* file that has no key beside it.

## Read order (matters)

1. Read + check magic, salt, iterations, iv.
2. Derive keys.
3. Stream the body: hold back the last 32 bytes as the expected MAC; feed everything before it
   through both HMAC (update) and AES-CTR (decrypt) into a temp file.
4. **Verify the HMAC before using any plaintext.** Only then open the ZIP. Nothing reaches the
   vault until the trailer matches.

## Body: a ZIP

The decrypted plaintext is a standard ZIP (Android writes it with `DEFLATE`; readers must
handle stored + deflated entries):

```
manifest.json          UTF-8 JSON, schema below
blobs/<uuid>           one entry per file, raw *plaintext* bytes of that file
```

Blob entry names are `blobs/` + the item's `id`. Restore must stage each entry by a counter,
**never** by the entry's own name, so a hand-crafted archive can't write outside the staging
dir (path-traversal guard).

## `manifest.json` (format version 2)

```json
{
  "version": 2,
  "createdAt": 1723305600000,
  "folders": [
    { "id": "uuid", "name": "Iran", "colorIndex": 3, "createdAt": 1723300000000, "hidden": false }
  ],
  "items": [
    {
      "id": "uuid",
      "name": "invoice.pdf",
      "mimeType": "application/pdf",
      "sizeBytes": 48213,
      "addedAt": 1723301111000,
      "folderId": "uuid or null",
      "hidden": false,
      "archived": false,
      "deletedAt": 0,
      "entry": "blobs/uuid"
    }
  ]
}
```

- Times are epoch **milliseconds**.
- `folderId` is `null` for a root item.
- `hidden` — the hidden-vault flag.
- `archived` — in the Archive.
- `deletedAt` — `0` = live; otherwise the epoch-ms it entered Recently Deleted. A restore
  should re-create the item in that state, and re-apply the 30-day purge clock from `deletedAt`.
- **v1 compatibility:** v1 manifests omit `archived`/`deletedAt`; default both (`false`/`0`,
  i.e. live). A v1 reader opening a v2 manifest simply ignores the two new fields. Never hard-
  fail on `version` — read what you understand, default the rest.

## iOS implementation notes

- **PBKDF2, AES-CTR and HMAC come from CommonCrypto**, not CryptoKit — CryptoKit exposes
  neither PBKDF2 nor AES-CTR. This is the one place CommonCrypto is unavoidable; note it so a
  reader doesn't try to "modernise" it into GCM and silently break cross-platform restore.
- Do **not** use the app's normal on-device format (chunked AES-GCM) for `.fwvault`. That
  format is device-keyed and not portable. `.fwvault` is its own passphrase-keyed container,
  identical on every platform — this file is the contract.
- ZIP: read/write a standard archive (e.g. via `libcompression` + a minimal local-file/central-
  directory parser, or a small vendored zip helper). Entries can be deflated.
- Upload/download against `https://www.googleapis.com/drive/v3/files` with `spaces=appDataFolder`;
  find the file by `name == filewall-backup.fwvault`, `PATCH` its media to replace or multipart-
  `POST` to create. (Mirrors `DriveBackup` on Android.)

## Reference implementation

Android: `app/src/main/java/com/filewall/data/backup/VaultArchive.kt` (format) and
`DriveBackup.kt` (Drive appDataFolder transport). When in doubt, those files are the source of
truth — match their bytes.
