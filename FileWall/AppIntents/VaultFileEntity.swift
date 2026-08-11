import AppIntents
import Foundation
import FileWallKit

/// A file in the vault, exposed to Siri, Shortcuts and Spotlight.
///
/// # A hidden file is never one of these
///
/// This type is only ever constructed from a `VaultFileSnapshot` produced by
/// `VaultService`, which queries the standard side exclusively. There is no code
/// path that builds a `VaultFileEntity` for a hidden item, so a hidden item
/// cannot be resolved, suggested, indexed or returned. The guarantee lives in
/// *what can become an entity*, not in filtering after the fact.
struct VaultFileEntity: AppEntity, Identifiable {

    // The Xcode 14.2 SDK's AppEntity requires `typeDisplayRepresentation`
    // (conformance to TypeDisplayRepresentable) — confirmed by the compiler, which
    // rejected `typeDisplayName`. Same explicit-initializer form as the AppEnums.
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Vault File")
    }

    static var defaultQuery = VaultFileQuery()

    var id: UUID

    // @Property-wrapped fields are the ones the EntityPropertyQuery can filter and
    // sort on — they become the columns of Shortcuts' "Find Files" action.
    @Property(title: "Name")
    var name: String

    @Property(title: "Category")
    var category: FileCategoryAppEnum

    // Size in bytes. Int is Comparable, so the "greater than / less than" size
    // filters come for free. Shown to the user as a formatted string in the
    // display representation below.
    @Property(title: "Size")
    var size: Int

    @Property(title: "Date Added")
    var dateAdded: Date

    @Property(title: "State")
    var state: FileStateAppEnum

    // Not filterable, informational: the date a trashed item will be auto-purged.
    // nil unless `state == .trashed`.
    @Property(title: "Auto-Purge Date")
    var autoPurgeDate: Date?

    /// Set only when the user has opted into thumbnails leaving the app. When nil
    /// (the default) the display representation falls back to a category glyph,
    /// which is not vault content. See `displayRepresentation`.
    var thumbnailImageName: String?

    var displayRepresentation: DisplayRepresentation {
        let subtitle = LocalizedStringResource(stringLiteral: Self.sizeFormatter.string(fromByteCount: Int64(size)))
        // Image policy: a real thumbnail is a decrypted copy of vault content, so
        // it only appears when the user has opted in (thumbnailImageName set to a
        // shared, app-group image the extension can read). Otherwise we show the
        // category glyph — the *kind* of file, never its contents.
        let image: DisplayRepresentation.Image
        if let thumbnailImageName {
            image = DisplayRepresentation.Image(named: thumbnailImageName)
        } else {
            image = DisplayRepresentation.Image(systemName: category.symbolName)
        }
        return DisplayRepresentation(title: "\(name)", subtitle: subtitle, image: image)
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}

extension VaultFileEntity {
    /// The one constructor. Everything reaching Siri/Shortcuts/Spotlight comes
    /// through here from a standard-side snapshot.
    init(_ snapshot: VaultFileSnapshot) {
        self.id = snapshot.id
        self.name = snapshot.name
        self.category = FileCategoryAppEnum(snapshot.category)
        self.size = Int(snapshot.byteSize)
        self.dateAdded = snapshot.dateAdded
        self.state = FileStateAppEnum(snapshot.state)
        if case let .trashed(autoPurgeAt) = snapshot.state {
            self.autoPurgeDate = autoPurgeAt
        } else {
            self.autoPurgeDate = nil
        }
        self.thumbnailImageName = nil // opt-in thumbnails wired in the Spotlight/UI stage
    }
}
