import Foundation

/// The cross-platform `.fwvault` container — the exact wire format Android's
/// `VaultArchive.kt` reads and writes, so a backup made on either platform
/// restores on the other. **This file is the contract; every constant is
/// load-bearing.** See BACKUP_FORMAT.md.
///
/// ```
/// [ "FWARCH01" 8B ][ salt 16B ][ iterations 4B BE ][ iv 16B ][ AES-256-CTR(zip) … ][ HMAC-SHA256 32B ]
/// ```
///
/// The encrypted body is a ZIP of `manifest.json` + `blobs/<uuid>` where each
/// blob is the file's raw **plaintext**. On iOS that means backup decrypts each
/// device blob (chunked-GCM) to plaintext before zipping, and restore re-encrypts
/// the plaintext into the device format — the `.fwvault` is device-independent by
/// construction, which is what lets it move between phones and platforms.
public struct InteropArchive {

    public static let magic = Data("FWARCH01".utf8)          // 8 bytes
    public static let defaultFileName = "filewall-backup.fwvault"
    public static let keyFileName = "filewall-backup.key"
    public static let writeIterations: UInt32 = 210_000
    public static let minIterations: UInt32 = 1_000
    public static let maxIterations: UInt32 = 2_000_000
    public static let minPassphraseLength = 8

    private static let saltLen = 16
    private static let ivLen = 16
    private static let macLen = 32
    private static let headerLen = 8 + 16 + 4 + 16          // 44
    private static let chunk = 64 * 1024

    private let iterations: UInt32

    public init(iterations: UInt32 = InteropArchive.writeIterations) {
        self.iterations = iterations
    }

    public enum ArchiveError: Error, Equatable {
        case passphraseTooShort
        case notAnArchive
        case damagedHeader
        /// Wrong passphrase OR tampered/corrupt body — deliberately one outcome.
        case wrongPassphraseOrDamaged
        case noManifest
    }

    // MARK: - Export

    /// Write a `.fwvault` to `output`. `plaintextProvider` returns a temp file
    /// containing an item's raw plaintext (the caller decrypts the device blob);
    /// the caller owns those temps' lifetimes.
    public func write(folders: [BackupFolder],
                      items: [BackupItem],
                      passphrase: String,
                      to output: URL,
                      createdAt: Int64,
                      plaintextProvider: (BackupItem) throws -> URL) throws {
        guard passphrase.count >= Self.minPassphraseLength else { throw ArchiveError.passphraseTooShort }

        let salt = InteropCrypto.randomBytes(Self.saltLen)
        let iv = InteropCrypto.randomBytes(Self.ivLen)
        let keys = try InteropCrypto.deriveKeys(passphrase: passphrase, salt: salt, iterations: iterations)

        // 1. Build the plaintext ZIP body to a temp file.
        let tempZip = FileManager.default.temporaryDirectory
            .appendingPathComponent("fwvault-body-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: tempZip) }

        let zip = try ZipWriter(url: tempZip)
        try zip.addData(name: "manifest.json",
                        data: try BackupManifest.encode(folders: folders, items: items, createdAt: createdAt))
        for item in items {
            try zip.addFile(name: item.entry, from: try plaintextProvider(item))
        }
        try zip.finish()

        // 2. Encrypt-then-MAC the ZIP into the container.
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }

        var header = Data()
        header.append(Self.magic)
        header.append(salt)
        header.append(iterationsBE(iterations))
        header.append(iv)
        try out.write(contentsOf: header)   // header is NOT MAC-covered (matches Android)

        let ctr = try InteropCrypto.CTR(key: keys.aes, iv: iv)
        var hmac = InteropCrypto.HMACAccumulator(key: keys.mac)

        let input = try FileHandle(forReadingFrom: tempZip)
        defer { try? input.close() }
        while let plain = try input.read(upToCount: Self.chunk), !plain.isEmpty {
            let ct = try ctr.update(plain)
            hmac.update(ct)                  // MAC over ciphertext only
            try out.write(contentsOf: ct)
        }
        try out.write(contentsOf: hmac.finalize())
    }

    // MARK: - Restore

    /// The result of a verified, decrypted restore: the folders, and each item
    /// paired with a temp file holding its raw plaintext. All plaintext lives
    /// under `stagingDirectory`, which the **caller must delete** once it has
    /// re-encrypted and ingested everything.
    ///
    /// Returned as staged files (rather than a callback) so the async app layer
    /// can re-encrypt into the device format and write Core Data — work that can't
    /// run inside a synchronous closure. Folders come first so the caller creates
    /// them and maps ids before re-linking items.
    public struct StagedRestore {
        public let folders: [BackupFolder]
        public let items: [(item: BackupItem, plaintextURL: URL)]
        public let stagingDirectory: URL
    }

