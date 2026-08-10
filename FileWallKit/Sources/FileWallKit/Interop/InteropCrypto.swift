import Foundation
import CryptoKit
// CommonCrypto is unavoidable here and MUST stay: CryptoKit exposes neither
// PBKDF2 nor AES-CTR, and the cross-platform `.fwvault` format is defined in
// terms of both (see BACKUP_FORMAT.md). Do NOT "modernise" this to AES-GCM —
// that would silently break restore against the Android app, which is the whole
// point of this codec.
import CommonCrypto

/// The three primitives the `.fwvault` container is built from, matched to the
/// Android reference (`VaultArchive.kt`) byte-for-byte.
enum InteropCrypto {

    /// PBKDF2-HMAC-SHA256 producing a 64-byte block: `dk[0..32]` is the AES-256
    /// key, `dk[32..64]` is the HMAC key. Android derives 512 bits the same way.
    static func deriveKeys(passphrase: String, salt: Data, iterations: UInt32) throws -> (aes: SymmetricKey, mac: SymmetricKey) {
        let pass = Array(passphrase.utf8)
        var dk = [UInt8](repeating: 0, count: 64)
        let status = salt.withUnsafeBytes { saltBuf in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passphrase, pass.count,
                saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                iterations,
                &dk, dk.count)
        }
        guard status == Int32(kCCSuccess) else { throw CryptoError.keyDerivationFailed }
        let aes = SymmetricKey(data: Data(dk[0..<32]))
        let mac = SymmetricKey(data: Data(dk[32..<64]))
        for i in dk.indices { dk[i] = 0 } // best-effort scrub
        return (aes, mac)
    }

    /// AES-256-CTR, big-endian 128-bit counter starting at `iv` — the semantics
    /// of Java's `AES/CTR/NoPadding` with a 16-byte IV, which increments the whole
    /// counter block. `kCCModeOptionCTR_BE` is the matching CommonCrypto mode.
    /// CTR is symmetric, so the same routine encrypts and decrypts.
    final class CTR {
        private var cryptor: CCCryptorRef?

        init(key: SymmetricKey, iv: Data) throws {
            let keyData = key.withUnsafeBytes { Data($0) }
            let status = keyData.withUnsafeBytes { keyBuf in
                iv.withUnsafeBytes { ivBuf in
                    CCCryptorCreateWithMode(
                        CCOperation(kCCEncrypt),          // for CTR, op is nominal
                        CCMode(kCCModeCTR),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCPadding(ccNoPadding),
                        ivBuf.baseAddress,
                        keyBuf.baseAddress, keyData.count,
                        nil, 0, 0,
                        CCModeOptions(kCCModeOptionCTR_BE),
                        &cryptor)
                }
            }
            guard status == Int32(kCCSuccess), cryptor != nil else {
                throw CryptoError.keyDerivationFailed
            }
        }

        deinit { if let cryptor { CCCryptorRelease(cryptor) } }

        /// Transform one chunk. Output length equals input length for CTR.
        func update(_ input: Data) throws -> Data {
            guard !input.isEmpty else { return Data() }
            var out = Data(count: input.count)
            var moved = 0
            let status = out.withUnsafeMutableBytes { outBuf in
                input.withUnsafeBytes { inBuf in
                    CCCryptorUpdate(cryptor,
                                    inBuf.baseAddress, input.count,
                                    outBuf.baseAddress, out.count,
                                    &moved)
                }
            }
            guard status == Int32(kCCSuccess) else { throw CryptoError.authenticationFailed }
            if moved != out.count { out.removeSubrange(moved..<out.count) }
            return out
        }
    }

    // MARK: HMAC-SHA256 over the ciphertext (encrypt-then-MAC)

    /// Streaming HMAC accumulator. We MAC the ciphertext only — the header is
    /// deliberately NOT covered (matching Android; MAC-ing it would fail
    /// verification against existing backups).
    struct HMACAccumulator {
        private var hmac: HMAC<SHA256>
        init(key: SymmetricKey) { hmac = HMAC<SHA256>(key: key) }
        mutating func update(_ data: Data) { hmac.update(data: data) }
        func finalize() -> Data { Data(hmac.finalize()) }
    }

    /// Constant-time 32-byte comparison for the trailer. A short-circuiting `==`
    /// on `Data` would leak timing about how many leading bytes matched.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        let ab = Array(a), bb = Array(b)
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    static func randomBytes(_ count: Int) -> Data {
        ChunkedCipher.randomBytes(count: count)
    }
}
