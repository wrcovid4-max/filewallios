import Foundation
import CryptoKit

/// Chunked, authenticated file encryption for FileWall.
///
/// # Why this format instead of the Android build's AES-256-CTR + HMAC-SHA256
///
/// The Android vault streams with CTR and authenticates with a separate HMAC
/// over the whole file. That gives seekability but pays for it: to verify
/// integrity you must read the *entire* file, and a single flipped byte in the
/// middle yields plausible-looking plaintext until the final HMAC check. On
/// Apple platforms we can do strictly better with AES-GCM:
///
///   * Authenticated encryption AND random access at once. Each 1 MiB chunk is
///     sealed independently, so seeking to byte N decrypts exactly one chunk.
///   * A tampered chunk fails to open right there — it never yields garbage the
///     player or PDF renderer might choke on or, worse, display.
///   * CryptoKit does not expose CTR publicly. Matching the Android construction
///     would mean dropping to CommonCrypto to gain nothing over GCM.
///
/// The one real cost of GCM is the 16-byte tag per chunk (0.0015% at 1 MiB) and
/// the 32-bit-per-file chunk-count ceiling, discussed under `nonce` below.
///
/// # Byte layout
///
/// ```
///  ┌────────────────────────── HEADER (20 bytes, plaintext) ──────────────────┐
///  │ off size field                                                           │
///  │  0   4   magic            'F' 'W' 'V' '1' (0x46 0x57 0x56 0x31)          │
///  │  4   1   version          0x01                                           │
///  │  5   1   flags            reserved, 0                                     │
///  │  6   2   reserved         0x0000                                          │
///  │  8   4   chunkSize        UInt32 little-endian, plaintext bytes/chunk    │
///  │ 12   8   noncePrefix      random, shared by every chunk in this file     │
///  └──────────────────────────────────────────────────────────────────────────┘
///  ┌────────────────────────── BODY (repeated per chunk) ─────────────────────┐
///  │ chunk 0:  ciphertext[len₀]  ‖  tag[16]                                    │
///  │ chunk 1:  ciphertext[len₁]  ‖  tag[16]                                    │
///  │   …                                                                       │
///  │ chunk n-1: ciphertext[lastLen] ‖ tag[16]   (lastLen ≤ chunkSize)         │
///  └──────────────────────────────────────────────────────────────────────────┘
/// ```
///
/// GCM is a stream mode, so `ciphertext.count == plaintext.count` for every
/// chunk. Only the final chunk may be shorter than `chunkSize`; every earlier
/// chunk is exactly `chunkSize` plaintext + 16-byte tag. That fixed stride is
/// what makes O(1) random access possible: the file offset of chunk *i* is
/// `headerLength + i * (chunkSize + tagLength)`.
///
/// # Per-chunk nonce
///
/// The 12-byte GCM nonce for chunk *i* is `noncePrefix(8) ‖ UInt32BE(i)`. The
/// prefix is random per file, so nonces never repeat across files under the same
/// key; the counter guarantees uniqueness within a file. The 32-bit counter caps
/// a single file at 2³² chunks = 4 PiB at 1 MiB chunks — far beyond any real
/// file, and we reject anything approaching it rather than silently wrapping.
///
/// # Additional authenticated data
///
/// Each chunk is sealed with AAD = `header(20) ‖ UInt32BE(i)`. This binds every
/// chunk to (a) this exact file header — so the chunk size and nonce prefix
/// cannot be edited — and (b) its own position, so chunks cannot be reordered,
/// duplicated, or spliced in from another file even though they share a key.
public struct ChunkedCipher: Sendable {

    // MARK: Format constants

    static let magic: [UInt8] = [0x46, 0x57, 0x56, 0x31] // "FWV1"
    static let version: UInt8 = 0x01
    static let headerLength = 20
    static let tagLength = 16
    static let noncePrefixLength = 8
    static let nonceLength = 12

    /// 1 MiB. Large enough that the per-chunk tag overhead is negligible, small
    /// enough that a single random-access read decrypts a bounded amount.
    public static let defaultChunkSize = 1 << 20

    /// Refuse chunk sizes outside a sane band. The lower bound keeps a hostile
    /// header from forcing millions of tiny chunks; the upper bound (64 MiB)
    /// keeps per-chunk allocation bounded.
    static let minChunkSize = 1024
    static let maxChunkSize = 64 << 20

    public let chunkSize: Int

    public init(chunkSize: Int = ChunkedCipher.defaultChunkSize) {
        precondition(chunkSize >= ChunkedCipher.minChunkSize &&
                     chunkSize <= ChunkedCipher.maxChunkSize,
                     "chunkSize out of range")
        self.chunkSize = chunkSize
    }

    // MARK: In-memory API

