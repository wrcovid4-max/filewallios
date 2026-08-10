import AppIntents
import FileWallKit

/// Content category, as an `AppEnum` so Shortcuts renders it as a picker in the
/// "Find Files" action ("Category is Photo"). Mirrors `FileWallKit.VaultCategory`
/// one-to-one; kept as a separate type because `AppEnum` conformance belongs in
/// the app target, not the framework.
enum FileCategoryAppEnum: String, AppEnum {
    case photo
    case video
    case document
    case other

    // AppEnum's type-level display. `TypeDisplayRepresentation(name:)` is the
    // iOS 16.0 form; if a future SDK swap complains, it also accepts a string
    // literal directly.
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Category")
    }

    static var caseDisplayRepresentations: [FileCategoryAppEnum: DisplayRepresentation] {
        [
            .photo: DisplayRepresentation(title: "Photo"),
            .video: DisplayRepresentation(title: "Video"),
            .document: DisplayRepresentation(title: "Document"),
            .other: DisplayRepresentation(title: "Other")
        ]
    }

    /// A generic SF Symbol per category. Safe to show anywhere — it depicts the
    /// *kind* of file, never its contents, so it needs no thumbnail opt-in.
    var symbolName: String {
        switch self {
        case .photo: return "photo"
        case .video: return "film"
        case .document: return "doc"
        case .other: return "questionmark.square.dashed"
        }
    }

    init(_ category: VaultCategory) {
        self = FileCategoryAppEnum(rawValue: category.rawValue) ?? .other
    }
}

/// Lifecycle state as an `AppEnum` so it can be a Shortcuts filter. The state
/// enum is deliberately flat (`AppEnum` cannot carry an associated value), so the
/// trashed auto-purge date is exposed as a separate optional property on the
/// entity rather than riding inside the case.
enum FileStateAppEnum: String, AppEnum {
    case live
    case archived
    case trashed

    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "State")
    }

    static var caseDisplayRepresentations: [FileStateAppEnum: DisplayRepresentation] {
        [
            .live: DisplayRepresentation(title: "In Vault"),
            .archived: DisplayRepresentation(title: "Archived"),
            .trashed: DisplayRepresentation(title: "Recently Deleted")
        ]
    }

    /// Bridge to the framework's query filter.
    var lifecycleFilter: LifecycleFilter {
        switch self {
        case .live: return .live
        case .archived: return .archived
        case .trashed: return .trashed
        }
    }

    init(_ state: VaultFileState) {
        switch state {
        case .live: self = .live
        case .archived: self = .archived
        case .trashed: self = .trashed
        }
    }
}
