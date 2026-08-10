import XCTest
import Compression
@testable import FileWallKit

/// Tests for the cross-platform `.fwvault` codec. These lock the wire format so a
/// refactor can't silently drift from BACKUP_FORMAT.md and break Android interop.
/// True cross-device interop (decrypting an archive Android actually wrote) is
/// verified on-device; here we pin every constant, the header bytes, the ZIP
/// container, and a full round trip.
final class InteropArchiveTests: XCTestCase {

    private var dir: URL!
    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writeTemp(_ name: String, _ bytes: Data) throws -> URL {
        let u = dir.appendingPathComponent(name)
        try bytes.write(to: u)
        return u
    }

    // MARK: Format constants (regression guard against silent drift)

    func testFormatConstantsMatchSpec() {
        XCTAssertEqual(InteropArchive.magic, Data("FWARCH01".utf8))
        XCTAssertEqual(InteropArchive.writeIterations, 210_000)
        XCTAssertEqual(InteropArchive.defaultFileName, "filewall-backup.fwvault")
        XCTAssertEqual(InteropArchive.keyFileName, "filewall-backup.key")
        XCTAssertEqual(InteropArchive.minPassphraseLength, 8)
    }

    func testHeaderBytesLayout() throws {
        let archive = InteropArchive(iterations: 210_000)
        let plaintext = try writeTemp("blob", Data("hello".utf8))
        let item = BackupItem(id: "id1", name: "a.txt", mimeType: "text/plain", sizeBytes: 5,
                              addedAt: 1, folderId: nil, hidden: false, archived: false,
                              deletedAt: 0, entry: "blobs/id1")
        let out = dir.appendingPathComponent("out.fwvault")
        try archive.write(folders: [], items: [item], passphrase: "passphrase1",
                          to: out, createdAt: 123) { _ in plaintext }

        let data = try Data(contentsOf: out)
        // magic (8) | salt (16) | iterations BE (4) | iv (16) | ciphertext | mac (32)
        XCTAssertEqual(data.subdata(in: 0..<8), Data("FWARCH01".utf8))
        let iters = data.subdata(in: 24..<28).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        XCTAssertEqual(iters, 210_000)
        XCTAssertGreaterThan(data.count, 8 + 16 + 4 + 16 + 32) // header + body + mac
    }

    // MARK: Round trip

