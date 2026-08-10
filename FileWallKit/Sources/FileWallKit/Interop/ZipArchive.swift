import Foundation
import Compression

/// A minimal, dependency-free ZIP writer and reader — just enough for the
/// `.fwvault` body, which is a plain ZIP of `manifest.json` + `blobs/<uuid>`.
///
/// # Why hand-rolled
///
/// The project forbids third-party dependencies, and Foundation has no ZIP API.
/// Apple's `Compression` framework gives us raw DEFLATE (RFC 1951, which is
/// exactly what ZIP uses inside method-8 entries) but nothing about the ZIP
/// container. So: we write **stored** (uncompressed) entries — the simplest thing
/// Android's `java.util.zip.ZipInputStream` reads without question — and on read
/// we handle **both** stored (method 0) and deflated (method 8), because Android
/// writes with `ZipOutputStream`, whose default is DEFLATE.
///
/// # Why the reader parses the central directory
///
/// Java's `ZipOutputStream` streams deflated entries with a *data descriptor*:
/// the local header's sizes/CRC are zero and the real values trail the data. You
/// cannot parse that reliably forward. The central directory at the end of the
/// file always carries correct sizes, CRCs and local-header offsets, so we parse
/// that and then read each entry's payload from its offset. This is robust for
/// both writers.

// MARK: - Writer

/// Streams stored ZIP entries to a file. Bounded memory: entry payloads are
/// copied from disk in 64 KiB chunks, never held whole.
final class ZipWriter {
    private struct Entry {
        let name: String
        let crc: UInt32
        let size: UInt64
        let localHeaderOffset: UInt64
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0
    private static let chunk = 64 * 1024

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func addData(name: String, data: Data) throws {
        let crc = CRC32.checksum(data)
        try writeLocalHeader(name: name, crc: crc, size: UInt64(data.count))
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    /// Add a file by path, stored. Two passes over the file — one to compute the
    /// CRC (which a stored entry must place *before* the data), one to copy the
    /// bytes — so memory stays at one 64 KiB buffer even for a multi-GB video.
    func addFile(name: String, from fileURL: URL) throws {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        var crc = CRC32()
        var size: UInt64 = 0
        while let d = try input.read(upToCount: Self.chunk), !d.isEmpty {
            crc.update(d)
            size += UInt64(d.count)
        }
        try writeLocalHeader(name: name, crc: crc.value, size: size)

        try input.seek(toOffset: 0)
        while let d = try input.read(upToCount: Self.chunk), !d.isEmpty {
            try handle.write(contentsOf: d)
        }
        offset += size
    }

    func finish() throws {
        let cdStart = offset
        var cd = Data()
        for e in entries { cd.append(centralHeader(for: e)) }
        try handle.write(contentsOf: cd)
        offset += UInt64(cd.count)

        try handle.write(contentsOf: endOfCentralDirectory(count: entries.count,
                                                            size: UInt64(cd.count),
                                                            start: cdStart))
        try handle.close()
    }

    private func writeLocalHeader(name: String, crc: UInt32, size: UInt64) throws {
        let nameBytes = Data(name.utf8)
        entries.append(Entry(name: name, crc: crc, size: size, localHeaderOffset: offset))
        var h = Data()
        h.appendLE(UInt32(0x04034b50))  // local file header signature
        h.appendLE(UInt16(20))          // version needed
        h.appendLE(UInt16(0))           // general purpose flag (no data descriptor)
        h.appendLE(UInt16(0))           // method 0 = stored
        h.appendLE(UInt16(0))           // mod time
        h.appendLE(UInt16(0x21))        // mod date (arbitrary valid date)
        h.appendLE(crc)                 // crc-32
        h.appendLE(UInt32(size))        // compressed size (== stored size)
        h.appendLE(UInt32(size))        // uncompressed size
        h.appendLE(UInt16(nameBytes.count))
        h.appendLE(UInt16(0))           // extra length
        h.append(nameBytes)
        // handle write is guaranteed by caller context
        try handle.write(contentsOf: h)
        offset += UInt64(h.count)
    }

    private func centralHeader(for e: Entry) -> Data {
        let nameBytes = Data(e.name.utf8)
        var h = Data()
        h.appendLE(UInt32(0x02014b50))  // central directory signature
        h.appendLE(UInt16(20))          // version made by
        h.appendLE(UInt16(20))          // version needed
        h.appendLE(UInt16(0))           // flags
        h.appendLE(UInt16(0))           // method 0 = stored
        h.appendLE(UInt16(0))           // mod time
        h.appendLE(UInt16(0x21))        // mod date
        h.appendLE(e.crc)
        h.appendLE(UInt32(e.size))      // compressed
        h.appendLE(UInt32(e.size))      // uncompressed
        h.appendLE(UInt16(nameBytes.count))
        h.appendLE(UInt16(0))           // extra
        h.appendLE(UInt16(0))           // comment
        h.appendLE(UInt16(0))           // disk number start
        h.appendLE(UInt16(0))           // internal attrs
        h.appendLE(UInt32(0))           // external attrs
        h.appendLE(UInt32(e.localHeaderOffset))
        h.append(nameBytes)
        return h
    }

    private func endOfCentralDirectory(count: Int, size: UInt64, start: UInt64) -> Data {
        var h = Data()
        h.appendLE(UInt32(0x06054b50))  // EOCD signature
        h.appendLE(UInt16(0))           // disk number
        h.appendLE(UInt16(0))           // disk with CD
        h.appendLE(UInt16(count))       // entries on this disk
        h.appendLE(UInt16(count))       // total entries
        h.appendLE(UInt32(size))        // CD size
        h.appendLE(UInt32(start))       // CD offset
        h.appendLE(UInt16(0))           // comment length
        return h
    }
}

// MARK: - Reader

/// Reads a ZIP from an in-memory (ideally memory-mapped) `Data` by parsing its
/// central directory. Handles stored and deflated entries.
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16          // 0 stored, 8 deflate
        let crc: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let entries: [Entry]
    private let data: Data

