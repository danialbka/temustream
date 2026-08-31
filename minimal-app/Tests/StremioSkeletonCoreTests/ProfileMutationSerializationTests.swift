import Foundation
import XCTest
@testable import StremioSkeletonCore

private actor ProfileMutationSuspension {
    private var activationCommitted = false
    private var activationWaiters: [CheckedContinuation<Void, Never>] = []
    private var activationRelease: CheckedContinuation<Void, Never>?
    private var metadataAttempted = false
    private var metadataAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var metadataEntered = false

    func pauseAfterActivationCommit() async {
        activationCommitted = true
        activationWaiters.forEach { $0.resume() }
        activationWaiters.removeAll()
        await withCheckedContinuation { continuation in
            activationRelease = continuation
        }
    }

    func waitUntilActivationCommitted() async {
        if activationCommitted { return }
        await withCheckedContinuation { continuation in
            activationWaiters.append(continuation)
        }
    }

    func releaseActivationPublication() {
        activationRelease?.resume()
        activationRelease = nil
    }

    func markMetadataAttempted() {
        metadataAttempted = true
        metadataAttemptWaiters.forEach { $0.resume() }
        metadataAttemptWaiters.removeAll()
    }

    func waitUntilMetadataAttempted() async {
        if metadataAttempted { return }
        await withCheckedContinuation { continuation in
            metadataAttemptWaiters.append(continuation)
        }
    }

    func markMetadataEntered() {
        metadataEntered = true
    }

    func didMetadataEnter() -> Bool {
        metadataEntered
    }
}

private actor PublishedProfileState {
    private var snapshot: ViewingProfileSnapshot
    private var activeStoreProfileID: UUID

    init(snapshot: ViewingProfileSnapshot) {
        self.snapshot = snapshot
        activeStoreProfileID = snapshot.activeProfileID
    }

    func publishActivation(
        snapshot: ViewingProfileSnapshot,
        activeStoreProfileID: UUID
    ) {
        self.snapshot = snapshot
        self.activeStoreProfileID = activeStoreProfileID
    }

    func publishMetadata(_ snapshot: ViewingProfileSnapshot) {
        self.snapshot = snapshot
    }

    func value() -> (snapshot: ViewingProfileSnapshot, activeStoreProfileID: UUID) {
        (snapshot, activeStoreProfileID)
    }
}

private actor StartupAuthSuspension {
    private var startupPrepared = false
    private var startupWaiters: [CheckedContinuation<Void, Never>] = []
    private var startupRelease: CheckedContinuation<Void, Never>?
    private var signOutAttempted = false
    private var signOutWaiters: [CheckedContinuation<Void, Never>] = []
    private var signOutEntered = false

    func pauseAfterStartupPreparation() async {
        startupPrepared = true
        startupWaiters.forEach { $0.resume() }
        startupWaiters.removeAll()
        await withCheckedContinuation { continuation in
            startupRelease = continuation
        }
    }

    func waitUntilStartupPrepared() async {
        if startupPrepared { return }
        await withCheckedContinuation { continuation in
            startupWaiters.append(continuation)
        }
    }

    func releaseStartupPublication() {
        startupRelease?.resume()
        startupRelease = nil
    }

    func markSignOutAttempted() {
        signOutAttempted = true
        signOutWaiters.forEach { $0.resume() }
        signOutWaiters.removeAll()
    }

    func waitUntilSignOutAttempted() async {
        if signOutAttempted { return }
        await withCheckedContinuation { continuation in
            signOutWaiters.append(continuation)
        }
    }

    func markSignOutEntered() {
        signOutEntered = true
    }

    func didSignOutEnter() -> Bool {
        signOutEntered
    }
}

private actor PublishedAuthProfileState {
    private var session: StremioSession?
    private var storageScope: String?

    func publish(session: StremioSession?, storageScope: String) {
        self.session = session
        self.storageScope = storageScope
    }

    func value() -> (session: StremioSession?, storageScope: String?) {
        (session, storageScope)
    }
}

