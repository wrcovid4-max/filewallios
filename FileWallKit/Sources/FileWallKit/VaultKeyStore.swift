import Foundation
import CryptoKit
import Security
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Which side of the vault a key belongs to. The hidden side gets a stricter
/// access-control policy (biometrics required, invalidated on re-enrolment).
public enum VaultSide: String, Sendable {
    case standard
    case hidden
}

/// Manages the per-vault AES key and its wrapping by a Secure Enclave P-256 key.
///
/// # Why a P-256 key wraps an AES key (this looks like indirection — it isn't)
///
/// The Secure Enclave will only ever hold P-256 keys; it cannot store or operate
/// on a raw 256-bit AES key. So we cannot "put the vault key in the enclave".
/// The correct, Apple-blessed pattern is instead:
///
///   1. Generate a random 256-bit AES vault key in memory.
///   2. Generate (once) a P-256 key that lives *inside* the enclave — its private
///      scalar never leaves hardware.
///   3. Wrap the AES key by ECDH-ing an ephemeral P-256 key against the enclave
///      key's public half, running the shared secret through HKDF to get a
///      256-bit wrapping key, and AES-GCM-sealing the vault key with it.
///   4. Persist only { ephemeral public key, sealed vault key } in the Keychain.
///
/// To unwrap we ECDH the *enclave* private key (in hardware, gated by the access
/// control) against the stored ephemeral public key, arriving at the identical
/// shared secret, re-deriving the wrapping key, and opening the box. The vault
/// key therefore only exists in plaintext while the device is unlocked and — for
/// the hidden side — the user has just passed biometrics.
///
/// This is strictly stronger than the Android build's "AES key in the Android
/// Keystore" because the unwrap is bound to enclave hardware and (hidden side) to
/// the current biometric enrolment.
public actor VaultKeyStore {

    // MARK: Configuration

    /// Keychain access group shared across the app, widgets and watch extension
    /// so all targets can reach the *wrapped* key (never the plaintext key).
    /// Passed in rather than hard-coded so the value lives in one entitlements
    /// file and is injected at app start.
    private let accessGroup: String
    private let service: String

    public init(accessGroup: String, service: String = "com.filewall.vaultkey") {
        self.accessGroup = accessGroup
        self.service = service
    }

    // Fixed HKDF salt/info. These need not be secret; they domain-separate this
    // KDF use from any other and are constant so unwrap reproduces the wrap.
    private static let hkdfSalt = Data("FileWall.SEwrap.v1.salt".utf8)
    private static let hkdfInfo = Data("FileWall.SEwrap.v1.info".utf8)

    // MARK: Public surface

    /// Fetch the vault key for `side`, generating and wrapping a fresh one on
    /// first use. For the hidden side the Keychain read triggers the biometric
    /// prompt (that is where `.biometryCurrentSet` bites), so callers should only
    /// invoke this after the user has asked to enter the hidden vault.
    public func vaultKey(for side: VaultSide) throws -> SymmetricKey {
        if let wrapped = try loadWrappedKey(for: side) {
            let enclaveKey = try loadEnclaveKey(for: side)
            return try unwrap(wrapped, using: enclaveKey)
        }
        return try createAndStoreVaultKey(for: side)
    }

    /// Remove both the wrapped vault key and its enclave key for `side`. Used by
    /// "reset vault" and by the hidden-vault destroy path. Irreversible: without
    /// the enclave key the ciphertext on disk is unrecoverable, which is the
    /// point.
    public func destroyKey(for side: VaultSide) throws {
        try deleteKeychainItem(account: wrappedAccount(side))
        try deleteKeychainItem(account: enclaveAccount(side))
    }

    // MARK: Create / wrap

    private func createAndStoreVaultKey(for side: VaultSide) throws -> SymmetricKey {
        let enclaveKey = try createEnclaveKey(for: side)
        let vaultKey = SymmetricKey(size: .bits256)
        let wrapped = try wrap(vaultKey, using: enclaveKey)
        try storeKeychainItem(account: wrappedAccount(side), data: wrapped, side: side)
        return vaultKey
    }

    private func wrap(_ vaultKey: SymmetricKey, using enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
        let wrappingKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Self.hkdfSalt, sharedInfo: Self.hkdfInfo, outputByteCount: 32)

        let raw = vaultKey.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(raw, using: wrappingKey)
        guard let combined = sealed.combined else { throw CryptoError.authenticationFailed }

        // Persist: ephemeralPublicKey.x963 ‖ sealedBox.combined. The ephemeral
        // public key is the other half the enclave needs to reproduce the shared
        // secret; it is not secret.
        let ephPub = ephemeral.publicKey.x963Representation
        var out = Data()
        var len = UInt16(ephPub.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(ephPub)
        out.append(combined)
        return out
    }

    private func unwrap(_ wrapped: Data, using enclaveKey: SecureEnclave.P256.KeyAgreement.PrivateKey) throws -> SymmetricKey {
        guard wrapped.count > 2 else { throw CryptoError.malformedHeader }
        let ephLen = Int(wrapped.subdata(in: 0..<2).withUnsafeBytes {
            UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self))
        })
        guard wrapped.count > 2 + ephLen else { throw CryptoError.malformedHeader }
        let ephPub = wrapped.subdata(in: 2 ..< 2 + ephLen)
        let combined = wrapped.subdata(in: 2 + ephLen ..< wrapped.count)

        let ephemeralPublic = try P256.KeyAgreement.PublicKey(x963Representation: ephPub)
        // The private half of this agreement is in the enclave; this call is what
        // the access control (and, hidden side, biometrics) gates.
        let shared = try enclaveKey.sharedSecretFromKeyAgreement(with: ephemeralPublic)
        let wrappingKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: Self.hkdfSalt, sharedInfo: Self.hkdfInfo, outputByteCount: 32)

        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            let raw = try AES.GCM.open(box, using: wrappingKey)
            return SymmetricKey(data: raw)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }

    // MARK: Secure Enclave key lifecycle

    private func createEnclaveKey(for side: VaultSide) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        guard SecureEnclave.isAvailable else { throw CryptoError.secureEnclaveUnavailable }

        var acError: Unmanaged<CFError>?
        // Standard side: usable whenever the device is unlocked, this device only.
        // Hidden side: additionally require the *current* biometric set — adding a
        // new face/finger invalidates the key and the hidden vault becomes
        // unrecoverable to the new enrolment. For a vault that is the desired
        // behaviour, not an inconvenience.
        let flags: SecAccessControlCreateFlags =
            side == .hidden ? [.privateKeyUsage, .biometryCurrentSet] : [.privateKeyUsage]
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly, // out of iCloud Keychain & backups
            flags,
            &acError) else {
            throw CryptoError.secureEnclaveUnavailable
        }

        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        // `dataRepresentation` is an opaque, enclave-bound blob (NOT the private
        // scalar) that we can persist and later rehydrate on the same device.
        try storeKeychainItem(account: enclaveAccount(side), data: key.dataRepresentation, side: side)
        return key
    }

    private func loadEnclaveKey(for side: VaultSide) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
        guard let data = try loadKeychainItem(account: enclaveAccount(side)) else {
            throw CryptoError.secureEnclaveUnavailable
        }
        return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: data)
    }

    private func loadWrappedKey(for side: VaultSide) throws -> Data? {
        try loadKeychainItem(account: wrappedAccount(side))
    }

    // MARK: Keychain plumbing
    //
    // Both stored items — the enclave-key blob and the wrapped vault key — use
    // kSecAttrAccessibleWhenUnlockedThisDeviceOnly + the shared access group. The
    // access-control object on the enclave *key* is what enforces biometrics; the
    // generic-password items just hold bytes.

    private func wrappedAccount(_ side: VaultSide) -> String { "wrapped.\(side.rawValue)" }
    private func enclaveAccount(_ side: VaultSide) -> String { "enclave.\(side.rawValue)" }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }

    private func storeKeychainItem(account: String, data: Data, side: VaultSide) throws {
        try deleteKeychainItem(account: account) // idempotent create-or-replace
        var attrs = baseQuery(account: account)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw CryptoError.keychain(status) }
    }

    private func loadKeychainItem(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CryptoError.keychain(status) }
        return out as? Data
    }

    private func deleteKeychainItem(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CryptoError.keychain(status)
        }
    }
}
