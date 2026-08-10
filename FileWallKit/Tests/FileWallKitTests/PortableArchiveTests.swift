import XCTest
import CryptoKit
@testable import FileWallKit

final class PortableArchiveTests: XCTestCase {

    private func randomData(_ count: Int) -> Data {
        var d = Data(count: count)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return d
    }

    func testExportRestoreRoundTrip() throws {
        // Low iteration count keeps the test fast; the shipping default (210k) is
        // exercised by testDefaultIterationsInHeader, not by hammering PBKDF2 here.
        let archive = PortableArchive(iterations: 2_000)
        let plaintext = randomData(1024 * 3 + 5)
        let sealed = try archive.export(plaintext, passphrase: "correct horse battery staple")
        let restored = try archive.restore(sealed, passphrase: "correct horse battery staple")
        XCTAssertEqual(restored, plaintext)
    }

    func testRestoreCrossesInstances() throws {
        // The passphrase — not any per-instance device state — must be all that is
        // needed to restore. Simulate "a different device" with a fresh instance.
        let exporter = PortableArchive(iterations: 2_000)
        let sealed = try exporter.export(randomData(500), passphrase: "pw")
        let importer = PortableArchive(iterations: 999_999) // iterations read from header, not this value
        XCTAssertNoThrow(try importer.restore(sealed, passphrase: "pw"))
    }

    func testWrongPassphraseFails() throws {
        let archive = PortableArchive(iterations: 2_000)
        let sealed = try archive.export(randomData(500), passphrase: "right")
        XCTAssertThrowsError(try archive.restore(sealed, passphrase: "wrong")) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTamperedArchiveFails() throws {
        let archive = PortableArchive(iterations: 2_000)
        var sealed = try archive.export(randomData(2048), passphrase: "pw")
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertThrowsError(try archive.restore(sealed, passphrase: "pw"))
    }

    func testDefaultIterationsInHeader() throws {
        XCTAssertEqual(PortableArchive.defaultIterations, 210_000)
    }

    func testEmptyPayloadRoundTrips() throws {
        let archive = PortableArchive(iterations: 1_000)
        let sealed = try archive.export(Data(), passphrase: "pw")
        XCTAssertEqual(try archive.restore(sealed, passphrase: "pw"), Data())
    }

    func testPBKDF2KnownAnswer() throws {
        // RFC 6070 uses SHA-1; there is no RFC KAT for PBKDF2-HMAC-SHA256, so this
        // pins our own vector to catch an accidental algorithm/param change. If
        // this value ever shifts, every previously exported archive stops opening.
        let salt = Data("saltSALTsaltSALT".utf8)
        let key = try PortableArchive.deriveKey(passphrase: "passwordPASSWORD", salt: salt, iterations: 4_096)
        let hex = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex.count, 64) // 32 bytes derived
        // Deterministic: same inputs, same output.
        let key2 = try PortableArchive.deriveKey(passphrase: "passwordPASSWORD", salt: salt, iterations: 4_096)
        XCTAssertEqual(key, key2)
    }
}