private actor CatalogLoadSuspension {
    private var waiting = false
    private var waitingContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseBeforePublication() async {
        waiting = true
        waitingContinuations.forEach { $0.resume() }
        waitingContinuations.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPublicationIsSuspended() async {
        if waiting { return }
        await withCheckedContinuation { continuation in
            waitingContinuations.append(continuation)
        }
    }

    func releasePublication() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

/// Production-shaped mirror of AppModel's synchronous profile/catalog
/// ownership boundary. Network work captures a revision before suspension;
/// profile publication invalidates that revision and clears all visible state
/// before exposing the replacement profile.
private actor PublishedProfileCatalogState {
    private var revision = 0
    private var profileID: UUID
    private var catalog: [String]
    private var shelves: [String]
    private var pagingIsActive: Bool
    private var searchIsActive: Bool
    private var errorMessage: String?

    init(profileID: UUID, catalog: [String]) {
        self.profileID = profileID
        self.catalog = catalog
        shelves = catalog
        pagingIsActive = true
        searchIsActive = true
        errorMessage = nil
    }

    func beginLoad() -> Int {
        revision += 1
        return revision
    }

    func publishProfile(_ profileID: UUID) {
        revision += 1
        catalog = []
        shelves = []
        pagingIsActive = false
        searchIsActive = false
        errorMessage = nil
        self.profileID = profileID
    }

    @discardableResult
    func publishCatalog(_ catalog: [String], revision capturedRevision: Int) -> Bool {
        guard capturedRevision == revision else { return false }
        self.catalog = catalog
        shelves = catalog
        pagingIsActive = true
        return true
    }

    @discardableResult
    func publishError(_ message: String, revision capturedRevision: Int) -> Bool {
        guard capturedRevision == revision else { return false }
        errorMessage = message
        return true
    }

    func value() -> (
        profileID: UUID,
        catalog: [String],
        shelves: [String],
        pagingIsActive: Bool,
        searchIsActive: Bool,
        errorMessage: String?
    ) {
        (
            profileID,
            catalog,
            shelves,
            pagingIsActive,
            searchIsActive,
            errorMessage
        )
    }
}

final class ProfileMutationSerializationTests: XCTestCase {
    func testMetadataMutationWaitsForCommittedActivationPublication() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ViewingProfileStore(rootDirectory: directory)
        let first = try await store.bootstrap(
            now: Date(timeIntervalSince1970: 1_000)
        )
        let withSecond = try await store.create(
            name: "Second",
            avatar: .moon,
            now: Date(timeIntervalSince1970: 2_000)
        )
        let secondID = try XCTUnwrap(
            withSecond.profiles.first { $0.id != first.activeProfileID }?.id
        )
        let gate = AsyncSerialGate()
        let suspension = ProfileMutationSuspension()
        let published = PublishedProfileState(snapshot: withSecond)

        let activation = Task {
            try await withProfileMutationGate(gate) {
                let plan = try await store.prepareActivation(
                    id: secondID,
                    now: Date(timeIntervalSince1970: 3_000)
                )
                let committed = try await store.commit(plan)
                await suspension.pauseAfterActivationCommit()
                await published.publishActivation(
                    snapshot: committed.snapshot,
                    activeStoreProfileID: secondID
                )
            }
        }
        await suspension.waitUntilActivationCommitted()

        let metadataUpdate = Task {
            await suspension.markMetadataAttempted()
            try await withProfileMutationGate(gate) {
                await suspension.markMetadataEntered()
                let committed = try await store.updateWithCommit(
                    id: secondID,
                    name: "Renamed Second",
                    avatar: .star,
                    now: Date(timeIntervalSince1970: 4_000)
                )
                await published.publishMetadata(committed.snapshot)
            }
        }
        await suspension.waitUntilMetadataAttempted()
        await Task.yield()
        let metadataEnteredBeforeActivationPublished = await suspension
            .didMetadataEnter()
        XCTAssertFalse(
            metadataEnteredBeforeActivationPublished,
            "Metadata publication must not overtake a committed activation whose profile stores are not published yet."
        )

        await suspension.releaseActivationPublication()
        try await activation.value
        try await metadataUpdate.value

        let final = await published.value()
        XCTAssertEqual(final.snapshot.activeProfileID, secondID)
        XCTAssertEqual(final.activeStoreProfileID, secondID)
        XCTAssertEqual(final.snapshot.activeProfile?.name, "Renamed Second")
        XCTAssertEqual(final.snapshot.activeProfile?.avatar, .star)
    }

    func testSignOutWaitsForStartupProfileAndAccountScopePublication() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ViewingProfileStore(rootDirectory: directory)
        let gate = AsyncSerialGate()
        let suspension = StartupAuthSuspension()
        let published = PublishedAuthProfileState()
        let accountSession = StremioSession(
            authKey: "startup-account-token",
            user: StremioUser(
                id: "startup-account",
                email: "startup@example.test"
            )
        )

        let startup = Task {
            try await withProfileMutationGate(gate) {
                let snapshot = try await store.bootstrap(
                    now: Date(timeIntervalSince1970: 1_000)
                )
                let capturedScope = AccountStorageScope.storageScope(
                    profileID: snapshot.activeProfileID,
                    session: accountSession
                )
                await suspension.pauseAfterStartupPreparation()
                await published.publish(
                    session: accountSession,
                    storageScope: capturedScope
                )
            }
        }
        await suspension.waitUntilStartupPrepared()

        let signOut = Task {
            await suspension.markSignOutAttempted()
            try await withProfileMutationGate(gate) {
                await suspension.markSignOutEntered()
                let snapshot = try await store.snapshot()
                await published.publish(
                    session: nil,
                    storageScope: AccountStorageScope.storageScope(
                        profileID: snapshot.activeProfileID,
                        session: nil
                    )
                )
            }
        }
        await suspension.waitUntilSignOutAttempted()
        await Task.yield()
        let signOutEnteredBeforeStartupPublished = await suspension
            .didSignOutEnter()
        XCTAssertFalse(
            signOutEnteredBeforeStartupPublished,
            "Sign-out must not clear the session while startup still owns an account-scoped store publication."
        )

        await suspension.releaseStartupPublication()
        try await startup.value
        try await signOut.value

        let final = await published.value()
        XCTAssertNil(final.session)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(
            final.storageScope,
            AccountStorageScope.storageScope(
                profileID: snapshot.activeProfileID,
                session: nil
            )
        )
    }

    func testPreparedWatchActivationFailuresLeaveManifestOnPublishedProfile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ViewingProfileStore(rootDirectory: directory)
        let first = try await store.bootstrap(
            now: Date(timeIntervalSince1970: 1_000)
        )
        let withSecond = try await store.create(
            name: "Second",
            avatar: .moon,
            now: Date(timeIntervalSince1970: 2_000)
        )
        let secondID = try XCTUnwrap(
            withSecond.profiles.first { $0.id != first.activeProfileID }?.id
        )
        let secondDirectory = try await store.dataDirectoryURL(for: secondID)
        let secondLibrary = secondDirectory.appendingPathComponent(
            ViewingProfileDataFile.anonymousLibrary
        )
        try FileManager.default.createDirectory(
            at: secondLibrary,
            withIntermediateDirectories: true
        )

        let activationPlan = try await store.prepareActivation(id: secondID)
        await XCTAssertThrowsErrorAsync {
            _ = try await LibraryStore(fileURL: secondLibrary).items()
        }
        await store.cancel(activationPlan)
        let afterActivationFailure = try await store.snapshot()
        XCTAssertEqual(afterActivationFailure.activeProfileID, first.activeProfileID)

        try FileManager.default.removeItem(at: secondLibrary)
        _ = try await store.activate(id: secondID)
        let firstDirectory = try await store.dataDirectoryURL(
            for: first.activeProfileID
        )
        let firstLibrary = firstDirectory.appendingPathComponent(
            ViewingProfileDataFile.anonymousLibrary
        )
        try FileManager.default.createDirectory(
            at: firstLibrary,
            withIntermediateDirectories: true
        )

        let archivePlan = try await store.prepareArchive(id: secondID)
        XCTAssertEqual(archivePlan.snapshot.activeProfileID, first.activeProfileID)
        await XCTAssertThrowsErrorAsync {
            _ = try await LibraryStore(fileURL: firstLibrary).items()
        }
        await store.cancel(archivePlan)
        let afterArchiveFailure = try await store.snapshot()
        XCTAssertEqual(afterArchiveFailure.activeProfileID, secondID)
        XCTAssertTrue(afterArchiveFailure.profiles.contains { $0.id == secondID })
        XCTAssertFalse(
            afterArchiveFailure.archivedProfiles.contains { $0.id == secondID }
        )
    }

    func testProfilePublicationInvalidatesSuspendedCatalogAndPagingOwnership() async {
        let firstProfileID = UUID()
        let secondProfileID = UUID()
        let state = PublishedProfileCatalogState(
            profileID: firstProfileID,
            catalog: ["profile-a-title"]
        )
        let suspension = CatalogLoadSuspension()
        let staleRevision = await state.beginLoad()

        let staleLoad = Task {
            await suspension.pauseBeforePublication()
            return await state.publishCatalog(
                ["stale-profile-a-result"],
                revision: staleRevision
            )
        }
        await suspension.waitUntilPublicationIsSuspended()

        // Profile B becomes visible, then its replacement network load fails.
        // The suspended A request must not fill that failure with A's data.
        await state.publishProfile(secondProfileID)
        await suspension.releasePublication()
        let stalePublished = await staleLoad.value
        XCTAssertFalse(stalePublished)

        let afterFailedReplacement = await state.value()
        XCTAssertEqual(afterFailedReplacement.profileID, secondProfileID)
        XCTAssertEqual(afterFailedReplacement.catalog, [])
        XCTAssertEqual(afterFailedReplacement.shelves, [])
        XCTAssertFalse(afterFailedReplacement.pagingIsActive)
        XCTAssertFalse(afterFailedReplacement.searchIsActive)

        // A request started under the replacement profile remains publishable.
        let currentRevision = await state.beginLoad()
        let currentPublished = await state.publishCatalog(
            ["profile-b-result"],
            revision: currentRevision
        )
        XCTAssertTrue(currentPublished)
        let final = await state.value()
        XCTAssertEqual(final.profileID, secondProfileID)
        XCTAssertEqual(final.catalog, ["profile-b-result"])

        let staleErrorSuspension = CatalogLoadSuspension()
        let staleErrorRevision = await state.beginLoad()
        let staleError = Task {
            await staleErrorSuspension.pauseBeforePublication()
            return await state.publishError(
                "profile-a-network-error",
                revision: staleErrorRevision
            )
        }
        await staleErrorSuspension.waitUntilPublicationIsSuspended()
        await state.publishProfile(secondProfileID)
        await staleErrorSuspension.releasePublication()
        let staleErrorPublished = await staleError.value
        let afterStaleError = await state.value()
        XCTAssertFalse(staleErrorPublished)
        XCTAssertNil(afterStaleError.errorMessage)

        let currentErrorRevision = await state.beginLoad()
        let currentErrorPublished = await state.publishError(
            "profile-b-network-error",
            revision: currentErrorRevision
        )
        let afterCurrentError = await state.value()
        XCTAssertTrue(currentErrorPublished)
        XCTAssertEqual(
            afterCurrentError.errorMessage,
            "profile-b-network-error"
        )
    }
}

private func withProfileMutationGate<Value>(
    _ gate: AsyncSerialGate,
    operation: () async throws -> Value
) async throws -> Value {
    await gate.enter()
    do {
        let value = try await operation()
        await gate.leave()
        return value
    } catch {
        await gate.leave()
        throw error
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
