import XCTest
import CoreData
@testable import FileWallKit

/// Lifecycle and retention tests for `VaultStore`. Core Data is available on
/// macOS, so these run under `swift test` on a laptop with an in-memory store —
/// no simulator, no device.
///
/// Note: `await` cannot appear inside an `XCTAssert…` autoclosure (it is not an
/// async context), so every awaited value is hoisted to a `let` first.
final class VaultLifecycleTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore(retention: TimeInterval = VaultStore.recentlyDeletedRetention) throws -> VaultStore {
        try VaultStore(blobsDirectory: tempDir, inMemory: true, retention: retention)
    }

    /// Create a live file and a matching zero-byte blob on disk, so blob-deletion
    /// paths (purge, delete-forever) have something real to erase.
    @discardableResult
    private func addFile(_ store: VaultStore, name: String = "f", category: VaultCategory = .photo,
                         size: Int64 = 1000, folderID: UUID? = nil,
                         side: VaultSideSelector = .standard) async throws -> VaultFileSnapshot {
        let id = UUID()
        FileManager.default.createFile(atPath: tempDir.appendingPathComponent(id.uuidString).path, contents: Data())
        return try await store.importFile(id: id, name: name, category: category, byteSize: size,
                                          folderID: folderID, side: side)
    }

    // MARK: Import → live

    func testImportedFileIsLive() async throws {
        let store = try makeStore()
        let snap = try await addFile(store)
        XCTAssertEqual(snap.state, .live)
        let live = try await store.liveFiles(side: .standard)
        XCTAssertEqual(live.map(\.id), [snap.id])
    }

    // MARK: Delete → Recently Deleted

    func testTrashLeavesLiveGridAndEntersRecentlyDeleted() async throws {
        let store = try makeStore()
        let snap = try await addFile(store)
        try await store.trash(id: snap.id)

        let live = try await store.liveFiles(side: .standard)
        XCTAssertTrue(live.isEmpty)
        let trashed = try await store.recentlyDeletedFiles(side: .standard)
        XCTAssertEqual(trashed.map(\.id), [snap.id])
        if case .trashed = trashed[0].state {} else { XCTFail("expected trashed state") }
    }

    func testTrashDropsFolderCountButRestoreReturnsIt() async throws {
        let store = try makeStore()
        let folder = try await store.createFolder(name: "F", colorIndex: 3, side: .standard)
        let snap = try await addFile(store, folderID: folder.id)

        var folders = try await store.folders(side: .standard)
        XCTAssertEqual(folders.first?.liveItemCount, 1)
        try await store.trash(id: snap.id)
        folders = try await store.folders(side: .standard)
        XCTAssertEqual(folders.first?.liveItemCount, 0)

        try await store.restore(id: snap.id)
        folders = try await store.folders(side: .standard)
        XCTAssertEqual(folders.first?.liveItemCount, 1)
        let live = try await store.liveFiles(side: .standard)
        XCTAssertEqual(live.map(\.id), [snap.id])
    }

    // MARK: Storage accounting — trashed drops, archived does not

    func testStorageExcludesTrashedButKeepsArchived() async throws {
        let store = try makeStore()
        let a = try await addFile(store, size: 1000)
        let b = try await addFile(store, size: 500)

        var storage = try await store.storageBreakdown(side: .standard)
        XCTAssertEqual(storage.totalBytes, 1500)

        // Archiving keeps the bytes counted.
        try await store.archive(id: a.id)
        storage = try await store.storageBreakdown(side: .standard)
        XCTAssertEqual(storage.totalBytes, 1500)
        let live = try await store.liveFiles(side: .standard)
        XCTAssertEqual(live.map(\.id), [b.id])

        // Trashing drops them.
        try await store.trash(id: b.id)
        storage = try await store.storageBreakdown(side: .standard)
        XCTAssertEqual(storage.totalBytes, 1000) // only the archived one remains counted
    }

    // MARK: One state at a time

    func testTrashClearsArchived() async throws {
        let store = try makeStore()
        let snap = try await addFile(store)
        try await store.archive(id: snap.id)
        var archived = try await store.archivedFiles(side: .standard)
        XCTAssertEqual(archived.map(\.id), [snap.id])

        try await store.trash(id: snap.id)
        // No longer in archive; only in recently deleted.
        archived = try await store.archivedFiles(side: .standard)
        XCTAssertTrue(archived.isEmpty)
        let trashed = try await store.recentlyDeletedFiles(side: .standard)
        XCTAssertEqual(trashed.map(\.id), [snap.id])
    }

    func testArchivingTrashedItemIsRejected() async throws {
        let store = try makeStore()
        let snap = try await addFile(store)
        try await store.trash(id: snap.id)
        do {
            try await store.archive(id: snap.id)
            XCTFail("expected invalidTransition")
        } catch {
            XCTAssertEqual(error as? VaultError, .invalidTransition)
        }
    }

    func testRestoringLiveItemIsRejected() async throws {
        let store = try makeStore()
        let snap = try await addFile(store)
        do {
            try await store.restore(id: snap.id)
            XCTFail("expected invalidTransition")
        } catch {
            XCTAssertEqual(error as? VaultError, .invalidTransition)
        }
    }

    func testArchiveUnarchiveRoundTrips() async throws {
        let store = try makeStore()
        let snap = try await addFile(store)
        try await store.archive(id: snap.id)
        var live = try await store.liveFiles(side: .standard)
        XCTAssertTrue(live.isEmpty)
        try await store.unarchive(id: snap.id)
        live = try await store.liveFiles(side: .standard)
        XCTAssertEqual(live.map(\.id), [snap.id])
        let archived = try await store.archivedFiles(side: .standard)
        XCTAssertTrue(archived.isEmpty)
    }

    // MARK: Delete Forever / Empty

    func testDeleteForeverErasesRecordAndBlob() async throws {
        let store = try makeStore()
        let snap = try await addFile(store)
        let blob = tempDir.appendingPathComponent(snap.id.uuidString)
        try await store.trash(id: snap.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
        try await store.deleteForever(id: snap.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path))
        let trashed = try await store.recentlyDeletedFiles(side: .standard)
        XCTAssertTrue(trashed.isEmpty)
    }

    func testDeleteForeverRequiresTrashed() async throws {
        let store = try makeStore()
        let snap = try await addFile(store)
        do {
            try await store.deleteForever(id: snap.id)
            XCTFail("expected invalidTransition")
        } catch {
            XCTAssertEqual(error as? VaultError, .invalidTransition)
        }
    }

    func testEmptyRecentlyDeletedOnlyAffectsItsSide() async throws {
        let store = try makeStore()
        let s1 = try await addFile(store, side: .standard)
        let s2 = try await addFile(store, side: .standard)
        let h1 = try await addFile(store, side: .hidden)
        try await store.trash(id: s1.id)
        try await store.trash(id: s2.id)
        try await store.trash(id: h1.id)

        let purged = try await store.emptyRecentlyDeleted(side: .standard)
        XCTAssertEqual(purged, 2)
        let standardTrash = try await store.recentlyDeletedFiles(side: .standard)
        XCTAssertTrue(standardTrash.isEmpty)
        // Hidden side's trash is untouched — separate Recently Deleted per side.
        let hiddenTrash = try await store.recentlyDeletedFiles(side: .hidden)
        XCTAssertEqual(hiddenTrash.map(\.id), [h1.id])
    }

    // MARK: Retention purge

    func testPurgeErasesExpiredButKeepsRecent() async throws {
        let store = try makeStore()
        let old = try await addFile(store)
        let recent = try await addFile(store)
        let oldBlob = tempDir.appendingPathComponent(old.id.uuidString)
        try await store.trash(id: old.id)
        try await store.trash(id: recent.id)

        let now = Date()
        // 29 days after trashing: cutoff is now-1d, so nothing older than that yet.
        let survivors = try await store.purgeExpired(now: now.addingTimeInterval(29 * 24 * 3600))
        XCTAssertTrue(survivors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldBlob.path))

        // 31 days: both are now past the 30-day window.
        let purged = try await store.purgeExpired(now: now.addingTimeInterval(31 * 24 * 3600))
        XCTAssertEqual(Set(purged), Set([old.id, recent.id]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldBlob.path))
        let trashed = try await store.recentlyDeletedFiles(side: .standard)
        XCTAssertTrue(trashed.isEmpty)
    }

    func testPurgeSpansBothSides() async throws {
        let store = try makeStore()
        let s = try await addFile(store, side: .standard)
        let h = try await addFile(store, side: .hidden)
        try await store.trash(id: s.id)
        try await store.trash(id: h.id)
        let purged = try await store.purgeExpired(now: Date().addingTimeInterval(31 * 24 * 3600))
        XCTAssertEqual(Set(purged), Set([s.id, h.id]))
    }

    // MARK: Hidden isolation

    func testHiddenItemsNeverAppearInStandardLists() async throws {
        let store = try makeStore()
        let visible = try await addFile(store, side: .standard)
        _ = try await addFile(store, side: .hidden)

        let standardLive = try await store.liveFiles(side: .standard)
        XCTAssertEqual(standardLive.map(\.id), [visible.id])
        // The hidden item is present on its own side, and only there.
        let hiddenLive = try await store.liveFiles(side: .hidden)
        XCTAssertEqual(hiddenLive.count, 1)
        // Standard storage counts only the visible file.
        let storage = try await store.storageBreakdown(side: .standard)
        XCTAssertEqual(storage.itemCount, 1)
    }

    func testSetHiddenMovesAcrossSides() async throws {
        let store = try makeStore()
        let snap = try await addFile(store, side: .standard)
        try await store.setHidden(id: snap.id, true)
        let standardLive = try await store.liveFiles(side: .standard)
        XCTAssertTrue(standardLive.isEmpty)
        let hiddenLive = try await store.liveFiles(side: .hidden)
        XCTAssertEqual(hiddenLive.map(\.id), [snap.id])
    }
}