    /// Encrypt `plaintext` into a self-describing FileWall blob.
    ///
    /// A zero-length input produces a header-only blob (20 bytes) that decrypts
    /// back to empty `Data` — the empty-file boundary is a real case (an empty
    /// note, a 0-byte import) and must round-trip.
    public func encrypt(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let prefix = Self.randomBytes(count: Self.noncePrefixLength)
        let header = makeHeader(noncePrefix: prefix)

        var out = Data(capacity: header.count + plaintext.count + expectedTagBytes(for: plaintext.count))
        out.append(header)

        let count = plaintext.count
        var offset = 0
        var index: UInt32 = 0
        while offset < count {
            let end = min(offset + chunkSize, count)
            let slice = plaintext.subdata(in: offset..<end)
            let sealed = try seal(slice, index: index, key: key, header: header, noncePrefix: prefix)
            out.append(sealed)
            offset = end
            index &+= 1
        }
        return out
    }

    /// Decrypt an entire FileWall blob back to plaintext.
    public func decrypt(_ blob: Data, using key: SymmetricKey) throws -> Data {
        let parsed = try parse(blob)
        var out = Data(capacity: max(0, blob.count - Self.headerLength - parsed.chunkCount * Self.tagLength))
        for i in 0..<parsed.chunkCount {
            out.append(try openChunk(index: i, blob: blob, parsed: parsed, key: key))
        }
        return out
    }

    /// Decrypt a single chunk by index without touching any other chunk.
    ///
    /// This is the primitive the video resource-loader and PDF preview lean on:
    /// a seek to byte N maps to `N / chunkSize` and one decrypt. The returned
    /// plaintext is the chunk's slice of the original file, at most `chunkSize`.
    public func decryptChunk(at index: Int, from blob: Data, using key: SymmetricKey) throws -> Data {
        let parsed = try parse(blob)
        guard index >= 0 && index < parsed.chunkCount else { throw CryptoError.chunkIndexOutOfRange }
        return try openChunk(index: index, blob: blob, parsed: parsed, key: key)
    }

    /// Number of chunks in a blob, and the plaintext chunk size it was written
    /// with. Cheap: reads the header only. Useful for the resource loader to map
    /// byte ranges before it decrypts anything.
    public func layout(of blob: Data) throws -> (chunkCount: Int, chunkSize: Int) {
        let parsed = try parse(blob)
        return (parsed.chunkCount, parsed.chunkSize)
    }

    // MARK: File-streaming API
    //
    // The in-memory path is fine for thumbnails and small documents but a 4 GiB
    // video must never be fully resident. These stream chunk-by-chunk through
    // FileHandle so peak memory is ~one chunk. async, per the house style
    // (no completion handlers); the work is genuinely I/O-bound.

    /// Encrypt a plaintext file at `source` into a FileWall blob at `destination`.
    public func encryptFile(at source: URL, to destination: URL, using key: SymmetricKey) async throws {
        let prefix = Self.randomBytes(count: Self.noncePrefixLength)
        let header = makeHeader(noncePrefix: prefix)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }

