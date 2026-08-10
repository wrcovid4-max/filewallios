import XCTest
import CryptoKit
@testable import FileWallKit

/// The crypto suite the prompt calls out as "where to spend your patience".
/// Everything here runs on macOS without a simulator — that is why FileWallKit
/// builds for macOS at all.
final class ChunkedCipherTests: XCTestCase {

    private let key = SymmetricKey(size: .bits256)

    private func randomData(_ count: Int) -> Data {
        var d = Data(count: count)
        d.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return d
    }

    // MARK: Round-trip across chunk boundaries
    //
    // The off-by-one at the chunk boundary is the bug that bites, so the sizes
    // are chosen to straddle it exactly: empty, one byte, one short of a chunk,
    // exactly a chunk, and one past a chunk.

    func testRoundTripAcrossChunkBoundaries() throws {
        let chunk = ChunkedCipher.defaultChunkSize
        let sizes = [0, 1, chunk - 1, chunk, chunk + 1]
        let cipher = ChunkedCipher()

        for size in sizes {
            let plaintext = randomData(size)
            let blob = try cipher.encrypt(plaintext, using: key)
            let restored = try cipher.decrypt(blob, using: key)
            XCTAssertEqual(restored, plaintext, "round-trip failed for size \(size)")
        }
    }

    func testEmptyFileIsHeaderOnly() throws {
        let cipher = ChunkedCipher()
        let blob = try cipher.encrypt(Data(), using: key)
        XCTAssertEqual(blob.count, ChunkedCipher.headerLength)
        XCTAssertEqual(try cipher.decrypt(blob, using: key), Data())
        XCTAssertEqual(try cipher.layout(of: blob).chunkCount, 0)
    }

    func testMultiChunkChunkCount() throws {
        // Small chunk size keeps the test cheap while still exercising many chunks.
        let cipher = ChunkedCipher(chunkSize: 1024)
        let plaintext = randomData(1024 * 4 + 7) // 5 chunks, last is partial
        let blob = try cipher.encrypt(plaintext, using: key)
        XCTAssertEqual(try cipher.layout(of: blob).chunkCount, 5)
        XCTAssertEqual(try cipher.decrypt(blob, using: key), plaintext)
    }

    // MARK: Tampering — every flipped byte must fail to open

    func testTamperHeaderFailsToOpen() throws {
        let cipher = ChunkedCipher(chunkSize: 1024)
        var blob = try cipher.encrypt(randomData(4096), using: key)
        // Flip a byte inside the random nonce-prefix region (offset 12..<20). It
        // is authenticated as AAD, so this must be rejected rather than yielding
        // garbage.
        blob[15] ^= 0xFF
        XCTAssertThrowsError(try cipher.decrypt(blob, using: key)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTamperFirstChunkFailsToOpen() throws {
        let cipher = ChunkedCipher(chunkSize: 1024)
        var blob = try cipher.encrypt(randomData(4096), using: key)
        blob[ChunkedCipher.headerLength] ^= 0x01 // first ciphertext byte
        XCTAssertThrowsError(try cipher.decrypt(blob, using: key)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTamperLastChunkFailsToOpen() throws {
        let cipher = ChunkedCipher(chunkSize: 1024)
        var blob = try cipher.encrypt(randomData(4096), using: key)
        blob[blob.count - 1] ^= 0x01 // last byte of the final tag
        XCTAssertThrowsError(try cipher.decrypt(blob, using: key)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testWrongKeyFailsToOpen() throws {
        let cipher = ChunkedCipher(chunkSize: 1024)
        let blob = try cipher.encrypt(randomData(4096), using: key)
        XCTAssertThrowsError(try cipher.decrypt(blob, using: SymmetricKey(size: .bits256))) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    // MARK: Random access

    func testRandomAccessMatchesWholeFileDecrypt() throws {
        let chunkSize = 1024
        let cipher = ChunkedCipher(chunkSize: chunkSize)
        let plaintext = randomData(chunkSize * 5 + 300)
        let blob = try cipher.encrypt(plaintext, using: key)

        // Decrypt a middle chunk without having touched earlier ones.
        let middleIndex = 2
        let middle = try cipher.decryptChunk(at: middleIndex, from: blob, using: key)

        let start = middleIndex * chunkSize
        let expected = plaintext.subdata(in: start ..< start + chunkSize)
        XCTAssertEqual(middle, expected)

        // And the partial final chunk.
        let lastIndex = try cipher.layout(of: blob).chunkCount - 1
        let last = try cipher.decryptChunk(at: lastIndex, from: blob, using: key)
        XCTAssertEqual(last, plaintext.subdata(in: lastIndex * chunkSize ..< plaintext.count))
    }

    func testRandomAccessOutOfRange() throws {
        let cipher = ChunkedCipher(chunkSize: 1024)
        let blob = try cipher.encrypt(randomData(2048), using: key)
        XCTAssertThrowsError(try cipher.decryptChunk(at: 99, from: blob, using: key)) { error in
            XCTAssertEqual(error as? CryptoError, .chunkIndexOutOfRange)
        }
    }

    // MARK: Malformed input

    func testShortBlobIsMalformed() throws {
        let cipher = ChunkedCipher()
        XCTAssertThrowsError(try cipher.decrypt(Data([0x46, 0x57]), using: key)) { error in
            XCTAssertEqual(error as? CryptoError, .malformedHeader)
        }
    }

    func testBadMagicIsMalformed() throws {
        let cipher = ChunkedCipher()
        var blob = try cipher.encrypt(randomData(100), using: key)
        blob[0] = 0x00
        XCTAssertThrowsError(try cipher.decrypt(blob, using: key)) { error in
            XCTAssertEqual(error as? CryptoError, .malformedHeader)
        }
    }

    // MARK: File-streaming path parity

    func testFileStreamingMatchesInMemory() async throws {
        let cipher = ChunkedCipher(chunkSize: 1024)
        let plaintext = randomData(1024 * 3 + 11)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plainURL = dir.appendingPathComponent("plain")
        let blobURL = dir.appendingPathComponent("blob")
        let outURL = dir.appendingPathComponent("out")
        try plaintext.write(to: plainURL)

        try await cipher.encryptFile(at: plainURL, to: blobURL, using: key)
        // A streamed blob must be openable by the in-memory decryptor and vice-versa.
        XCTAssertEqual(try cipher.decrypt(Data(contentsOf: blobURL), using: key), plaintext)

        try await cipher.decryptFile(at: blobURL, to: outURL, using: key)
        XCTAssertEqual(try Data(contentsOf: outURL), plaintext)
    }

    // A file whose length is an exact multiple of the chunk size must not emit a
    // spurious trailing empty chunk from the streaming encoder.
    func testFileStreamingExactMultiple() async throws {
        let cipher = ChunkedCipher(chunkSize: 1024)
        let plaintext = randomData(1024 * 2)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plainURL = dir.appendingPathComponent("plain")
        let blobURL = dir.appendingPathComponent("blob")
        try plaintext.write(to: plainURL)

        try await cipher.encryptFile(at: plainURL, to: blobURL, using: key)
        let blob = try Data(contentsOf: blobURL)
        XCTAssertEqual(try cipher.layout(of: blob).chunkCount, 2)
        XCTAssertEqual(try cipher.decrypt(blob, using: key), plaintext)
    }
}
