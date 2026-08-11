import Foundation
import CryptoKit
import FileWallKit

/// Orchestrates "Backup & Sync": ties Google auth + Drive transport + the
/// cross-platform `.fwvault` codec + the on-device vault together.
///
/// # The "no passphrase" model
/// The archive passphrase is never typed. A random 256-bit key lives in Drive's
/// `appDataFolder` as `filewall-backup.key` (Base64 text). Any device signed into
/// the account reads it and can decrypt — deliberately "as safe as the Google
/// account". iOS follows the exact same rule as Android (BACKUP_FORMAT.md), so
/// one backup is shared between platforms.
///
/// # Backup carries plaintext, so it needs the device keys
/// The `.fwvault` ZIP holds each file's raw *plaintext* (that's what makes it
/// portable). So backup decrypts each device blob (chunked-GCM) first, and
/// restore re-encrypts into the device format. The hidden side's key is
/// biometry-gated, so which sides a backup covers depends on what the caller can
/// unlock — see `backup(sides:)`.
final class DriveBackupService {

    static let shared = DriveBackupService()
    private init() {}

    private let cipher = ChunkedCipher()
    private var drive: DriveClient {
        DriveClient(accessToken: { try await GoogleAuth.shared.validAccessToken() })
    }

    struct BackupResult: Equatable { let items: Int; let folders: Int }

    enum BackupError: Error, Equatable { case notSignedIn, noBackupFound }

    // MARK: - Managed passphrase (Drive-side, no user prompt)

