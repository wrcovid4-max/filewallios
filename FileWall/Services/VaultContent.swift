import Foundation
import FileWallKit

/// Import/export of actual file content, layered on the metadata store. Images
/// and video never touch disk in plaintext; only PDFs/Quick Look formats use the
/// preview cache (wiped on lock/background/launch), which lives here.
extension VaultService {

    /// The single plaintext location on disk — a preview cache for Quick Look of
    /// formats the app can't render in memory. Wiped aggressively.
    static var previewCacheDirectory: URL {
        AppEnvironment.vaultDirectory.appendingPathComponent("PreviewCache", isDirectory: true)
    }

    /// Erase the preview cache. Called on lock, on backgrounding, and at launch.
    static func wipePreviewCache() {
        try? FileManager.default.removeItem(at: previewCacheDirectory)
    }

    // MARK: Import

    /// Encrypt `data` into the vault (chunked AES-GCM, device key) and register it.
    @discardableResult
    func importData(_ data: Data, name: String, mimeType: String,
                    folderID: UUID?, side: VaultSideSelector) async throws -> VaultFileSnapshot {
        let id = UUID()
        let key = try await keyStore.vaultKey(for: side)
        let blob = try ChunkedCipher().encrypt(data, using: key)

        try FileManager.default.createDirectory(at: AppEnvironment.vaultDirectory,
                                                withIntermediateDirectories: true)
        let url = AppEnvironment.vaultDirectory.appendingPathComponent(id.uuidString)
        try blob.write(to: url, options: .atomic)

        return try await vaultStore().importFile(
            id: id, name: name, category: VaultCategory(mimeType: mimeType), mimeType: mimeType,
            byteSize: Int64(blob.count), folderID: folderID, side: side)
    }

    // MARK: Read

    /// Decrypt a file to memory (used for image display — plaintext never hits disk).
    func decryptedData(for id: UUID, side: VaultSideSelector) async throws -> Data {
        let key = try await keyStore.vaultKey(for: side)
        let url = AppEnvironment.vaultDirectory.appendingPathComponent(id.uuidString)
        let blob = try Data(contentsOf: url, options: .mappedIfSafe)
        return try ChunkedCipher().decrypt(blob, using: key)
    }

    /// Decrypt a file into the preview cache and return the URL (for Quick Look /
    /// PDFKit of non-image formats). The caller is responsible for wiping via
    /// `wipePreviewCache()` on lock/background.
    func decryptToPreviewCache(id: UUID, name: String, side: VaultSideSelector) async throws -> URL {
        let key = try await keyStore.vaultKey(for: side)
        try FileManager.default.createDirectory(at: Self.previewCacheDirectory,
                                                withIntermediateDirectories: true)
        let source = AppEnvironment.vaultDirectory.appendingPathComponent(id.uuidString)
        // Keep the real name so Quick Look picks the right renderer by extension.
        let dest = Self.previewCacheDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        try await ChunkedCipher().decryptFile(at: source, to: dest, using: key)
        return dest
    }
}
