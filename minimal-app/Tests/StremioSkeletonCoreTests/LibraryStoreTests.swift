import Foundation
import XCTest
@testable import StremioSkeletonCore

final class LibraryStoreTests: XCTestCase {
    func testTogglePersistsAndRemovesItem() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("library.json")
        let item = MetaItem(id: "tt1254207", type: "movie", name: "Big Buck Bunny")
        let store = LibraryStore(fileURL: url)

        let added = try await store.toggle(item)
        XCTAssertEqual(added, [item])
        let contains = try await store.contains(item)
        XCTAssertTrue(contains)

        let reloaded = LibraryStore(fileURL: url)
        let persisted = try await reloaded.items()
        XCTAssertEqual(persisted, [item])
        let removed = try await reloaded.toggle(item)
        XCTAssertEqual(removed, [])
    }

    func testRemoteRemovalIsApplied() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let item = MetaItem(id: "tt1", type: "movie", name: "Movie")
        _ = try await store.toggle(item)

        let result = try await store.applyRemote([
            RemoteLibraryItem(item: item, removed: true)
        ])

        XCTAssertTrue(result.isEmpty)
    }

    func testRemoteSnapshotDoesNotRetainUnrelatedLocalItems() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let local = MetaItem(id: "local", type: "movie", name: "Local Movie")
        let remote = MetaItem(id: "remote", type: "series", name: "Remote Series")
        _ = try await store.toggle(local)

        let result = try await store.replaceWithRemoteSnapshot([
            RemoteLibraryItem(item: remote, removed: false),
            RemoteLibraryItem(item: local, removed: true),
        ])

        XCTAssertEqual(result, [remote])
        let persisted = try await store.items()
        XCTAssertEqual(persisted, [remote])
    }
}
