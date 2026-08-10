import Foundation
import CoreData
import FileWallKit

/// The single bridge between the App Intents / UI layers and `FileWallKit`.
///
/// Every entry point here queries the **standard** side only. That is the
/// enforcement point for the hard rule "no query ever returns a hidden item":
/// App Intents never touch the hidden side, so a hidden file is never fetched,
/// never snapshotted, and therefore never becomes an `AppEntity`. The hidden
/// side is reachable only through explicit, authenticated UI flows (not modelled
/// in this stage).
///
/// A plain `final class` singleton rather than an actor: it holds no mutable
/// shared state of its own — the `VaultStore` it wraps is itself an actor and
/// owns all synchronisation. This just resolves the store once and forwards.
final class VaultService {
    static let shared = VaultService()

    /// The store is created once, lazily, off the first call. Wrapped in a Task
    /// so concurrent first callers all await the same construction rather than
    /// racing to build two stores over the same SQLite file.
    private let storeTask: Task<VaultStore, Error>

    private init() {
        storeTask = Task {
            try VaultStore(blobsDirectory: AppEnvironment.vaultDirectory)
        }
    }

    private func store() async throws -> VaultStore { try await storeTask.value }

    // MARK: - App Intents query surface (standard side only)

    /// Resolve ids to snapshots. Hidden ids resolve to nothing — the store scopes
    /// to the standard side, so this cannot round-trip a hidden item back into an
    /// entity even if its id leaks.
    func snapshots(forIDs ids: [UUID]) async throws -> [VaultFileSnapshot] {
        try await store().snapshots(forIDs: ids, side: .standard)
    }

    /// The general query behind Shortcuts' "Find Files" and the string query.
    /// `states` defaults to `[.live]` at the call sites so a bare query never
    /// surfaces archived or trashed items.
    func find(states: Set<LifecycleFilter>,
              matching content: NSPredicate?,
              sort: [NSSortDescriptor],
              limit: Int?) async throws -> [VaultFileSnapshot] {
        try await store().find(side: .standard, states: states, matching: content,
                               sortDescriptors: sort, limit: limit)
    }

    /// Recent live files, for Siri/Shortcuts entity suggestions.
    func recentLive(limit: Int) async throws -> [VaultFileSnapshot] {
        try await store().find(side: .standard, states: [.live], matching: nil,
                               sortDescriptors: [NSSortDescriptor(key: "dateAdded", ascending: false)],
                               limit: limit)
    }
}
