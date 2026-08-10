import AppIntents
import Foundation
import FileWallKit

/// An explicit "Find Files" intent, alongside the one the `EntityPropertyQuery`
/// generates automatically.
///
/// Why both: the `EntityPropertyQuery` conformance gives Shortcuts a rich, fully
/// composable "Find Files" action for free (open-ended filters + sorting). This
/// hand-written intent is the *simple* front door — a few named parameters and a
/// spoken result — reachable from Siri and the App Shortcuts phrase "Find photos
/// in FileWall". It returns the same `VaultFileEntity` values, so its output
/// pipes into any other Shortcuts action.
struct FindFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Find Files"

    static var description = IntentDescription(
        "Search your vault by name, type, size or date. Only files in the main vault are searched.")

    // Reads vault content → require local authentication (Face ID / Touch ID /
    // passcode) before it runs, even from a locked-device automation. iOS 16.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Search Text")
    var searchText: String?

    @Parameter(title: "Category")
    var category: FileCategoryAppEnum?

    // Archived and Recently Deleted are opt-in, matching the query default.
    // Trashed is not destructive to *read*, but surfacing it is a deliberate act.
    @Parameter(title: "Include Archived", default: false)
    var includeArchived: Bool

    @Parameter(title: "Include Recently Deleted", default: false)
    var includeTrashed: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Find files matching \(\.$searchText)") {
            \.$category
            \.$includeArchived
            \.$includeTrashed
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[VaultFileEntity]> & ProvidesDialog {
        var states: Set<LifecycleFilter> = [.live]
        if includeArchived { states.insert(.archived) }
        if includeTrashed { states.insert(.trashed) }

        var predicates: [NSPredicate] = []
        if let searchText, !searchText.isEmpty {
            predicates.append(NSPredicate(format: "name CONTAINS[cd] %@", searchText))
        }
        if let category {
            predicates.append(NSPredicate(format: "categoryRaw == %@", category.rawValue))
        }
        let content = predicates.isEmpty ? nil
            : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

        let entities = try await VaultService.shared
            .find(states: states,
                  matching: content,
                  sort: [NSSortDescriptor(key: "dateAdded", ascending: false)],
                  limit: nil)
            .map(VaultFileEntity.init)

        let noun = entities.count == 1 ? "file" : "files"
        return .result(value: entities, dialog: "Found \(entities.count) \(noun).")
    }
}
