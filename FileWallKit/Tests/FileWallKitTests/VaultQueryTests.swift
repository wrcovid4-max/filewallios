import XCTest
import CoreData
@testable import FileWallKit

/// Tests for the query surface App Intents / Spotlight sit on top of. These
/// encode the two hard privacy rules at the exact boundary they must hold:
///   * no query ever returns a hidden item;
///   * no default (state-unspecified) query returns a trashed one.
final class VaultQueryTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }
    private func makeStore() throws -> VaultStore {
        try VaultStore(blobsDirectory: tempDir, inMemory: true)
    }
    @discardableResult
    private func add(_ store: VaultStore, name: String = "f", category: VaultCategory = .photo,
                     size: Int64 = 100, side: VaultSideSelector = .standard) async throws -> VaultFileSnapshot {
        try await store.importFile(id: UUID(), name: name, category: category, byteSize: size,
                                   folderID: nil, side: side)
    }

    // MARK: The hard rules

    func testDefaultQueryReturnsOnlyLiveStandardItems() async throws {
        let store = try makeStore()
        let live = try await add(store, name: "live")
        let archived = try await add(store, name: "arch")
        let trashed = try await add(store, name: "trash")
        _ = try await add(store, name: "hidden", side: .hidden)
        try await store.archive(id: archived.id)
        try await store.trash(id: trashed.id)

        // states: [.live] is what every default query path passes.
        let result = try await store.find(side: .standard, states: [.live],
                                          matching: nil, sortDescriptors: [], limit: nil)
        XCTAssertEqual(result.map(\.id), [live.id])
    }

    func testHiddenIdIsUnresolvable() async throws {
        let store = try makeStore()
        let hidden = try await add(store, name: "secret", side: .hidden)
        // Even handed the exact id, the standard-side query resolves nothing —
        // a hidden item can never be turned back into an entity.
        let resolved = try await store.snapshots(forIDs: [hidden.id], side: .standard)
        XCTAssertTrue(resolved.isEmpty)
    }

    func testTrashedIsReturnedOnlyWhenExplicitlyRequested() async throws {
        let store = try makeStore()
        let trashed = try await add(store, name: "gone")
        try await store.trash(id: trashed.id)

        let byDefault = try await store.find(side: .standard, states: [.live],
                                             matching: nil, sortDescriptors: [], limit: nil)
        XCTAssertTrue(byDefault.isEmpty)

        let explicit = try await store.find(side: .standard, states: [.trashed],
                                            matching: nil, sortDescriptors: [], limit: nil)
        XCTAssertEqual(explicit.map(\.id), [trashed.id])
    }

    func testEmptyStateSetReturnsNothing() async throws {
        let store = try makeStore()
        _ = try await add(store)
        let result = try await store.find(side: .standard, states: [],
                                          matching: nil, sortDescriptors: [], limit: nil)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Content predicates + sorting behave

    func testContentPredicateNarrowsWithinSecurityScope() async throws {
        let store = try makeStore()
        _ = try await add(store, name: "invoice-jan", category: .document)
        let feb = try await add(store, name: "invoice-feb", category: .document)
        _ = try await add(store, name: "vacation", category: .photo)

        let predicate = NSPredicate(format: "name CONTAINS[cd] %@", "feb")
        let result = try await store.find(side: .standard, states: [.live],
                                          matching: predicate, sortDescriptors: [], limit: nil)
        XCTAssertEqual(result.map(\.id), [feb.id])
    }

    func testHiddenNeverLeaksThroughAContentPredicate() async throws {
        let store = try makeStore()
        _ = try await add(store, name: "match", side: .standard)
        _ = try await add(store, name: "match", side: .hidden) // same name, hidden side

        let predicate = NSPredicate(format: "name == %@", "match")
        let result = try await store.find(side: .standard, states: [.live, .archived, .trashed],
                                          matching: predicate, sortDescriptors: [], limit: nil)
        // The hidden namesake is excluded even with all states requested.
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result.contains { $0.isHidden })
    }

    func testSortDescriptorApplied() async throws {
        let store = try makeStore()
        let a = try await add(store, name: "a", size: 300)
        let b = try await add(store, name: "b", size: 100)
        let c = try await add(store, name: "c", size: 200)

        let bySizeAsc = try await store.find(side: .standard, states: [.live], matching: nil,
                                             sortDescriptors: [NSSortDescriptor(key: "byteSize", ascending: true)],
                                             limit: nil)
        XCTAssertEqual(bySizeAsc.map(\.id), [b.id, c.id, a.id])
    }
}