    /// The archive passphrase from Drive: read `filewall-backup.key` if present,
    /// otherwise mint 32 random bytes, Base64 them (no wrapping) and upload — the
    /// exact behaviour of Android's `managedPassphrase()`.
    func managedPassphrase() async throws -> String {
        let d = drive
        if let id = try await d.findFileId(name: InteropArchiveName.key) {
            let data = try await d.downloadData(id: id)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var raw = Data(count: 32)
        _ = raw.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        // Foundation's base64EncodedString() emits no line breaks — equivalent to
        // Android's Base64.NO_WRAP, which the key-file contract requires.
        let encoded = raw.base64EncodedString()
        try await d.uploadData(name: InteropArchiveName.key, data: Data(encoded.utf8))
        return encoded
    }

    // MARK: - Backup

    /// Back up the given sides. A manual, authenticated backup passes
    /// `[.standard, .hidden]` (the caller has just unlocked, so the hidden key is
    /// reachable). Unattended auto-backup passes `[.standard]` only, because the
    /// hidden key is biometry-gated and cannot be read in the background.
    ///
    /// NOTE on not clobbering: the whole vault is one `filewall-backup.fwvault`.
    /// An auto-backup that omitted hidden items would, on upload, replace a fuller
    /// manual backup and lose them. So `backup(sides:)` is only safe to call with a
    /// reduced side set when there are no items on the omitted sides — the caller
    /// (BG task) checks that first; see `autoBackupIfSafe()`.
    @discardableResult
    func backup(sides: Set<VaultSideSelector>) async throws -> BackupResult {
        guard await GoogleAuth.shared.isSignedIn else { throw BackupError.notSignedIn }
        let work = try Self.makeWorkDir(prefix: "fwbackup")
        defer { try? FileManager.default.removeItem(at: work) }
        let archiveURL = work.appendingPathComponent(InteropArchiveName.archive)
        let result = try await buildArchive(passphrase: try await managedPassphrase(), sides: sides,
                                            to: archiveURL, work: work)
        try await drive.uploadFile(name: InteropArchiveName.archive, fileURL: archiveURL)
        return result
    }

    /// Build a `.fwvault` at `archiveURL`, keyed by `passphrase`. Plaintext temps
    /// live under `work` (the caller owns it). Shared by Drive backup and local
    /// export — the only difference is where the passphrase comes from and what
    /// happens to the finished file.
    @discardableResult
    private func buildArchive(passphrase: String, sides: Set<VaultSideSelector>,
                              to archiveURL: URL, work: URL) async throws -> BackupResult {
        let store = try await VaultService.shared.vaultStore()
        let keyStore = VaultService.shared.keyStore
        let folders = try await store.allFoldersForBackup(sides: sides)
        let files = try await store.allFilesForBackup(sides: sides)

        var keyCache: [VaultSideSelector: SymmetricKey] = [:]
        var plaintextByID: [String: URL] = [:]
        var items: [BackupItem] = []
        for f in files {
            let side: VaultSideSelector = f.isHidden ? .hidden : .standard
            let key = try await key(for: side, keyStore: keyStore, cache: &keyCache)
            let blobURL = AppEnvironment.vaultDirectory.appendingPathComponent(f.id.uuidString)
            let plainURL = work.appendingPathComponent("plain-\(f.id.uuidString)")
            try await cipher.decryptFile(at: blobURL, to: plainURL, using: key)
            plaintextByID[f.id.uuidString] = plainURL
            items.append(BackupItem(
                id: f.id.uuidString, name: f.name, mimeType: f.mimeType,
                sizeBytes: Self.fileSize(plainURL), addedAt: Self.ms(f.dateAdded),
                folderId: f.folderID?.uuidString, hidden: f.isHidden,
                archived: f.state == .archived, deletedAt: f.deletedAt.map(Self.ms) ?? 0,
                entry: "blobs/\(f.id.uuidString)"))
        }
        let backupFolders = folders.map {
            BackupFolder(id: $0.id.uuidString, name: $0.name, colorIndex: $0.colorIndex,
                         createdAt: Self.ms($0.dateCreated), hidden: $0.isHidden)
        }
        try InteropArchive().write(
            folders: backupFolders, items: items, passphrase: passphrase,
            to: archiveURL, createdAt: Self.ms(Date())) { item in
                guard let url = plaintextByID[item.id] else { throw BackupError.noBackupFound }
                return url
            }
        return BackupResult(items: items.count, folders: backupFolders.count)
    }

    /// Unattended backup for the BG task. Only proceeds if it can safely cover the
    /// whole vault: if hidden items exist (whose key it can't read in the
    /// background), it declines rather than upload a partial that would clobber a
    /// fuller manual backup. Returns nil when it declined.
    @discardableResult
    func autoBackupIfSafe() async throws -> BackupResult? {
        guard await GoogleAuth.shared.isSignedIn else { return nil }
        let store = try await VaultService.shared.vaultStore()
        let hiddenItems = try await store.allFilesForBackup(sides: [.hidden])
        guard hiddenItems.isEmpty else {
            // Hidden content present → a background run can't include it. Defer to
            // the next manual backup. (Documented trade-off; see BACKUP_SYNC.md.)
            return nil
        }
        return try await backup(sides: [.standard])
    }

    // MARK: - Restore

    /// Download and restore the shared backup. Re-creates folders, then re-encrypts
    /// each item's plaintext into the device format and registers it with its exact
    /// hidden/archived/deleted state. The hidden side's key is required for hidden
    /// items, so a full restore runs authenticated (BackUpVaultIntent / Settings).
    @discardableResult
    func restore() async throws -> BackupResult {
        guard await GoogleAuth.shared.isSignedIn else { throw BackupError.notSignedIn }
        let d = drive
        guard let id = try await d.findFileId(name: InteropArchiveName.archive) else {
            throw BackupError.noBackupFound
        }
        let work = try Self.makeWorkDir(prefix: "fwrestore")
        defer { try? FileManager.default.removeItem(at: work) }
        let archiveURL = work.appendingPathComponent(InteropArchiveName.archive)
        try await d.download(id: id, to: archiveURL)
        return try await ingestArchive(from: archiveURL, passphrase: try await managedPassphrase())
    }

    /// Verify, decrypt and ingest a `.fwvault` into the vault, re-creating folders
    /// then re-encrypting each item with its exact state. Shared by Drive restore
    /// and local import.
    @discardableResult
    private func ingestArchive(from archiveURL: URL, passphrase: String) async throws -> BackupResult {
        let staged = try InteropArchive().readStaged(from: archiveURL, passphrase: passphrase)
        defer { try? FileManager.default.removeItem(at: staged.stagingDirectory) }

        let store = try await VaultService.shared.vaultStore()
        let keyStore = VaultService.shared.keyStore

        var folderMap: [String: UUID] = [:]
        for f in staged.folders {
            let newID = try await store.createFolderForRestore(
                name: f.name, colorIndex: f.colorIndex, hidden: f.hidden, createdAt: Self.date(f.createdAt))
            folderMap[f.id] = newID
        }

        var keyCache: [VaultSideSelector: SymmetricKey] = [:]
        for (item, plainURL) in staged.items {
            let side: VaultSideSelector = item.hidden ? .hidden : .standard
            let key = try await key(for: side, keyStore: keyStore, cache: &keyCache)
            let newID = UUID()
            let blobURL = AppEnvironment.vaultDirectory.appendingPathComponent(newID.uuidString)
            try await cipher.encryptFile(at: plainURL, to: blobURL, using: key)
            try await store.importRestored(
                id: newID, name: item.name, category: VaultCategory(mimeType: item.mimeType),
                mimeType: item.mimeType, byteSize: Self.fileSize(blobURL),
                folderID: item.folderId.flatMap { folderMap[$0] },
                hidden: item.hidden, archived: item.archived,
                deletedAt: item.deletedAt == 0 ? nil : Self.date(item.deletedAt),
                dateAdded: Self.date(item.addedAt))
        }
        return BackupResult(items: staged.items.count, folders: staged.folders.count)
    }

    // MARK: - Local .fwvault (passphrase, no Google)

    /// Export the whole vault to a passphrase-protected `.fwvault` at a temp URL
    /// the caller shares/saves ("Save to Files"). No Google account required.
    func exportLocalArchive(passphrase: String, sides: Set<VaultSideSelector> = [.standard, .hidden]) async throws -> URL {
        let work = try Self.makeWorkDir(prefix: "fwexport")
        defer { try? FileManager.default.removeItem(at: work) }
        // The finished file lives OUTSIDE `work`, so cleaning up the plaintext
        // temps doesn't take the archive with it.
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileWall-\(Self.stamp()).fwvault")
        try? FileManager.default.removeItem(at: out)
        _ = try await buildArchive(passphrase: passphrase, sides: sides, to: out, work: work)
        return out
    }

    /// Import a local `.fwvault` the user picked, with the passphrase they typed.
    @discardableResult
    func importLocalArchive(from url: URL, passphrase: String) async throws -> BackupResult {
        try await ingestArchive(from: url, passphrase: passphrase)
    }

    /// modifiedTime of the stored backup (for a "Last backed up …" label), or nil.
    func lastBackupTime() async throws -> String? {
        guard await GoogleAuth.shared.isSignedIn else { return nil }
        return try await drive.lastBackupModifiedTime()
    }

    // MARK: - Helpers

    private func key(for side: VaultSideSelector, keyStore: VaultKeyStore,
                     cache: inout [VaultSideSelector: SymmetricKey]) async throws -> SymmetricKey {
        if let k = cache[side] { return k }
        let k = try await keyStore.vaultKey(for: side == .hidden ? .hidden : .standard)
        cache[side] = k
        return k
    }

    private static func makeWorkDir(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let n = attrs[.size] as? NSNumber else { return 0 }
        return n.int64Value
    }

    /// Epoch **milliseconds** — the manifest's time unit, matching Android.
    private static func ms(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
}
