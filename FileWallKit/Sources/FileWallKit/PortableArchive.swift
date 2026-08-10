import Foundation
import CryptoKit
// CommonCrypto is imported for exactly one reason: PBKDF2. CryptoKit ships no
// password-based KDF at all — no PBKDF2, no scrypt, no Argon2 — so a
// passphrase-keyed archive has nowhere else to go on this platform. Every other
// crypto operation here still runs through CryptoKit's AES-GCM.
import CommonCrypto

/// A `.fwvault` portable archive: a vault file (or whole vault) sealed under a
/// user *passphrase* instead of the device's Secure Enclave key, so it restores
/// on a different device. This is exactly what cloud backup uploads — a blob
/// Apple (or anyone holding the CloudKit asset) cannot read without the
/// passphrase.
///
/// # Layout
///
/// ```
///  off size field
///   0   4   magic      'F' 'W' 'V' 'A'         (0x46 0x57 0x56 0x41)
///   4   1   version    0x01
///   5   1   kdf        0x01 = PBKDF2-HMAC-SHA256
///   6   2   reserved   0x0000
///   8   4   iterations UInt32 big-endian
///  12   1   saltLen    UInt8
///  13   n   salt       random
///  13+n …  body        a full ChunkedCipher blob, keyed by the derived key
/// ```
///
/// The body is an ordinary `ChunkedCipher` blob — same chunked-GCM format as
/// on-device storage — so the only thing that differs between a device blob and
/// a portable one is where the key comes from. That keeps a single audited
/// encryption path.
public struct PortableArchive: Sendable {

    static let magic: [UInt8] = [0x46, 0x57, 0x56, 0x41] // "FWVA"
    static let version: UInt8 = 0x01
    static let kdfPBKDF2: UInt8 = 0x01

    /// 210,000 iterations — OWASP's 2023 PBKDF2-HMAC-SHA256 floor, and the value
    /// the Android build uses, so archives are portable between the two.
    public static let defaultIterations: UInt32 = 210_000
    static let saltLength = 16
    static let derivedKeyLength = 32

    private let cipher: ChunkedCipher
    private let iterations: UInt32

    public init(iterations: UInt32 = PortableArchive.defaultIterations,
                chunkSize: Int = ChunkedCipher.defaultChunkSize) {
        self.cipher = ChunkedCipher(chunkSize: chunkSize)
        self.iterations = iterations
    }

    /// Seal `plaintext` under `passphrase`.
    public func export(_ plaintext: Data, passphrase: String) throws -> Data {
        let salt = ChunkedCipher.randomBytes(count: Self.saltLength)
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let body = try cipher.encrypt(plaintext, using: key)

        var out = Data()
        out.append(contentsOf: Self.magic)
        out.append(Self.version)
        out.append(Self.kdfPBKDF2)
        out.append(contentsOf: [0, 0])
        var iterBE = iterations.bigEndian
        withUnsafeBytes(of: &iterBE) { out.append(contentsOf: $0) }
        out.append(UInt8(salt.count))
        out.append(salt)
        out.append(body)
        return out
    }

    /// Open a `.fwvault` archive with `passphrase`. Wrong passphrase surfaces as
    /// `authenticationFailed` (GCM open fails on the derived key) — the same
    /// opaque outcome as tampering, by design.
    public func restore(_ archive: Data, passphrase: String) throws -> Data {
        guard archive.count >= 13 else { throw CryptoError.malformedHeader }
        let base = archive.startIndex
        guard Array(archive[base ..< base + 4]) == Self.magic else { throw CryptoError.malformedHeader }
        guard archive[base + 4] == Self.version, archive[base + 5] == Self.kdfPBKDF2 else {
            throw CryptoError.malformedHeader
        }
        let iters = archive.subdata(in: base + 8 ..< base + 12).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        let saltLen = Int(archive[base + 12])
        let saltStart = base + 13
        guard archive.endIndex >= saltStart + saltLen else { throw CryptoError.malformedHeader }
        let salt = archive.subdata(in: saltStart ..< saltStart + saltLen)
        let body = archive.subdata(in: saltStart + saltLen ..< archive.endIndex)

        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: iters)
        return try cipher.decrypt(body, using: key)
    }

    // MARK: PBKDF2 via CommonCrypto

    static func deriveKey(passphrase: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        let passwordBytes = Array(passphrase.utf8)
        var derived = [UInt8](repeating: 0, count: derivedKeyLength)

        let status = salt.withUnsafeBytes { saltBuf -> Int32 in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passphrase, passwordBytes.count,
                saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &derived, derived.count)
        }
        // CCKeyDerivationPBKDF returns Int32; kCCSuccess is Int — widen to compare.
        guard status == Int32(kCCSuccess) else { throw CryptoError.keyDerivationFailed }
        let key = SymmetricKey(data: Data(derived))
        // Best-effort scrub of the intermediate buffer. Swift may keep copies, so
        // this is defence-in-depth, not a guarantee.
        for i in derived.indices { derived[i] = 0 }
        return key
    }
}
