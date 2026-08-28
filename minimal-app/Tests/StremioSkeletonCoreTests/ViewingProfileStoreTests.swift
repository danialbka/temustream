import Foundation
import XCTest
@testable import StremioSkeletonCore

final class ViewingProfileStoreTests: XCTestCase {
    func testEveryAvatarPresetRoundTripsThroughPersistence() throws {
        let encoded = try JSONEncoder().encode(ViewingProfileAvatar.allCases)
        let decoded = try JSONDecoder().decode(
            [ViewingProfileAvatar].self,
            from: encoded
        )

        XCTAssertEqual(decoded, ViewingProfileAvatar.allCases)
        XCTAssertTrue(decoded.contains(.avril))
        XCTAssertTrue(decoded.contains(.sam))
        XCTAssertTrue(decoded.contains(.lopBunny))
        XCTAssertTrue(decoded.contains(.goldenPuppy))
        XCTAssertTrue(decoded.contains(.tabbyKitten))
        XCTAssertTrue(decoded.contains(.seaOtter))
    }

    func testBootstrapCreatesStableDefaultProfile() async throws {
        let directory = temporaryDirectory()
        let first = try await ViewingProfileStore(rootDirectory: directory).bootstrap(
            defaultName: "  Primary Viewer   ",
            defaultAvatar: .bunny,
            now: date(1)
        )
        let second = try await ViewingProfileStore(rootDirectory: directory).snapshot(
            now: date(2)
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.activeProfile?.name, "Primary Viewer")
        XCTAssertEqual(first.activeProfile?.avatar, .bunny)
        XCTAssertEqual(first.activeProfileID, first.primaryProfileID)
        XCTAssertTrue(first.activeProfileAllowsAccountLibrarySync)
    }

    func testLegacyMigrationCopiesWithoutRemovingOrOverwritingSource() async throws {
        let directory = temporaryDirectory()
        let legacyURL = directory.appendingPathComponent("playback-progress.json")
        let original = Data("legacy progress".utf8)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try original.write(to: legacyURL)

        let store = ViewingProfileStore(rootDirectory: directory)
        let first = try await store.bootstrap(
            migrating: [
                ViewingProfileLegacyFile(
                    fileName: "playback-progress.json",
                    sourceURL: legacyURL
                ),
            ],
            now: date(1)
        )
        let profileDirectory = try await store.dataDirectoryURL(
            for: first.activeProfileID
        )
        let migratedURL = profileDirectory.appendingPathComponent(
            "playback-progress.json"
        )
        XCTAssertEqual(try Data(contentsOf: migratedURL), original)
        XCTAssertEqual(try Data(contentsOf: legacyURL), original)

        try Data("new legacy value".utf8).write(to: legacyURL, options: .atomic)
        _ = try await ViewingProfileStore(rootDirectory: directory).bootstrap(
            migrating: [
                ViewingProfileLegacyFile(
                    fileName: "playback-progress.json",
                    sourceURL: legacyURL
                ),
            ],
            now: date(2)
        )
        XCTAssertEqual(try Data(contentsOf: migratedURL), original)
    }

    func testProfilesHaveIsolatedStoreDirectories() async throws {
        let directory = temporaryDirectory()
        let profileStore = ViewingProfileStore(rootDirectory: directory)
        let first = try await profileStore.bootstrap(now: date(1))
        let second = try await profileStore.create(
            name: "Guest",
            avatar: .popcorn,
            now: date(2)
        )
        let firstDirectory = try await profileStore.dataDirectoryURL(
            for: first.activeProfileID
        )
        let guestID = try XCTUnwrap(
            second.profiles.first(where: { $0.name == "Guest" })?.id
        )
        let secondDirectory = try await profileStore.dataDirectoryURL(for: guestID)
        let item = MetaItem(id: "tt1", type: "movie", name: "One")

        _ = try await LibraryStore(
            fileURL: firstDirectory.appendingPathComponent("library.json")
        ).toggle(item)
        let guestItems = try await LibraryStore(
            fileURL: secondDirectory.appendingPathComponent("library.json")
        ).items()

        XCTAssertNotEqual(firstDirectory, secondDirectory)
        XCTAssertTrue(guestItems.isEmpty)
        XCTAssertTrue(second.allowsAccountLibrarySync(for: first.activeProfileID))
        XCTAssertFalse(second.allowsAccountLibrarySync(for: guestID))
    }

