import Foundation
import CoreData

/// Core Data managed objects for the vault's metadata.
///
/// Metadata — names, types, folder membership, lifecycle flags — lives ONLY
/// here. The blobs on disk are UUID filenames with no extension and no embedded
/// metadata, so a stolen disk yields opaque ciphertext and nothing about what it
/// is. `deletedAt`/`isArchived`/`isHidden` are plain columns; the lifecycle
/// *state* is computed from them (see `VaultFileState`) rather than stored, so
/// there is a single source of truth and no way for a stored state to disagree
/// with the flags.
///
/// No SwiftData: it needs iOS 17. Core Data is the iOS 16 equivalent and is what
/// the whole storage layer is built on.
@objc(VaultFile)
final class VaultFile: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var categoryRaw: String
    @NSManaged var byteSize: Int64
    @NSManaged var dateAdded: Date
    @NSManaged var isHidden: Bool
    @NSManaged var isArchived: Bool
    /// nil == live-or-archived; a date == in Recently Deleted since that moment.
    @NSManaged var deletedAt: Date?
    @NSManaged var folder: VaultFolder?

    var category: VaultCategory { VaultCategory(rawValue: categoryRaw) ?? .other }

    /// The single place the lifecycle precedence rule lives. `deletedAt` wins
    /// over `isArchived`; see `VaultFileState` for why that ordering is the safe
    /// one.
    func state(retention: TimeInterval) -> VaultFileState {
        if let deletedAt { return .trashed(autoPurgeAt: deletedAt.addingTimeInterval(retention)) }
        return isArchived ? .archived : .live
    }

    func snapshot(retention: TimeInterval) -> VaultFileSnapshot {
        VaultFileSnapshot(
            id: id, name: name, category: category, byteSize: byteSize,
            dateAdded: dateAdded, state: state(retention: retention),
            folderID: folder?.id, isHidden: isHidden)
    }
}

@objc(VaultFolder)
final class VaultFolder: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var name: String
    @NSManaged var colorHex: String
    @NSManaged var dateCreated: Date
    @NSManaged var isHidden: Bool
    @NSManaged var files: Set<VaultFile>
}
