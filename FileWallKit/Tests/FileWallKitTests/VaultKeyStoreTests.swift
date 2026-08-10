import XCTest
import CryptoKit
@testable import FileWallKit

/// Secure Enclave and Keychain tests. Unlike the ChunkedCipher/PortableArchive
/// suites, these cannot run in a plain `swift test` on a Linux CI box or an
/// entitlement-less macOS process — they need real SE hardware and a Keychain
/// access group, i.e. a signed run on a device or an appropriately entitled
/// host. Each guards on availability and `XCTSkip`s otherwise, so the suite stays
/// green everywhere while still exercising the real path where it can.
final class VaultKeyStoreTests: XCTestCase {

    private func skipUnlessSecureEnclave() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave unavailable in this test host")
        }
    }

    func testWrapUnwrapRoundTrip() async throws {
        try skipUnlessSecureEnclave()
        // Requires the test host to carry the keychain-access-group entitlement
        // matching this identifier; skipped implicitly if Keychain ops fail.
        let store = VaultKeyStore(accessGroup: "test.filewall.group")
        do {
            let key1 = try await store.vaultKey(for: .standard)
            let key2 = try await store.vaultKey(for: .standard) // second read unwraps the same key
            XCTAssertEqual(key1.withUnsafeBytes { Data($0) },
                           key2.withUnsafeBytes { Data($0) })
            try await store.destroyKey(for: .standard)
        } catch CryptoError.keychain(let status) {
            throw XCTSkip("Keychain unavailable in this host (OSStatus \(status)); needs a signed run")
        }
    }

    func testStandardAndHiddenKeysDiffer() async throws {
        try skipUnlessSecureEnclave()
        let store = VaultKeyStore(accessGroup: "test.filewall.group")
        do {
            let standard = try await store.vaultKey(for: .standard)
            let hidden = try await store.vaultKey(for: .hidden) // may prompt biometrics on-device
            XCTAssertNotEqual(standard.withUnsafeBytes { Data($0) },
                              hidden.withUnsafeBytes { Data($0) })
            try await store.destroyKey(for: .standard)
            try await store.destroyKey(for: .hidden)
        } catch CryptoError.keychain(let status) {
            throw XCTSkip("Keychain unavailable in this host (OSStatus \(status)); needs a signed run")
        }
    }

    // Key invalidation on biometric re-enrolment (the `.biometryCurrentSet`
    // guarantee) cannot be reproduced in an automated test: it requires a human
    // to add a Face ID / Touch ID enrolment between the wrap and the unwrap. It is
    // verified manually on-device — enrol a new finger, then confirm the hidden
    // vault key fails to unwrap. Documented here so the gap is explicit, not
    // forgotten.
    func testBiometricInvalidationIsManualOnly() throws {
        throw XCTSkip("Biometric re-enrolment invalidation is verified manually on-device (see comment).")
    }
}