    func testMigrationPreservesLibraryProgressAndCompletionData() async throws {
        let directory = temporaryDirectory()
        let libraryURL = directory.appendingPathComponent("library.json")
        let progressURL = directory.appendingPathComponent("playback-progress.json")
        let completionURL = directory.appendingPathComponent("playback-completions.json")
        let item = MetaItem(id: "tt-legacy", type: "movie", name: "Legacy Movie")
        let progress = PlaybackProgress(
            contentIdentifier: "movie:tt-legacy",
            contentTitle: item.name,
            stream: Stream(
                url: URL(string: "https://example.test/movie.mp4"),
                externalUrl: nil,
                name: "Direct",
                title: "1080p",
                description: nil,
                infoHash: nil,
                fileIdx: nil,
                sources: nil
            ),
            position: 120,
            duration: 3_600,
            updatedAt: date(2),
            mediaMetadata: .movie(item)
        )
        _ = try await LibraryStore(fileURL: libraryURL).toggle(item)
        _ = try await PlaybackProgressStore(fileURL: progressURL).record(progress)
        _ = try await PlaybackCompletionStore(fileURL: completionURL).markCompleted(
            contentIdentifier: "movie:finished",
            completedAt: date(3)
        )

        let store = ViewingProfileStore(rootDirectory: directory)
        let snapshot = try await store.bootstrap(
            migrating: [
                ViewingProfileLegacyFile(fileName: "library.json", sourceURL: libraryURL),
                ViewingProfileLegacyFile(
                    fileName: "playback-progress.json",
                    sourceURL: progressURL
                ),
                ViewingProfileLegacyFile(
                    fileName: "playback-completions.json",
                    sourceURL: completionURL
                ),
            ],
            now: date(4)
        )
        let migrated = try await store.dataDirectoryURL(for: snapshot.activeProfileID)
        let migratedLibrary = try await LibraryStore(
            fileURL: migrated.appendingPathComponent("library.json")
        ).items()
        let migratedProgress = try await PlaybackProgressStore(
            fileURL: migrated.appendingPathComponent("playback-progress.json")
        ).items()
        let migratedCompletions = try await PlaybackCompletionStore(
            fileURL: migrated.appendingPathComponent("playback-completions.json")
        ).items()

        XCTAssertEqual(migratedLibrary, [item])
        XCTAssertEqual(migratedProgress.map(\.contentIdentifier), [progress.contentIdentifier])
        XCTAssertEqual(migratedProgress.first?.position, progress.position)
        XCTAssertNil(migratedProgress.first?.stream.url)
        XCTAssertEqual(migratedProgress.first?.stream.name, progress.stream.name)
        XCTAssertEqual(migratedCompletions.map(\.contentIdentifier), ["movie:finished"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: libraryURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: progressURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: completionURL.path))
    }

    func testActivationPersistsAndAccountSyncStaysWithPrimaryProfile() async throws {
        let directory = temporaryDirectory()
        let store = ViewingProfileStore(rootDirectory: directory)
        let initial = try await store.bootstrap(now: date(1))
        let created = try await store.create(
            name: "Guest",
            avatar: .star,
            now: date(2)
        )
        let guestID = try XCTUnwrap(
            created.profiles.first(where: { $0.name == "Guest" })?.id
        )
        let activated = try await store.activate(id: guestID, now: date(3))
        let reloaded = try await ViewingProfileStore(rootDirectory: directory).snapshot()

        XCTAssertEqual(activated.activeProfileID, guestID)
        XCTAssertEqual(reloaded.activeProfileID, guestID)
        XCTAssertEqual(reloaded.primaryProfileID, initial.activeProfileID)
        XCTAssertFalse(reloaded.activeProfileAllowsAccountLibrarySync)
    }