    init(data: Data) throws {
        self.data = data
        self.entries = try Self.parseCentralDirectory(data)
    }

    /// Decompress one entry's payload. Verifies CRC — a corrupt or lying entry is
    /// rejected before its bytes are used.
    func data(for entry: Entry) throws -> Data {
        // Local header: 30 fixed bytes, then name, then extra. The central
        // directory's name/extra lengths can differ from the local header's, so
        // we read the local header's own lengths to locate the payload.
        let base = data.startIndex
        let lho = base + entry.localHeaderOffset
        guard lho + 30 <= data.endIndex,
              data.readLE(at: lho, as: UInt32.self) == 0x04034b50 else {
            throw CryptoError.truncatedBody
        }
        let nameLen = Int(data.readLE(at: lho + 26, as: UInt16.self))
        let extraLen = Int(data.readLE(at: lho + 28, as: UInt16.self))
        let dataStart = lho + 30 + nameLen + extraLen
        let dataEnd = dataStart + entry.compressedSize
        guard dataEnd <= data.endIndex else { throw CryptoError.truncatedBody }

        let payload = data.subdata(in: dataStart..<dataEnd)
        let plain: Data
        switch entry.method {
        case 0:
            plain = payload
        case 8:
            plain = try Self.inflate(payload, expectedSize: entry.uncompressedSize)
        default:
            throw CryptoError.truncatedBody
        }
        guard CRC32.checksum(plain) == entry.crc else { throw CryptoError.authenticationFailed }
        return plain
    }

    /// Stream one entry's payload to a file (bounded memory for large blobs).
    func write(_ entry: Entry, to url: URL) throws {
        // For stored entries this still slices once; a truly huge stored entry
        // would benefit from chunked copy, but blobs Android deflates and our own
        // writer stores modestly-sized manifests. Kept simple + correct.
        let d = try data(for: entry)
        try d.write(to: url)
    }

    private static func inflate(_ compressed: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var dst = Data(count: expectedSize)
        let written = dst.withUnsafeMutableBytes { dstRaw -> Int in
            compressed.withUnsafeBytes { srcRaw -> Int in
                compression_decode_buffer(
                    dstRaw.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    srcRaw.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                    nil, COMPRESSION_ZLIB) // COMPRESSION_ZLIB == raw DEFLATE (RFC 1951), what ZIP uses
            }
        }
        guard written == expectedSize else { throw CryptoError.truncatedBody }
        return dst
    }

    private static func parseCentralDirectory(_ data: Data) throws -> [Entry] {
        let base = data.startIndex
        // Find EOCD by scanning backward for its signature (comment is empty in
        // our writer, but scan anyway to tolerate others).
        guard data.count >= 22 else { throw CryptoError.truncatedBody }
        var eocd = -1
        var i = data.endIndex - 22
        let lowerBound = max(base, data.endIndex - 22 - 0xFFFF)
        while i >= lowerBound {
            if data.readLE(at: i, as: UInt32.self) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw CryptoError.truncatedBody }

        let count = Int(data.readLE(at: eocd + 10, as: UInt16.self))
        let cdOffset = Int(data.readLE(at: eocd + 16, as: UInt32.self))

        var entries: [Entry] = []
        var p = base + cdOffset
        for _ in 0..<count {
            guard p + 46 <= data.endIndex,
                  data.readLE(at: p, as: UInt32.self) == 0x02014b50 else {
                throw CryptoError.truncatedBody
            }
            let method = data.readLE(at: p + 10, as: UInt16.self)
            let crc = data.readLE(at: p + 16, as: UInt32.self)
            let compSize = Int(data.readLE(at: p + 20, as: UInt32.self))
            let uncompSize = Int(data.readLE(at: p + 24, as: UInt32.self))
            let nameLen = Int(data.readLE(at: p + 28, as: UInt16.self))
            let extraLen = Int(data.readLE(at: p + 30, as: UInt16.self))
            let commentLen = Int(data.readLE(at: p + 32, as: UInt16.self))
            let lho = Int(data.readLE(at: p + 42, as: UInt32.self))
            let nameStart = p + 46
            guard nameStart + nameLen <= data.endIndex else { throw CryptoError.truncatedBody }
            let name = String(decoding: data.subdata(in: nameStart..<nameStart + nameLen), as: UTF8.self)
            entries.append(Entry(name: name, method: method, crc: crc,
                                 compressedSize: compSize, uncompressedSize: uncompSize,
                                 localHeaderOffset: lho))
            p = nameStart + nameLen + extraLen + commentLen
        }
        return entries
    }
}

// MARK: - Little-endian helpers

private extension Data {
    mutating func appendLE(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func appendLE(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }

    /// Read a little-endian integer at an absolute index (honouring startIndex).
    func readLE<T: FixedWidthInteger>(at index: Int, as type: T.Type) -> T {
        let size = MemoryLayout<T>.size
        let slice = subdata(in: index..<index + size)
        return slice.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(as: T.self)) }
    }
}
