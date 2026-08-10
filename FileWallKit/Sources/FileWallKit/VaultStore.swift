import Foundation
import CoreData

/// The vault's metadata store and lifecycle engine.
///
/// Every list the app, App Intents, Spotlight, widgets and the watch can show is
/// produced here by a *fetch predicate*, never by filtering in the UI. That is
/// the load-bearing privacy decision: a hidden item is excluded at the query, so
/// it cannot be fetched, snapshotted, indexed, suggested or sent to the watch. A
/// trashed item is excluded from every default list for the same reason. If you
/// find yourself filtering `snapshot.isHidden` in a view, something upstream is
/// already wrong.
///
/// An `actor` so concurrent callers serialize, but the real Core Data work runs
/// on the background context's own queue via `perform`; managed objects never
/// escape those blocks — only `Sendable` snapshots do.
public actor VaultStore {

    /// 30 days. A trashed item's ciphertext stays on disk until this elapses, so
    /// Restore is lossless; the launch sweep erases anything older.
    public static let recentlyDeletedRetention: TimeInterval = 30 * 24 * 60 * 60

    private let container: NSPersistentContainer
    private let context: NSManagedObjectContext
    private let blobsDirectory: URL
    private let retention: TimeInterval

    /// - Parameters:
    ///   - blobsDirectory: where encrypted blobs live. Purge/delete-forever erase
    ///     `<blobsDirectory>/<uuid>` here.
    ///   - inMemory: use an in-memory store (tests). Production passes `false` and
    ///     gets a SQLite store with file protection applied below.
    public init(blobsDirectory: URL,
                inMemory: Bool = false,
                retention: TimeInterval = VaultStore.recentlyDeletedRetention) throws {
        self.blobsDirectory = blobsDirectory
        self.retention = retention

        // Always present: even with an in-memory metadata store the blob
        // directory is where purge/delete-forever erase ciphertext.
        try FileManager.default.createDirectory(at: blobsDirectory, withIntermediateDirectories: true)

        let container = NSPersistentContainer(name: "FileWall", managedObjectModel: VaultModel.shared)
        let description = NSPersistentStoreDescription()
        if inMemory {
            description.type = NSInMemoryStoreType
        } else {
            description.url = blobsDirectory.appendingPathComponent("metadata.sqlite")
            #if os(iOS)
            // Defence *beneath* the app's own encryption: even the metadata DB is
            // unreadable while the device is locked (except a file already open).
            // The blobs are separately encrypted; this protects the names too.
            description.setOption(FileProtectionType.completeUnlessOpen as NSObject,
                                  forKey: NSPersistentStoreFileProtectionKey)
            #endif
        }
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        // Single store, so a bounded synchronous wait in init is acceptable and
        // keeps the public API non-async to construct.
        let semaphore = DispatchSemaphore(value: 0)
        container.loadPersistentStores { _, error in
            loadError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let loadError { throw loadError }

        self.container = container
        let ctx = container.newBackgroundContext()
        ctx.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        self.context = ctx
    }

    // MARK: - Predicates
    //
    // The three lifecycle lists, each scoped to a side. `isHidden` appears in
    // ALL of them — the hidden vault keeps its own separate Archive and Recently
    // Deleted, so these never leak across the boundary.

    private func sidePredicate(_ side: VaultSideSelector) -> NSPredicate {
        NSPredicate(format: "isHidden == %@", NSNumber(value: side.isHidden))
    }

    /// live grid: deletedAt == nil AND isArchived == NO AND isHidden == <side>
    private func livePredicate(_ side: VaultSideSelector) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            sidePredicate(side),
            NSPredicate(format: "deletedAt == nil"),
            NSPredicate(format: "isArchived == %@", NSNumber(value: false))
        ])
    }

    /// archive: deletedAt == nil AND isArchived == YES AND isHidden == <side>
    private func archivePredicate(_ side: VaultSideSelector) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            sidePredicate(side),
            NSPredicate(format: "deletedAt == nil"),
            NSPredicate(format: "isArchived == %@", NSNumber(value: true))
        ])
    }

    /// recently deleted: deletedAt != nil AND isHidden == <side>
    private func trashedPredicate(_ side: VaultSideSelector) -> NSPredicate {
        NSCompoundPredicate(andPredicateWithSubpredicates: [
            sidePredicate(side),
            NSPredicate(format: "deletedAt != nil")
        ])
    }

    // MARK: - Reads

    public func liveFiles(side: VaultSideSelector) async throws -> [VaultFileSnapshot] {
        try await fetchSnapshots(predicate: livePredicate(side))
    }

    public func archivedFiles(side: VaultSideSelector) async throws -> [VaultFileSnapshot] {
        try await fetchSnapshots(predicate: archivePredicate(side))
    }

    public func recentlyDeletedFiles(side: VaultSideSelector) async throws -> [VaultFileSnapshot] {
        try await fetchSnapshots(predicate: trashedPredicate(side))
    }

    /// Live files inside a specific folder. Archived/trashed excluded — opening a
    /// folder shows exactly what its badge counts.
    public func liveFiles(inFolder folderID: UUID, side: VaultSideSelector) async throws -> [VaultFileSnapshot] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            livePredicate(side),
            NSPredicate(format: "folder.id == %@", folderID as NSUUID)
        ])
        return try await fetchSnapshots(predicate: predicate)
    }

    public func recentlyDeletedCount(side: VaultSideSelector) async throws -> Int {
        try await count(predicate: trashedPredicate(side))
    }

    public func archiveCount(side: VaultSideSelector) async throws -> Int {
        try await count(predicate: archivePredicate(side))
    }

    /// Storage breakdown for a side: bytes by category, excluding trashed items
    /// (on their way out) but INCLUDING archived ones (they still occupy disk).
    public func storageBreakdown(side: VaultSideSelector) async throws -> StorageBreakdown {
        // Not-trashed == live OR archived, both counted.
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            sidePredicate(side),
            NSPredicate(format: "deletedAt == nil")
        ])
        return try await context.perform {
            let request = VaultFile.fetchRequest(predicate: predicate)
            let files = try self.context.fetch(request)
            var byCategory: [VaultCategory: Int64] = [:]
            var total: Int64 = 0
            for f in files {
                byCategory[f.category, default: 0] += f.byteSize
                total += f.byteSize
            }
            return StorageBreakdown(bytesByCategory: byCategory, totalBytes: total, itemCount: files.count)
        }
    }

    // MARK: - Query support (App Intents / Spotlight)
    //
    // The App Intents `EntityPropertyQuery` (Shortcuts' "Find Files" action) and
    // Spotlight both funnel through here. The security-critical part is that the
    // side and lifecycle filters are enforced *in the store*: callers pass only
    // an additive content predicate, so no query path can widen the result to
    // hidden or (by default) trashed items. App Intents always query the standard
    // side, so `sidePredicate(.standard)` == `isHidden == NO` is what makes a
    // hidden item unresolvable, unsuggestable and unreturnable — not UI filtering.

    /// State selector for `find`. A default query passes `[.live]` only; trashed
    /// is opt-in, treated as a deliberate act.
    private func statePredicate(for states: Set<LifecycleFilter>) -> NSPredicate? {
        var subs: [NSPredicate] = []
        if states.contains(.live) {
            subs.append(NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "deletedAt == nil"),
                NSPredicate(format: "isArchived == %@", NSNumber(value: false))
            ]))
        }
        if states.contains(.archived) {
            subs.append(NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "deletedAt == nil"),
                NSPredicate(format: "isArchived == %@", NSNumber(value: true))
            ]))
        }
        if states.contains(.trashed) {
            subs.append(NSPredicate(format: "deletedAt != nil"))
        }
        if subs.isEmpty { return nil }
        return NSCompoundPredicate(orPredicateWithSubpredicates: subs)
    }

    /// The general query behind Shortcuts' "Find Files". `matching` is an additive
    /// content predicate built from the user's Shortcuts filters (name, category,
    /// size, date); it is AND-ed with the mandatory side and state predicates and
    /// can only ever *narrow* the result.
    public func find(side: VaultSideSelector,
                     states: Set<LifecycleFilter>,
                     matching content: NSPredicate?,
                     sortDescriptors: [NSSortDescriptor],
                     limit: Int?) async throws -> [VaultFileSnapshot] {
        guard let statePred = statePredicate(for: states) else { return [] }
        var subs: [NSPredicate] = [sidePredicate(side), statePred]
        if let content { subs.append(content) }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: subs)
        return try await context.perform {
            let request = VaultFile.fetchRequest(predicate: predicate)
            request.sortDescriptors = sortDescriptors.isEmpty
                ? [NSSortDescriptor(key: "dateAdded", ascending: false)]
                : sortDescriptors
            if let limit { request.fetchLimit = limit }
            return try self.context.fetch(request).map { $0.snapshot(retention: self.retention) }
        }
    }

    /// Resolve specific ids to snapshots — the App Intents `entities(for:)` path.
    /// Scoped to a side, so passing a hidden item's id from the standard side
    /// (the only side App Intents queries) returns nothing: a hidden item can
    /// never be resolved back into an entity.
    public func snapshots(forIDs ids: [UUID], side: VaultSideSelector) async throws -> [VaultFileSnapshot] {
        guard !ids.isEmpty else { return [] }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            sidePredicate(side),
            NSPredicate(format: "id IN %@", ids as NSArray)
        ])
        return try await fetchSnapshots(predicate: predicate)
    }

    // MARK: - File writes

    /// Register a freshly-encrypted blob's metadata. `id` is the blob's on-disk
    /// UUID filename; the caller has already written `<blobsDirectory>/<id>`.
    /// New files are always born live.
    public func importFile(id: UUID, name: String, category: VaultCategory, mimeType: String? = nil,
                           byteSize: Int64, folderID: UUID?, side: VaultSideSelector) async throws -> VaultFileSnapshot {
        try await context.perform {
            // insertNewObject(forEntityName:) rather than VaultFile(context:): with
            // a programmatically-built model shared across stores, entity lookup by
            // name is unambiguous where lookup by class can warn.
            let file = NSEntityDescription.insertNewObject(forEntityName: "VaultFile", into: self.context) as! VaultFile
            file.id = id
            file.name = name
            file.categoryRaw = category.rawValue
            file.mimeType = mimeType ?? category.genericMimeType
            file.byteSize = byteSize
            file.dateAdded = Date()
            file.isHidden = side.isHidden
            file.isArchived = false
            file.deletedAt = nil
            file.folder = try folderID.flatMap { try self.folderObject($0) }
            try self.context.save()
            return file.snapshot(retention: self.retention)
        }
    }

    public func rename(id: UUID, to newName: String) async throws {
        try await mutate(id) { $0.name = newName }
    }

    public func move(id: UUID, toFolder folderID: UUID?) async throws {
        try await context.perform {
            guard let file = try self.fileObject(id) else { throw VaultError.notFound }
            file.folder = try folderID.flatMap { try self.folderObject($0) }
            try self.context.save()
        }
    }

    /// Move to Archive. Only meaningful for a live item; a trashed item must be
    /// restored first (enforced so a file is never in two states at once).
    public func archive(id: UUID) async throws {
        try await mutate(id) { file in
            guard file.deletedAt == nil else { throw VaultError.invalidTransition }
            file.isArchived = true
        }
    }

    public func unarchive(id: UUID) async throws {
        try await mutate(id) { file in
            guard file.deletedAt == nil else { throw VaultError.invalidTransition }
            file.isArchived = false
        }
    }

    /// Soft-delete → Recently Deleted. Clears `isArchived` so the item lives in
    /// exactly one place. Reversible for `retention`; the blob stays on disk.
    public func trash(id: UUID) async throws {
        try await mutate(id) { file in
            file.deletedAt = Date()
            file.isArchived = false // one state at a time
        }
    }

    /// Restore a trashed item to live. It comes back un-archived, into the main
    /// grid, regardless of where it was before — the safe, predictable landing.
    public func restore(id: UUID) async throws {
        try await mutate(id) { file in
            guard file.deletedAt != nil else { throw VaultError.invalidTransition }
            file.deletedAt = nil
            file.isArchived = false
        }
    }

    /// Move an item to the hidden side (or back). Preserves its live/archived
    /// state; only the side changes.
    public func setHidden(id: UUID, _ hidden: Bool) async throws {
        try await mutate(id) { $0.isHidden = hidden }
    }

    /// Permanent erase of a single trashed item: record + blob. Cannot be undone.
    public func deleteForever(id: UUID) async throws {
        try await context.perform {
            guard let file = try self.fileObject(id) else { throw VaultError.notFound }
            guard file.deletedAt != nil else { throw VaultError.invalidTransition }
            let blobID = file.id
            self.context.delete(file)
            try self.context.save()
            self.deleteBlob(blobID)
        }
    }

    /// Empty Recently Deleted for one side: erase every trashed record and blob.
    @discardableResult
    public func emptyRecentlyDeleted(side: VaultSideSelector) async throws -> Int {
        try await context.perform {
            let request = VaultFile.fetchRequest(predicate: self.trashedPredicate(side))
            let files = try self.context.fetch(request)
            let ids = files.map { $0.id }
            files.forEach { self.context.delete($0) }
            try self.context.save()
            ids.forEach { self.deleteBlob($0) }
            return ids.count
        }
    }

    /// The launch sweep. Erase every item whose `deletedAt` is older than the
    /// retention window, across BOTH sides — expiry is not a per-side action. A
    /// 29-day-old item survives; a 30-day-plus one is gone, blob included.
    /// Returns the purged ids so a caller can also drop them from any index.
    @discardableResult
    public func purgeExpired(now: Date = Date()) async throws -> [UUID] {
        let cutoff = now.addingTimeInterval(-retention)
        return try await context.perform {
            let request = VaultFile.fetchRequest(
                predicate: NSPredicate(format: "deletedAt != nil AND deletedAt < %@", cutoff as NSDate))
            let files = try self.context.fetch(request)
            let ids = files.map { $0.id }
            files.forEach { self.context.delete($0) }
            try self.context.save()
            ids.forEach { self.deleteBlob($0) }
            return ids
        }
    }

    // MARK: - Folders

    public func createFolder(name: String, colorIndex: Int, side: VaultSideSelector) async throws -> VaultFolderSnapshot {
        try await context.perform {
            let folder = NSEntityDescription.insertNewObject(forEntityName: "VaultFolder", into: self.context) as! VaultFolder
            folder.id = UUID()
            folder.name = name
            folder.colorIndex = Int64(colorIndex)
            folder.dateCreated = Date()
            folder.isHidden = side.isHidden
            try self.context.save()
            return self.folderSnapshot(folder)
        }
    }

    public func folders(side: VaultSideSelector) async throws -> [VaultFolderSnapshot] {
        try await context.perform {
            let request = VaultFolder.fetchRequest(predicate: self.sidePredicate(side))
            request.sortDescriptors = [NSSortDescriptor(key: "dateCreated", ascending: true)]
            return try self.context.fetch(request).map { self.folderSnapshot($0) }
        }
    }

    /// Delete a folder without deleting its files (nullify rule). Its files fall
    /// back to "no folder".
    public func deleteFolder(id: UUID) async throws {
        try await context.perform {
            guard let folder = try self.folderObject(id) else { throw VaultError.notFound }
            self.context.delete(folder)
            try self.context.save()
        }
    }

    // MARK: - Backup / restore bridge
    //
    // Backup is the one operation that intentionally spans ALL states and the
    // sides the caller can decrypt. It is the caller's job (the app layer) to
    // supply the vault keys per side — the hidden side's key is biometry-gated, so
    // an unattended auto-backup passes only `[.standard]`, while a manual,
    // authenticated backup passes both. The store just enumerates and re-creates.

    /// Every file on the given sides, in every lifecycle state, for a backup.
    public func allFilesForBackup(sides: Set<VaultSideSelector>) async throws -> [VaultFileSnapshot] {
        guard !sides.isEmpty else { return [] }
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: sides.map { sidePredicate($0) })
        return try await fetchSnapshots(predicate: predicate)
    }

    /// Every folder on the given sides, for a backup.
    public func allFoldersForBackup(sides: Set<VaultSideSelector>) async throws -> [VaultFolderSnapshot] {
        guard !sides.isEmpty else { return [] }
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: sides.map { sidePredicate($0) })
        return try await context.perform {
            let request = VaultFolder.fetchRequest(predicate: predicate)
            request.sortDescriptors = [NSSortDescriptor(key: "dateCreated", ascending: true)]
            return try self.context.fetch(request).map { self.folderSnapshot($0) }
        }
    }

    /// Re-create a folder from a backup, assigning it a fresh local UUID (the
    /// caller maps the archive's folder id → the returned UUID so items can be
    /// re-linked). Preserves name, colour, side and creation date.
    public func createFolderForRestore(name: String, colorIndex: Int, hidden: Bool,
                                       createdAt: Date) async throws -> UUID {
        try await context.perform {
            let folder = NSEntityDescription.insertNewObject(forEntityName: "VaultFolder", into: self.context) as! VaultFolder
            folder.id = UUID()
            folder.name = name
            folder.colorIndex = Int64(colorIndex)
            folder.dateCreated = createdAt
            folder.isHidden = hidden
            try self.context.save()
            return folder.id
        }
    }

    /// Re-create a file from a backup with its exact lifecycle state. `id` is a
    /// fresh local blob UUID (the caller has already re-encrypted the plaintext to
    /// `<blobsDirectory>/<id>`). A trashed item keeps its `deletedAt` so the
    /// 30-day purge clock resumes from the original deletion time; `isArchived` is
    /// forced off for a trashed item so a file is never in two states at once.
    public func importRestored(id: UUID, name: String, category: VaultCategory, mimeType: String,
                               byteSize: Int64, folderID: UUID?, hidden: Bool, archived: Bool,
                               deletedAt: Date?, dateAdded: Date) async throws {
        try await context.perform {
            let file = NSEntityDescription.insertNewObject(forEntityName: "VaultFile", into: self.context) as! VaultFile
            file.id = id
            file.name = name
            file.categoryRaw = category.rawValue
            file.mimeType = mimeType
            file.byteSize = byteSize
            file.dateAdded = dateAdded
            file.isHidden = hidden
            file.deletedAt = deletedAt
            file.isArchived = (deletedAt == nil) ? archived : false
            file.folder = try folderID.flatMap { try self.folderObject($0) }
            try self.context.save()
        }
    }

    // MARK: - Internals

    private func fetchSnapshots(predicate: NSPredicate) async throws -> [VaultFileSnapshot] {
        try await context.perform {
            let request = VaultFile.fetchRequest(predicate: predicate)
            request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]
            return try self.context.fetch(request).map { $0.snapshot(retention: self.retention) }
        }
    }

    private func count(predicate: NSPredicate) async throws -> Int {
        try await context.perform {
            let request = VaultFile.fetchRequest(predicate: predicate)
            return try self.context.count(for: request)
        }
    }

    /// Fetch a file, apply `body`, save. `body` may throw to veto an invalid
    /// transition, in which case nothing is saved.
    private func mutate(_ id: UUID, _ body: @escaping (VaultFile) throws -> Void) async throws {
        try await context.perform {
            guard let file = try self.fileObject(id) else { throw VaultError.notFound }
            try body(file)
            try self.context.save()
        }
    }

    // These run inside a `context.perform` block, on the context's queue.
    private func fileObject(_ id: UUID) throws -> VaultFile? {
        let request = VaultFile.fetchRequest(predicate: NSPredicate(format: "id == %@", id as NSUUID))
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func folderObject(_ id: UUID) throws -> VaultFolder? {
        let request = VaultFolder.fetchRequest(predicate: NSPredicate(format: "id == %@", id as NSUUID))
        request.fetchLimit = 1
        return try context.fetch(request).first
    }

    private func folderSnapshot(_ folder: VaultFolder) -> VaultFolderSnapshot {
        // Count only live files in the folder — archived/trashed excluded.
        let liveCount = folder.files.filter { $0.deletedAt == nil && !$0.isArchived }.count
        return VaultFolderSnapshot(
            id: folder.id, name: folder.name, colorIndex: Int(folder.colorIndex),
            dateCreated: folder.dateCreated, isHidden: folder.isHidden, liveItemCount: liveCount)
    }

    private func deleteBlob(_ id: UUID) {
        let url = blobsDirectory.appendingPathComponent(id.uuidString)
        try? FileManager.default.removeItem(at: url)
    }
}

/// Errors from the lifecycle engine, distinct from the crypto errors.
public enum VaultError: Error, Equatable {
    case notFound
    /// An operation that would put a file in an impossible state — e.g. archiving
    /// a trashed item, or restoring one that isn't trashed.
    case invalidTransition
}

// Typed fetch-request helper so call sites read cleanly. Core Data's generic
// `fetchRequest()` returns `NSFetchRequest<NSFetchRequestResult>`; this pins the
// element type and attaches a predicate in one step.
extension VaultFile {
    static func fetchRequest(predicate: NSPredicate) -> NSFetchRequest<VaultFile> {
        let request = NSFetchRequest<VaultFile>(entityName: "VaultFile")
        request.predicate = predicate
        return request
    }
}

extension VaultFolder {
    static func fetchRequest(predicate: NSPredicate) -> NSFetchRequest<VaultFolder> {
        let request = NSFetchRequest<VaultFolder>(entityName: "VaultFolder")
        request.predicate = predicate
        return request
    }
}
