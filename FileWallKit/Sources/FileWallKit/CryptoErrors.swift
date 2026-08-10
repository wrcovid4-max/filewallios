import Foundation

/// Errors surfaced by the FileWallKit crypto layer.
///
/// These are intentionally coarse. A vault must never leak *why* a decrypt
/// failed in a way that helps an attacker distinguish "wrong key" from
/// "tampered data" — from the caller's point of view both are simply
/// `authenticationFailed`, and both mean "do not trust this blob".
public enum CryptoError: Error, Equatable {
    /// The blob is too short to contain a valid header, or the magic/version
    /// bytes do not match. The file is not a FileWall blob (or is truncated).
    case malformedHeader

    /// The declared chunk size is zero or absurdly large. A hostile header
    /// could otherwise ask us to allocate gigabytes per chunk.
    case invalidChunkSize

    /// The encrypted body length is not a valid sequence of sealed chunks —
    /// e.g. a trailing fragment smaller than a GCM tag. Structural corruption.
    case truncatedBody

    /// A requested chunk index is past the end of the file.
    case chunkIndexOutOfRange

    /// GCM authentication failed on open. Wrong key, wrong nonce, or the
    /// ciphertext/header/AAD was tampered with. Caller gets one bit: reject.
    case authenticationFailed

    /// The Secure Enclave is unavailable on this device, or key generation
    /// against it failed.
    case secureEnclaveUnavailable

    /// A Keychain operation returned a non-success `OSStatus`.
    case keychain(OSStatus)

    /// PBKDF2 key derivation failed (CommonCrypto returned non-success).
    case keyDerivationFailed
}
