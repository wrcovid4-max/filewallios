import Foundation

/// Coarse content category. Stored as a raw string on `VaultFile` and surfaced
/// to the App Intents `AppEnum` and the storage breakdown. Kept deliberately
/// small — the vault sorts files into buckets a user reasons about, not MIME
/// types.
public enum VaultCategory: String, CaseIterable, Sendable {
    case photo
    case video
    case document
    case other

    /// Bucket a MIME type into a category. Used when ingesting a restored item
    /// whose manifest carries the real MIME type (the source of truth), and for
    /// any import that knows only the MIME type.
    public init(mimeType: String) {
        let m = mimeType.lowercased()
        if m.hasPrefix("image/") { self = .photo }
        else if m.hasPrefix("video/") { self = .video }
        else if m.hasPrefix("application/pdf")
                    || m.hasPrefix("text/")
                    || m.contains("word") || m.contains("document")
                    || m.contains("spreadsheet") || m.contains("presentation")
                    || m.contains("excel") || m.contains("powerpoint") { self = .document }
        else { self = .other }
    }

    /// A generic MIME type for a category, used only when a real one is unknown.
    public var genericMimeType: String {
        switch self {
        case .photo: return "image/jpeg"
        case .video: return "video/mp4"
        case .document: return "application/pdf"
        case .other: return "application/octet-stream"
        }
    }
}

/// Which side of the vault a file or folder lives on. Orthogonal to lifecycle
/// state: an item is (standard | hidden) *and* (live | archived | trashed).
/// The hidden side keeps its own separate Archive and Recently Deleted so
/// nothing leaks across the boundary.
public enum VaultSideSelector: Sendable {
    case standard
    case hidden

    var isHidden: Bool { self == .hidden }
}

/// The lifecycle state of a file within one vault side. Modelled as a computed
/// enum over the `isArchived` / `deletedAt` columns rather than a free-for-all of
/// booleans, so "which state is this in" has exactly one answer and callers can
/// `switch` instead of re-deriving the precedence rules.
///
/// Precedence, and why: a `deletedAt` date wins over everything. Trashing clears
/// `isArchived` on the way in, so the two flags can never both be "on", but even
/// if a bug set both, `trashed` is the safe interpretation — an item on its way
/// to permanent deletion must never be treated as merely archived.
public enum VaultFileState: Equatable, Sendable {
    case live
    case archived
    /// Carries the date at which the auto-purge sweep will erase this item.
    case trashed(autoPurgeAt: Date)
}

/// Which lifecycle states a query should return. A default query passes
/// `[.live]` only — archived and trashed are opt-in. Kept separate from
/// `VaultFileState` because a query selects a *set* of states, while a file is in
/// exactly one.
public enum LifecycleFilter: Sendable, Hashable, CaseIterable {
    case live
    case archived
    case trashed
}

/// A Sendable, value-type snapshot of a `VaultFile`. The store hands these out
/// instead of live `NSManagedObject`s so the UI, App Intents and watch layers
/// never touch Core Data threading and never accidentally mutate the graph.
public struct VaultFileSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let category: VaultCategory
    /// Original MIME type; carried through the cross-platform backup manifest.
    public let mimeType: String
    /// On-disk size of the encrypted blob, in bytes. This is what the storage
    /// breakdown counts — archived items still occupy it, trashed items are
    /// excluded because they are on their way out.
    public let byteSize: Int64
    public let dateAdded: Date
    public let state: VaultFileState
    /// The raw moment the file entered Recently Deleted (nil if not trashed). The
    /// backup manifest needs this exact time — `state`'s `.trashed(autoPurgeAt:)`
    /// carries the *purge* date (deletedAt + 30d), which is a different value.
    public let deletedAt: Date?
    public let folderID: UUID?
    /// True only for hidden-vault items. Callers that must never surface hidden
    /// content assert on this, but the real defence is the fetch predicate: a
    /// hidden item is never fetched in the first place.
    public let isHidden: Bool

    public init(id: UUID, name: String, category: VaultCategory, mimeType: String, byteSize: Int64,
                dateAdded: Date, state: VaultFileState, deletedAt: Date?, folderID: UUID?, isHidden: Bool) {
        self.id = id
        self.name = name
        self.category = category
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.dateAdded = dateAdded
        self.state = state
        self.deletedAt = deletedAt
        self.folderID = folderID
        self.isHidden = isHidden
    }
}

/// A Sendable snapshot of a `VaultFolder`.
public struct VaultFolderSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    /// Palette index, matching Android's `colorIndex` (survives backup round trips).
    public let colorIndex: Int
    public let dateCreated: Date
    public let isHidden: Bool
    /// Count of *live* files in the folder. Archived and trashed items are
    /// excluded — a folder's badge reflects what you'd see if you opened it.
    public let liveItemCount: Int

    public init(id: UUID, name: String, colorIndex: Int, dateCreated: Date,
                isHidden: Bool, liveItemCount: Int) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.dateCreated = dateCreated
        self.isHidden = isHidden
        self.liveItemCount = liveItemCount
    }
}

/// The per-side storage breakdown surfaced by `VaultStatusIntent`, the widget and
/// the Settings chart. Bytes by category plus totals. Excludes trashed items,
/// includes archived ones.
public struct StorageBreakdown: Equatable, Sendable {
    public let bytesByCategory: [VaultCategory: Int64]
    public let totalBytes: Int64
    public let itemCount: Int

    public init(bytesByCategory: [VaultCategory: Int64], totalBytes: Int64, itemCount: Int) {
        self.bytesByCategory = bytesByCategory
        self.totalBytes = totalBytes
        self.itemCount = itemCount
    }
}