    func testExportRestoreRoundTrip() throws {
        // Low iteration count keeps PBKDF2 fast; the format is identical.
        let archive = InteropArchive(iterations: 2_000)

        let folders = [BackupFolder(id: "F1", name: "Iran", colorIndex: 3, createdAt: 1_723_300_000_000, hidden: false)]
        let blobA = try writeTemp("a", Data(repeating: 0xAB, count: 3000))
        let blobB = try writeTemp("b", Data("second file".utf8))
        let items = [
            BackupItem(id: "A", name: "invoice.pdf", mimeType: "application/pdf", sizeBytes: 3000,
                       addedAt: 1_723_301_111_000, folderId: "F1", hidden: false, archived: true,
                       deletedAt: 0, entry: "blobs/A"),
            BackupItem(id: "B", name: "note.txt", mimeType: "text/plain", sizeBytes: 11,
                       addedAt: 1_723_302_222_000, folderId: nil, hidden: true, archived: false,
                       deletedAt: 1_723_309_999_000, entry: "blobs/B")
        ]
        let plaintext: [String: Data] = [
            "blobs/A": Data(repeating: 0xAB, count: 3000),
            "blobs/B": Data("second file".utf8)
        ]

        let out = dir.appendingPathComponent("rt.fwvault")
        try archive.write(folders: folders, items: items, passphrase: "correct horse",
                          to: out, createdAt: 42) { item in item.entry == "blobs/A" ? blobA : blobB }

        let staged = try archive.readStaged(from: out, passphrase: "correct horse")
        defer { try? FileManager.default.removeItem(at: staged.stagingDirectory) }
        let restoredFolders = staged.folders
        let restoredItems: [(BackupItem, Data)] = try staged.items.map { ($0.item, try Data(contentsOf: $0.plaintextURL)) }

        XCTAssertEqual(restoredFolders, folders)
        XCTAssertEqual(restoredItems.count, 2)
        let byId = Dictionary(restoredItems.map { ($0.0.id, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byId["A"]?.0, items[0])
        XCTAssertEqual(byId["A"]?.1, plaintext["blobs/A"])
        XCTAssertEqual(byId["B"]?.0, items[1])
        XCTAssertEqual(byId["B"]?.1, plaintext["blobs/B"])
    }

    func testWrongPassphraseFails() throws {
        let archive = InteropArchive(iterations: 2_000)
        let blob = try writeTemp("x", Data("data".utf8))
        let item = BackupItem(id: "X", name: "x", mimeType: "text/plain", sizeBytes: 4, addedAt: 0,
                              folderId: nil, hidden: false, archived: false, deletedAt: 0, entry: "blobs/X")
        let out = dir.appendingPathComponent("w.fwvault")
        try archive.write(folders: [], items: [item], passphrase: "rightpass", to: out, createdAt: 0) { _ in blob }

        XCTAssertThrowsError(try archive.readStaged(from: out, passphrase: "wrongpass")) { error in
            XCTAssertEqual(error as? InteropArchive.ArchiveError, .wrongPassphraseOrDamaged)
        }
    }

    func testTamperedBodyFails() throws {
        let archive = InteropArchive(iterations: 2_000)
        let blob = try writeTemp("x", Data("data".utf8))
        let item = BackupItem(id: "X", name: "x", mimeType: "text/plain", sizeBytes: 4, addedAt: 0,
                              folderId: nil, hidden: false, archived: false, deletedAt: 0, entry: "blobs/X")
        let out = dir.appendingPathComponent("t.fwvault")
        try archive.write(folders: [], items: [item], passphrase: "rightpass", to: out, createdAt: 0) { _ in blob }

        var data = try Data(contentsOf: out)
        data[data.count / 2] ^= 0x01 // flip a ciphertext byte
        let tampered = dir.appendingPathComponent("tampered.fwvault")
        try data.write(to: tampered)
        XCTAssertThrowsError(try archive.readStaged(from: tampered, passphrase: "rightpass")) { error in
            XCTAssertEqual(error as? InteropArchive.ArchiveError, .wrongPassphraseOrDamaged)
        }
    }

    func testShortPassphraseRejectedOnWrite() throws {
        let archive = InteropArchive(iterations: 2_000)
        let out = dir.appendingPathComponent("s.fwvault")
        XCTAssertThrowsError(try archive.write(folders: [], items: [], passphrase: "short", to: out, createdAt: 0) { _ in
            self.dir // unused
        }) { error in
            XCTAssertEqual(error as? InteropArchive.ArchiveError, .passphraseTooShort)
        }
    }

    func testNotAnArchiveRejected() throws {
        let archive = InteropArchive(iterations: 2_000)
        let bogus = try writeTemp("bogus", Data("not a vault at all, just text padding........".utf8))
        XCTAssertThrowsError(try archive.readStaged(from: bogus, passphrase: "whatever8")) { error in
            XCTAssertEqual(error as? InteropArchive.ArchiveError, .notAnArchive)
        }
    }

    // MARK: ZIP + CRC + manifest units

    func testZipStoredRoundTrip() throws {
        let zipURL = dir.appendingPathComponent("z.zip")
        let writer = try ZipWriter(url: zipURL)
        try writer.addData(name: "manifest.json", data: Data("{\"version\":2}".utf8))
        let big = try writeTemp("big", Data(repeating: 0x5A, count: 100_000))
        try writer.addFile(name: "blobs/one", from: big)
        try writer.finish()

        let reader = try ZipReader(data: try Data(contentsOf: zipURL))
        XCTAssertEqual(Set(reader.entries.map(\.name)), ["manifest.json", "blobs/one"])
        let manifest = try reader.data(for: reader.entries.first { $0.name == "manifest.json" }!)
        XCTAssertEqual(manifest, Data("{\"version\":2}".utf8))
        let blob = try reader.data(for: reader.entries.first { $0.name == "blobs/one" }!)
        XCTAssertEqual(blob, Data(repeating: 0x5A, count: 100_000))
    }

    func testCRC32KnownAnswer() {
        // Standard CRC-32 of "123456789" is 0xCBF43926.
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testInflateRoundTripAgainstCompressionFramework() throws {
        // Deflate with the same framework the reader inflates with, proving the
        // method-8 path (Android writes deflate) decodes correctly.
        let original = Data((0..<5000).map { UInt8($0 & 0xFF) })
        var compressed = Data(count: original.count + 1024)
        let n = compressed.withUnsafeMutableBytes { dst in
            original.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, original.count + 1024,
                                          src.bindMemory(to: UInt8.self).baseAddress!, original.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        XCTAssertGreaterThan(n, 0)
        compressed.removeSubrange(n..<compressed.count)

        var dst = Data(count: original.count)
        let out = dst.withUnsafeMutableBytes { d in
            compressed.withUnsafeBytes { s in
                compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, original.count,
                                          s.bindMemory(to: UInt8.self).baseAddress!, compressed.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        XCTAssertEqual(out, original.count)
        XCTAssertEqual(dst, original)
    }

    func testManifestEncodeDecodeMatchesSchema() throws {
        let folders = [BackupFolder(id: "F", name: "Docs", colorIndex: 2, createdAt: 111, hidden: true)]
        let items = [BackupItem(id: "I", name: "a", mimeType: "text/plain", sizeBytes: 9, addedAt: 222,
                                folderId: nil, hidden: false, archived: true, deletedAt: 333, entry: "blobs/I")]
        let data = try BackupManifest.encode(folders: folders, items: items, createdAt: 999)

        // Field names and null handling must match Android's org.json output.
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(root["version"] as? Int, 2)
        let itemDict = (root["items"] as! [[String: Any]])[0]
        XCTAssertTrue(itemDict["folderId"] is NSNull)
        XCTAssertEqual(itemDict["deletedAt"] as? NSNumber, 333)

        let (df, di) = try BackupManifest.decode(data)
        XCTAssertEqual(df, folders)
        XCTAssertEqual(di, items)
    }

    func testManifestV1DefaultsArchivedAndDeleted() throws {
        // A v1 manifest omits archived/deletedAt; both must default to live.
        let v1 = Data("""
        {"version":1,"createdAt":1,"folders":[],"items":[
          {"id":"I","name":"a","mimeType":"text/plain","sizeBytes":1,"addedAt":2,"folderId":null,"hidden":false,"entry":"blobs/I"}
        ]}
        """.utf8)
        let (_, items) = try BackupManifest.decode(v1)
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].archived)
        XCTAssertEqual(items[0].deletedAt, 0)
    }
}
