import AppIntents
import Foundation
import FileWallKit

/// The query that makes the vault composable from Shortcuts.
///
/// Three conformances, each earning its place:
///  * `EntityQuery`         — resolve ids (e.g. a saved Shortcuts reference) and
///                            offer suggestions.
///  * `EntityStringQuery`   — let Siri resolve "the invoice one" from a spoken
///                            fragment.
///  * `EntityPropertyQuery` — the high-leverage one: it *generates* Shortcuts'
///                            "Find Files" action, with real filters and sorting,
///                            without a hand-written intent per query.
///
/// Security is enforced in one place — `VaultService`, which only ever queries
/// the standard side and defaults to live-only. Every method below inherits that:
/// no path returns a hidden item, and no default (state-unspecified) path returns
/// a trashed one.
struct VaultFileQuery: EntityQuery {

    // MARK: EntityQuery

    func entities(for identifiers: [UUID]) async throws -> [VaultFileEntity] {
        try await VaultService.shared.snapshots(forIDs: identifiers).map(VaultFileEntity.init)
    }

    func suggestedEntities() async throws -> [VaultFileEntity] {
        try await VaultService.shared.recentLive(limit: 8).map(VaultFileEntity.init)
    }
}

// MARK: - EntityStringQuery

extension VaultFileQuery: EntityStringQuery {
    /// Spoken/typed fragment → live files whose name contains it. Live only:
    /// Siri must not surface archived or trashed items from a loose match.
    func entities(matching string: String) async throws -> [VaultFileEntity] {
        let predicate = NSPredicate(format: "name CONTAINS[cd] %@", string)
        return try await VaultService.shared
            .find(states: [.live], matching: predicate, sort: [], limit: 25)
            .map(VaultFileEntity.init)
    }
}

// MARK: - EntityPropertyQuery (generates the "Find Files" Shortcuts action)

extension VaultFileQuery: EntityPropertyQuery {

    /// The uniform value every property comparator maps to. Modelling it as an
    /// enum — rather than a bare `NSPredicate` — lets the *state* filter select
    /// lifecycle states (which the store treats specially and securely) while
    /// every other filter contributes an additive content predicate. This is what
    /// keeps "default excludes trashed" true: a query with no `.state` comparator
    /// falls back to `[.live]`.
    enum ComparatorMappingType {
        case content(NSPredicate)
        case state(LifecycleFilter)
    }

    /// The filterable columns Shortcuts shows in "Find Files". Predicates are
    /// written against Core Data attribute names (`byteSize`, `categoryRaw`),
    /// which differ from the entity's display names — that mapping lives here so
    /// the store stays a dumb predicate executor.
    static var properties = QueryProperties {
        Property(\VaultFileEntity.$name) {
            EqualToComparator { .content(NSPredicate(format: "name ==[cd] %@", $0)) }
            ContainsComparator { .content(NSPredicate(format: "name CONTAINS[cd] %@", $0)) }
        }
        Property(\VaultFileEntity.$category) {
            EqualToComparator { .content(NSPredicate(format: "categoryRaw == %@", $0.rawValue)) }
        }
        Property(\VaultFileEntity.$size) {
            GreaterThanComparator { .content(NSPredicate(format: "byteSize > %ld", $0)) }
            LessThanComparator { .content(NSPredicate(format: "byteSize < %ld", $0)) }
        }
        Property(\VaultFileEntity.$dateAdded) {
            GreaterThanComparator { .content(NSPredicate(format: "dateAdded > %@", $0 as NSDate)) }
            LessThanComparator { .content(NSPredicate(format: "dateAdded < %@", $0 as NSDate)) }
        }
        Property(\VaultFileEntity.$state) {
            EqualToComparator { .state($0.lifecycleFilter) }
        }
    }

    static var sortingOptions = SortingOptions {
        SortableBy(\VaultFileEntity.$dateAdded)
        SortableBy(\VaultFileEntity.$name)
        SortableBy(\VaultFileEntity.$size)
    }

    /// Maps the sortable property key-paths to Core Data attribute names.
    private static let sortKeys: [PartialKeyPath<VaultFileEntity>: String] = [
        \VaultFileEntity.$dateAdded: "dateAdded",
        \VaultFileEntity.$name: "name",
        \VaultFileEntity.$size: "byteSize"
    ]

    /// The heart of "Find Files". Splits the user's comparators into lifecycle
    /// state selections and additive content predicates, defaults to live-only,
    /// and hands both to the store — which always AND-s in the standard-side
    /// (non-hidden) predicate.
    ///
    /// SDK note: this is the iOS 16 `EntityPropertyQuery` requirement. If Xcode
    /// 14.2 disagrees on the sort element type, it is `EntityQuerySort<Entity>`
    /// vs `Sort<Entity>` — match whichever the SDK declares; the body is identical.
    func entities(matching comparators: [ComparatorMappingType],
                  mode: ComparatorMode,
                  sortedBy: [EntityQuerySort<VaultFileEntity>],
                  limit: Int?) async throws -> [VaultFileEntity] {

        var states: Set<LifecycleFilter> = []
        var contentPredicates: [NSPredicate] = []
        for comparator in comparators {
            switch comparator {
            case .content(let predicate): contentPredicates.append(predicate)
            case .state(let filter): states.insert(filter)
            }
        }
        // Default: live only. A bare "Find Files" never surfaces archived or
        // trashed items — the user must add a State filter to see them.
        if states.isEmpty { states = [.live] }

        let content: NSPredicate?
        if contentPredicates.isEmpty {
            content = nil
        } else if mode == .and {
            content = NSCompoundPredicate(andPredicateWithSubpredicates: contentPredicates)
        } else {
            content = NSCompoundPredicate(orPredicateWithSubpredicates: contentPredicates)
        }

        let sortDescriptors: [NSSortDescriptor] = sortedBy.compactMap { sort in
            guard let key = Self.sortKeys[sort.by] else { return nil }
            return NSSortDescriptor(key: key, ascending: sort.order == .ascending)
        }

        return try await VaultService.shared
            .find(states: states, matching: content, sort: sortDescriptors, limit: limit)
            .map(VaultFileEntity.init)
    }
}
