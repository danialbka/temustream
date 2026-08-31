import Foundation
import XCTest
@testable import StremioSkeletonCore

final class LibraryMutationSerializationTests: XCTestCase {
    @MainActor
    func testRegistryDoesNotRetainInactiveStoreWithoutAnOwner() {
        let registry = FileBackedStoreRegistry<RegistryLifetimeProbe>()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        weak var released: RegistryLifetimeProbe?
        do {
            let store = registry.store(for: url) { RegistryLifetimeProbe() }
            released = store
        }
        XCTAssertNil(released)
    }

    @MainActor
    func testRetainedStoreKeepsDelayedToggleAcrossProfileReactivation() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("library.json")
        let registry = FileBackedStoreRegistry<LibraryStore>()
        let original = registry.store(for: storeURL) {
            LibraryStore(fileURL: storeURL)
        }
        let firstItem = MetaItem(id: "first", type: "movie", name: "First")
        let secondItem = MetaItem(id: "second", type: "movie", name: "Second")
        let coordinator = LibraryMutationCoordinator()
        let remote = BlockingRemoteRecorder()
        let delayedToggle = Task {
            try await coordinator.toggle(
                firstItem,
                store: original,
                remoteMutation: { removed in
                    try await remote.push(removed: removed)
                }
            )
        }
        await remote.waitForFirstPush()

        let reactivated = registry.store(for: storeURL.standardizedFileURL) {
            LibraryStore(fileURL: storeURL)
        }
        XCTAssertTrue(original === reactivated)
        let preloadedItems = try await reactivated.items()
        XCTAssertEqual(preloadedItems, [])

        await remote.releaseFirstPush()
        _ = try await delayedToggle.value
        _ = try await reactivated.toggle(secondItem)

        let identifiers = try await LibraryStore(fileURL: storeURL).items().map(\.id)
        XCTAssertEqual(Set(identifiers), Set(["first", "second"]))
    }

    func testBlockedFirstPushKeepsAddThenRemoveIntentOrdered() async throws {
        try await assertDoubleToggle(
            initiallyPresent: false,
            expectedRemovedFlags: [false, true],
            expectedFinalCount: 0
        )
    }

    func testBlockedFirstPushKeepsRemoveThenAddIntentOrdered() async throws {
        try await assertDoubleToggle(
            initiallyPresent: true,
            expectedRemovedFlags: [true, false],
            expectedFinalCount: 1
        )
    }

    private func assertDoubleToggle(
        initiallyPresent: Bool,
        expectedRemovedFlags: [Bool],
        expectedFinalCount: Int
    ) async throws {
        let item = MetaItem(id: "tt-gate", type: "movie", name: "Gate")
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("library.json")
        let store = LibraryStore(fileURL: storeURL)
        if initiallyPresent {
            _ = try await store.toggle(item)
        }
        let coordinator = LibraryMutationCoordinator()
        let remote = BlockingRemoteRecorder()

        let first = Task {
            try await coordinator.toggle(
                item,
                store: store,
                remoteMutation: { removed in
                    try await remote.push(removed: removed)
                }
            )
        }
        await remote.waitForFirstPush()
        let second = Task {
            try await coordinator.toggle(
                item,
                store: store,
                remoteMutation: { removed in
                    try await remote.push(removed: removed)
                }
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        let flagsWhileBlocked = await remote.flags()
        let countWhileBlocked = try await store.items().count
        XCTAssertEqual(flagsWhileBlocked, [])
        XCTAssertEqual(countWhileBlocked, initiallyPresent ? 1 : 0)
        await remote.releaseFirstPush()
        _ = try await (first.value, second.value)

        let finalFlags = await remote.flags()
        let finalCount = try await store.items().count
        let reloadedCount = try await LibraryStore(fileURL: storeURL).items().count
        XCTAssertEqual(finalFlags, expectedRemovedFlags)
        XCTAssertEqual(finalCount, expectedFinalCount)
        XCTAssertEqual(reloadedCount, expectedFinalCount)
    }

    func testFailedRemoteMutationLeavesLocalStateRetryable() async throws {
        let item = MetaItem(id: "tt-retry", type: "movie", name: "Retry")
        let store = LibraryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("library.json"))
        let coordinator = LibraryMutationCoordinator()
        let remote = FailOnceRemoteRecorder()

        do {
            _ = try await coordinator.toggle(
                item,
                store: store,
                remoteMutation: { removed in
                    try await remote.push(removed: removed)
                }
            )
            XCTFail("Expected the first remote mutation to fail")
        } catch {
            let afterFailure = try await store.items()
            XCTAssertEqual(afterFailure, [])
        }

        let retried = try await coordinator.toggle(
            item,
            store: store,
            remoteMutation: { removed in
                try await remote.push(removed: removed)
            }
        )
        let attempts = await remote.flags()
        XCTAssertEqual(attempts, [false, false])
        XCTAssertEqual(retried.map(\.id), [item.id])
    }
}

private final class RegistryLifetimeProbe: @unchecked Sendable {}

private actor BlockingRemoteRecorder {
    private var firstPushStarted = false
    private var firstPushWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var recorded: [Bool] = []

    func push(removed: Bool) async throws {
        if !firstPushStarted {
            firstPushStarted = true
            firstPushWaiters.forEach { $0.resume() }
            firstPushWaiters.removeAll()
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        recorded.append(removed)
    }

    func waitForFirstPush() async {
        if firstPushStarted { return }
        await withCheckedContinuation { continuation in
            firstPushWaiters.append(continuation)
        }
    }

    func releaseFirstPush() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func flags() -> [Bool] { recorded }
}

private actor FailOnceRemoteRecorder {
    private var recorded: [Bool] = []

    func push(removed: Bool) throws {
        recorded.append(removed)
        if recorded.count == 1 {
            throw URLError(.networkConnectionLost)
        }
    }

    func flags() -> [Bool] { recorded }
}
