import Foundation
import XCTest
@testable import StremioSkeletonCore

final class LibraryStoreTests: XCTestCase {
    func testCorruptLibraryIsPreservedAndStoreRemainsWritable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("library.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let corrupt = Data("{ definitely not a library".utf8)
        try corrupt.write(to: url)

        let store = LibraryStore(fileURL: url)
        let recoveredEmptyItems = try await store.items()
        XCTAssertEqual(recoveredEmptyItems, [])

        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("library.corrupt-") }
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveryFiles[0]), corrupt)

        let item = MetaItem(id: "tt-recovered", type: "movie", name: "Recovered")
        let recoveredItems = try await store.toggle(item)
        XCTAssertEqual(recoveredItems, [item])
        let reloadedItems = try await LibraryStore(fileURL: url).items()
        XCTAssertEqual(reloadedItems, [item])
    }

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

    func testCompleteRemoteSnapshotDoesNotRetainOmittedLocalItems() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let store = LibraryStore(fileURL: directory.appendingPathComponent("library.json"))
        let local = MetaItem(id: "local", type: "movie", name: "Local Movie")
        let remote = MetaItem(id: "remote", type: "series", name: "Remote Series")
        _ = try await store.toggle(local)

        let result = try await store.replaceWithRemoteSnapshot([
            RemoteLibraryItem(item: remote, removed: false),
        ])

        XCTAssertEqual(result, [remote])
        let persisted = try await store.items()
        XCTAssertEqual(persisted, [remote])
    }
}