    func testArchiveIsRecoverableAndCannotArchiveLastProfile() async throws {
        let store = ViewingProfileStore(rootDirectory: temporaryDirectory())
        let initial = try await store.bootstrap(now: date(1))
        do {
            _ = try await store.archive(id: initial.activeProfileID, now: date(2))
            XCTFail("Expected the last-profile guard")
        } catch {
            XCTAssertEqual(
                error as? ViewingProfileStoreError,
                .cannotArchiveLastProfile
            )
        }

        let created = try await store.create(
            name: "Guest",
            avatar: .moon,
            now: date(3)
        )
        let guestID = try XCTUnwrap(
            created.profiles.first(where: { $0.name == "Guest" })?.id
        )
        let guestDirectory = try await store.dataDirectoryURL(for: guestID)
        let retainedData = guestDirectory.appendingPathComponent("media-ratings.json")
        try Data("keep me".utf8).write(to: retainedData)
        _ = try await store.activate(id: guestID, now: date(4))
        let archived = try await store.archive(id: guestID, now: date(5))

        XCTAssertEqual(archived.activeProfileID, initial.activeProfileID)
        XCTAssertEqual(archived.archivedProfiles.map(\.id), [guestID])

        let restored = try await store.restore(id: guestID, now: date(6))
        XCTAssertTrue(restored.archivedProfiles.isEmpty)
        XCTAssertTrue(restored.profiles.contains(where: { $0.id == guestID }))
        XCTAssertEqual(try Data(contentsOf: retainedData), Data("keep me".utf8))
    }

    func testNamesAreNormalizedAndValidated() async throws {
        let store = ViewingProfileStore(rootDirectory: temporaryDirectory())
        _ = try await store.bootstrap(defaultName: "Owner")
        let created = try await store.create(
            name: "  Movie    Night  ",
            avatar: .rocket
        )
        XCTAssertTrue(created.profiles.contains(where: { $0.name == "Movie Night" }))

        do {
            _ = try await store.create(name: "movie night", avatar: .star)
            XCTFail("Expected duplicate-name rejection")
        } catch {
            XCTAssertEqual(error as? ViewingProfileStoreError, .duplicateName)
        }
    }

    func testCorruptManifestIsPreservedBeforeFreshRecovery() async throws {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let manifestURL = directory.appendingPathComponent("viewing-profiles.json")
        let corrupt = Data("{ definitely not json".utf8)
        try corrupt.write(to: manifestURL)

        let snapshot = try await ViewingProfileStore(
            rootDirectory: directory
        ).bootstrap(defaultName: "Recovered", now: date(10))
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("viewing-profiles.corrupt-") }

        XCTAssertEqual(snapshot.activeProfile?.name, "Recovered")
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveryFiles[0]), corrupt)
    }

    func testInvalidLegacyFilenameDoesNotMarkMigrationComplete() async throws {
        let directory = temporaryDirectory()
        let source = directory.appendingPathComponent("legacy.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: source)
        let store = ViewingProfileStore(rootDirectory: directory)

        do {
            _ = try await store.bootstrap(
                migrating: [
                    ViewingProfileLegacyFile(
                        fileName: "../outside.json",
                        sourceURL: source
                    ),
                ]
            )
            XCTFail("Expected path rejection")
        } catch {
            XCTAssertEqual(
                error as? ViewingProfileStoreError,
                .invalidLegacyFileName
            )
        }

        let recovered = try await store.bootstrap(
            migrating: [
                ViewingProfileLegacyFile(
                    fileName: "legacy.json",
                    sourceURL: source
                ),
            ]
        )
        let profileDirectory = try await store.dataDirectoryURL(
            for: recovered.activeProfileID
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: profileDirectory.appendingPathComponent("legacy.json").path
            )
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func date(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }
}