    /// Verify + decrypt a `.fwvault` and stage every blob's plaintext to disk.
    ///
    /// The HMAC is checked **before** any plaintext is written out: nothing is
    /// staged until the trailer matches. Blobs are staged by a counter, never by
    /// the entry's own name — a hand-crafted archive cannot write outside the
    /// staging directory (path-traversal guard).
    public func readStaged(from input: URL, passphrase: String) throws -> StagedRestore {
        let data = try Data(contentsOf: input, options: .mappedIfSafe)
        let base = data.startIndex
        guard data.count >= Self.headerLen + Self.macLen else { throw ArchiveError.notAnArchive }
        guard data.subdata(in: base..<base + 8) == Self.magic else { throw ArchiveError.notAnArchive }

        var p = base + 8
        let salt = data.subdata(in: p..<p + Self.saltLen); p += Self.saltLen
        let iterations = readIterationsBE(data.subdata(in: p..<p + 4)); p += 4
        guard iterations >= Self.minIterations && iterations <= Self.maxIterations else {
            throw ArchiveError.damagedHeader
        }
        let iv = data.subdata(in: p..<p + Self.ivLen); p += Self.ivLen

        let cipherStart = p
        let cipherEnd = data.endIndex - Self.macLen
        guard cipherEnd >= cipherStart else { throw ArchiveError.notAnArchive }
        let trailer = data.subdata(in: cipherEnd..<data.endIndex)

        let keys = try InteropCrypto.deriveKeys(passphrase: passphrase, salt: salt, iterations: iterations)

        // 1. Verify MAC over the ciphertext BEFORE decrypting anything for use.
        var verifier = InteropCrypto.HMACAccumulator(key: keys.mac)
        var q = cipherStart
        while q < cipherEnd {
            let end = min(q + Self.chunk, cipherEnd)
            verifier.update(data.subdata(in: q..<end))
            q = end
        }
        guard InteropCrypto.constantTimeEqual(verifier.finalize(), trailer) else {
            throw ArchiveError.wrongPassphraseOrDamaged
        }

        // 2. Decrypt the body to a temp ZIP.
        let tempZip = FileManager.default.temporaryDirectory
            .appendingPathComponent("fwvault-in-\(UUID().uuidString).zip")
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("fwvault-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Only the temp ZIP is cleaned here; `staging` is handed to the caller and
        // is their responsibility to delete after ingest.
        defer { try? FileManager.default.removeItem(at: tempZip) }

        FileManager.default.createFile(atPath: tempZip.path, contents: nil)
        let zipOut = try FileHandle(forWritingTo: tempZip)
        let ctr = try InteropCrypto.CTR(key: keys.aes, iv: iv)
        var r = cipherStart
        while r < cipherEnd {
            let end = min(r + Self.chunk, cipherEnd)
            try zipOut.write(contentsOf: try ctr.update(data.subdata(in: r..<end)))
            r = end
        }
        try zipOut.close()

        // 3. Parse the ZIP, read the manifest, ingest each blob staged by counter.
        let zipData = try Data(contentsOf: tempZip, options: .mappedIfSafe)
        let reader = try ZipReader(data: zipData)

        guard let manifestEntry = reader.entries.first(where: { $0.name == "manifest.json" }) else {
            throw ArchiveError.noManifest
        }
        let (folders, items) = try BackupManifest.decode(try reader.data(for: manifestEntry))
        let itemsByEntry = Dictionary(items.map { ($0.entry, $0) }, uniquingKeysWith: { a, _ in a })

        var staged: [(item: BackupItem, plaintextURL: URL)] = []
        var counter = 0
        for entry in reader.entries where entry.name != "manifest.json" {
            guard let item = itemsByEntry[entry.name] else { continue }
            // Staged by counter, never by the entry's own name.
            let url = staging.appendingPathComponent("item_\(counter).bin")
            try reader.write(entry, to: url)
            staged.append((item, url))
            counter += 1
        }
        return StagedRestore(folders: folders, items: staged, stagingDirectory: staging)
    }

    // MARK: - Header integer helpers

    private func iterationsBE(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Swift.withUnsafeBytes(of: &be) { Data($0) }
    }

    private func readIterationsBE(_ d: Data) -> UInt32 {
        UInt32(bigEndian: d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }
}
