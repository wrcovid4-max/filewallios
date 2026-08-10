# FileWallKit

Crypto, storage, models and sync for **FileWall** — an encrypted file vault for
iOS 16, iPadOS 16 and watchOS 9. No UI. Builds and tests on macOS so the crypto
suite runs without a simulator.

> **Toolchain:** Xcode 14.2 / Swift 5.7.2 / iOS 16 / watchOS 9. No SwiftData, no
> `@Observable`, no Swift 6 concurrency, no third-party dependencies. See the
> top-level project prompt for why (visionOS and App Store submission are both
> out of reach on this toolchain — a deliberate, documented choice).

## Build order

This package is **Stage 1** of a five-stage build. Stage 1 is the crypto
foundation and is where the correctness bar is highest — everything after it is
replaceable UI and integration:

1. **FileWallKit — crypto ✅ (this stage)**
2. iOS/iPadOS app
3. App Intents (declared in the *app* target, never here — Xcode 14.2's metadata
   extractor only scans the app target, so intents in a framework silently fail
   to appear in Shortcuts)
4. watchOS
5. Widgets

## What Stage 1 ships

| File | Responsibility |
|------|----------------|
| `ChunkedCipher.swift` | The on-disk file format: 1 MiB chunks, each independently sealed with AES-GCM. Authenticated **and** seekable. Full byte-layout diagram in the header comment. In-memory and file-streaming APIs. |
| `VaultKeyStore.swift` | Per-vault 256-bit AES key, wrapped by a Secure Enclave P-256 key via ECDH + HKDF, stored in the Keychain (`ThisDeviceOnly`; `.biometryCurrentSet` for the hidden side). |
| `PortableArchive.swift` | `.fwvault` export: passphrase-keyed (PBKDF2-HMAC-SHA256, 210k iterations) so it restores on another device. This is what cloud backup uploads. |
| `CryptoErrors.swift` | Coarse error surface — decrypt failures collapse to one opaque outcome so a caller can never distinguish "wrong key" from "tampered byte". |

### Why AES-GCM instead of the Android build's AES-CTR + HMAC

The Android vault gets seekability from CTR but can only verify integrity by
reading the whole file, and a flipped middle byte yields plausible garbage until
the final HMAC check. Chunked GCM gives authenticated encryption *and* O(1)
random access: a seek decrypts exactly one chunk, and a tampered chunk fails to
open rather than rendering. CryptoKit also doesn't expose CTR, so matching
Android would mean dropping to CommonCrypto for no gain. The one place
CommonCrypto is unavoidable is PBKDF2 (CryptoKit has no password KDF), and that
is called out in `PortableArchive.swift`.

## Testing

```
cd FileWallKit
swift test          # runs on macOS 12.5+, no simulator needed
```

The `ChunkedCipher` and `PortableArchive` suites run anywhere CryptoKit exists.
The `VaultKeyStore` suite needs Secure Enclave hardware **and** a signed run with
the keychain-access-group entitlement, so it `XCTSkip`s on an unentitled/CI host
rather than failing. Biometric-re-enrolment key invalidation is verified
manually on-device (documented in `VaultKeyStoreTests`), since it needs a human
to add a Face ID / Touch ID enrolment mid-test.

Coverage:

- Round-trip across chunk boundaries: 0, 1, 1 MiB − 1, 1 MiB, 1 MiB + 1 bytes.
- Tamper: a flipped byte in the header, the first chunk, and the last chunk all
  fail to open.
- Random access: a middle chunk decrypts standalone and matches the whole-file
  decrypt.
- Portable archive: cross-instance restore (proves it's passphrase-, not
  device-bound), wrong-passphrase and tamper rejection, PBKDF2 determinism.