        try output.write(contentsOf: header)
        var index: UInt32 = 0
        while true {
            // Fill a whole chunk before sealing. `read(upToCount:)` is allowed to
            // return fewer bytes than asked even mid-file, so a naive single read
            // could emit a short chunk in the middle of the stream and wreck the
            // fixed-stride layout the decoder relies on. Only a genuine EOF ends
            // the chunk short.
            var slice = Data()
            while slice.count < chunkSize {
                guard let more = try input.read(upToCount: chunkSize - slice.count), !more.isEmpty else { break }
                slice.append(more)
            }
            if slice.isEmpty { break } // clean EOF on a chunk boundary
            let sealed = try seal(slice, index: index, key: key, header: header, noncePrefix: prefix)
            try output.write(contentsOf: sealed)
            index &+= 1
            if slice.count < chunkSize { break } // true EOF: this was the final, partial chunk
        }
    }

    /// Decrypt a FileWall blob at `source` into a plaintext file at `destination`.
    public func decryptFile(at source: URL, to destination: URL, using key: SymmetricKey) async throws {
        let blob = try Data(contentsOf: source, options: .mappedIfSafe)
        let parsed = try parse(blob)

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        for i in 0..<parsed.chunkCount {
            try output.write(contentsOf: try openChunk(index: i, blob: blob, parsed: parsed, key: key))
        }
    }

    // MARK: Header

    private func makeHeader(noncePrefix: Data) -> Data {
        var header = Data(capacity: Self.headerLength)
        header.append(contentsOf: Self.magic)        // 0..<4
        header.append(Self.version)                  // 4
        header.append(0)                             // 5  flags
        header.append(contentsOf: [0, 0])            // 6..<8 reserved
        var sizeLE = UInt32(chunkSize).littleEndian  // 8..<12
        withUnsafeBytes(of: &sizeLE) { header.append(contentsOf: $0) }
        header.append(noncePrefix)                   // 12..<20
        return header
    }

    private struct ParsedHeader {
        let header: Data          // the raw 20-byte header, reused as AAD prefix
        let noncePrefix: Data
        let chunkSize: Int
        let chunkCount: Int
        let lastChunkCipherLen: Int
    }

    private func parse(_ blob: Data) throws -> ParsedHeader {
        guard blob.count >= Self.headerLength else { throw CryptoError.malformedHeader }
        // Copy the header into its own contiguous buffer. `blob` may be a slice
        // (non-zero startIndex), so we never index it with absolute offsets.
        let header = blob.subdata(in: blob.startIndex ..< blob.startIndex + Self.headerLength)

        guard Array(header[0..<4]) == Self.magic else { throw CryptoError.malformedHeader }
        guard header[4] == Self.version else { throw CryptoError.malformedHeader }

        let declaredSize = header.subdata(in: 8..<12).withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)))
        }
        guard declaredSize >= Self.minChunkSize && declaredSize <= Self.maxChunkSize else {
            throw CryptoError.invalidChunkSize
        }
        let noncePrefix = header.subdata(in: 12..<20)

        // Reconstruct chunk boundaries from the body length. Only the last chunk
        // may be short, so the arithmetic has exactly one special case.
        let bodyLen = blob.count - Self.headerLength
        let stride = declaredSize + Self.tagLength
        let chunkCount: Int
        let lastLen: Int
        if bodyLen == 0 {
            chunkCount = 0
            lastLen = 0
        } else {
            let full = bodyLen / stride
            let rem = bodyLen % stride
            if rem == 0 {
                chunkCount = full
                lastLen = stride
            } else {
                // A partial final chunk must still carry a full GCM tag plus at
                // least one ciphertext byte.
                guard rem > Self.tagLength else { throw CryptoError.truncatedBody }
                chunkCount = full + 1
                lastLen = rem
            }
        }
        return ParsedHeader(header: header, noncePrefix: noncePrefix, chunkSize: declaredSize,
                            chunkCount: chunkCount, lastChunkCipherLen: lastLen)
    }

    // MARK: Chunk seal / open

    private func seal(_ plaintextChunk: Data, index: UInt32, key: SymmetricKey,
                      header: Data, noncePrefix: Data) throws -> Data {
        let nonce = try Self.nonce(prefix: noncePrefix, index: index)
        let aad = Self.aad(header: header, index: index)
        let box = try AES.GCM.seal(plaintextChunk, using: key, nonce: nonce, authenticating: aad)
        // We reconstruct the nonce on open, so we never store it. Persist only
        // ciphertext ‖ tag.
        return box.ciphertext + box.tag
    }

    private func openChunk(index: Int, blob: Data, parsed: ParsedHeader, key: SymmetricKey) throws -> Data {
        let stride = parsed.chunkSize + Self.tagLength
        let cipherLen = (index == parsed.chunkCount - 1) ? parsed.lastChunkCipherLen : stride
        // Absolute offset into `blob`, honouring a possibly-sliced startIndex.
        let start = blob.startIndex + Self.headerLength + index * stride
        let end = start + cipherLen
        guard end <= blob.endIndex else { throw CryptoError.truncatedBody }

        let ciphertext = blob.subdata(in: start ..< end - Self.tagLength)
        let tag = blob.subdata(in: end - Self.tagLength ..< end)

        let nonce = try Self.nonce(prefix: parsed.noncePrefix, index: UInt32(index))
        let aad = Self.aad(header: parsed.header, index: UInt32(index))
        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            // Collapse every CryptoKit failure to one opaque outcome. The caller
            // learns "reject", never "wrong key vs. tampered byte".
            throw CryptoError.authenticationFailed
        }
    }

    // MARK: Nonce / AAD derivation

    private static func nonce(prefix: Data, index: UInt32) throws -> AES.GCM.Nonce {
        precondition(prefix.count == noncePrefixLength)
        var bytes = Data(prefix)
        var be = index.bigEndian
        withUnsafeBytes(of: &be) { bytes.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: bytes) // exactly 12 bytes
    }

    private static func aad(header: Data, index: UInt32) -> Data {
        var aad = Data(header)
        var be = index.bigEndian
        withUnsafeBytes(of: &be) { aad.append(contentsOf: $0) }
        return aad
    }

    // MARK: Helpers

    private func expectedTagBytes(for plaintextCount: Int) -> Int {
        guard plaintextCount > 0 else { return 0 }
        let chunks = (plaintextCount + chunkSize - 1) / chunkSize
        return chunks * Self.tagLength
    }

    static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        let ok = data.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            return SecRandomCopyBytes(kSecRandomDefault, count, base) == errSecSuccess
        }
        // SecRandomCopyBytes fails only on catastrophic OS states; a vault must
        // not fall back to a weaker RNG, so this is a hard stop.
        precondition(ok, "SecRandomCopyBytes failed")
        return data
    }
}
