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

    func testPreparedActivationDoesNotPersistUntilCommitted() async throws {
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

        let plan = try await store.prepareActivation(id: guestID, now: date(3))
        let beforeCommit = try await ViewingProfileStore(
            rootDirectory: directory
        ).snapshot()

        XCTAssertEqual(plan.snapshot.activeProfileID, guestID)
        XCTAssertEqual(beforeCommit.activeProfileID, initial.activeProfileID)

        _ = try await store.commit(plan)
        let afterCommit = try await ViewingProfileStore(
            rootDirectory: directory
        ).snapshot()
        XCTAssertEqual(afterCommit.activeProfileID, guestID)
    }

    func testPreparedCreateAndActivateIsInvisibleUntilCommitted() async throws {
        let directory = temporaryDirectory()
        let store = ViewingProfileStore(rootDirectory: directory)
        let initial = try await store.bootstrap(now: date(1))

        let plan = try await store.prepareCreateAndActivate(
            name: "Guest",
            avatar: .moon,
            now: date(2)
        )
        let beforeCommit = try await ViewingProfileStore(
            rootDirectory: directory
        ).snapshot()

        XCTAssertEqual(beforeCommit.profiles.count, 1)
        XCTAssertEqual(beforeCommit.activeProfileID, initial.activeProfileID)
        XCTAssertEqual(plan.snapshot.activeProfile?.name, "Guest")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: plan.activeProfileDataDirectoryURL.path
            )
        )

        let committed = try await store.commit(plan)
        XCTAssertEqual(committed.snapshot.profiles.count, 2)
        XCTAssertEqual(committed.snapshot.activeProfile?.name, "Guest")
    }

    func testInterveningWriteInvalidatesPreparedMutation() async throws {
        let directory = temporaryDirectory()
        let store = ViewingProfileStore(rootDirectory: directory)
        let initial = try await store.bootstrap(now: date(1))
        let plan = try await store.prepareCreateAndActivate(
            name: "Guest",
            avatar: .moon,
            now: date(2)
        )

        _ = try await store.update(
            id: initial.activeProfileID,
            name: "Owner",
            avatar: .bunny,
            now: date(3)
        )

        do {
            _ = try await store.commit(plan)
            XCTFail("Expected the stale mutation guard")
        } catch {
            XCTAssertEqual(
                error as? ViewingProfileStoreError,
                .staleMutationPlan
            )
        }
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

    func testRestoreRejectsReusedActiveNameWithoutChangingArchiveOrData() async throws {
        let store = ViewingProfileStore(rootDirectory: temporaryDirectory())
        _ = try await store.bootstrap(defaultName: "Owner", now: date(1))
        let first = try await store.create(
            name: "Kids",
            avatar: .moon,
            now: date(2)
        )
        let archivedID = try XCTUnwrap(
            first.profiles.first(where: { $0.name == "Kids" })?.id
        )
        let directory = try await store.dataDirectoryURL(for: archivedID)
        let retainedData = directory.appendingPathComponent("sentinel.txt")
        try Data("keep archived data".utf8).write(to: retainedData)
        _ = try await store.archive(id: archivedID, now: date(3))
        _ = try await store.create(name: "kids", avatar: .star, now: date(4))

        do {
            _ = try await store.restore(id: archivedID, now: date(5))
            XCTFail("Expected restore to preserve active-name uniqueness")
        } catch {
            XCTAssertEqual(error as? ViewingProfileStoreError, .duplicateName)
        }

        let reloaded = try await store.bootstrap(now: date(6))
        XCTAssertEqual(
            reloaded.profiles.filter {
                $0.name.caseInsensitiveCompare("Kids") == .orderedSame
            }.count,
            1
        )
        XCTAssertEqual(reloaded.archivedProfiles.map(\.id), [archivedID])
        XCTAssertEqual(
            try Data(contentsOf: retainedData),
            Data("keep archived data".utf8)
        )
    }

    func testUpgradeRearchivesOlderDuplicateNameAndPreservesBothProfileDirectories() async throws {
        let directory = temporaryDirectory()
        let manifestURL = directory.appendingPathComponent("viewing-profiles.json")
        let ownerID = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")
        )
        let olderKidsID = try XCTUnwrap(
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")
        )
        let newerKidsID = try XCTUnwrap(
            UUID(uuidString: "33333333-3333-3333-3333-333333333333")
        )
        let preFixManifest = """
        {
          "activeProfileID" : "\(ownerID.uuidString)",
          "legacyMigrationVersion" : 1,
          "primaryProfileID" : "\(ownerID.uuidString)",
          "profiles" : [
            {
              "avatar" : "bunny",
              "createdAt" : "1970-01-01T00:00:01Z",
              "id" : "\(ownerID.uuidString)",
              "name" : "Owner",
              "updatedAt" : "1970-01-01T00:00:01Z"
            },
            {
              "avatar" : "moon",
              "createdAt" : "1970-01-01T00:00:02Z",
              "id" : "\(olderKidsID.uuidString)",
              "name" : " Kids ",
              "updatedAt" : "1970-01-01T00:00:05Z"
            },
            {
              "avatar" : "star",
              "createdAt" : "1970-01-01T00:00:04Z",
              "id" : "\(newerKidsID.uuidString)",
              "name" : "kids",
              "updatedAt" : "1970-01-01T00:00:04Z"
            }
          ],
          "schemaVersion" : 1
        }
        """
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(preFixManifest.utf8).write(to: manifestURL)
        let profilesDirectory = directory.appendingPathComponent(
            ViewingProfileStore.profilesDirectoryName,
            isDirectory: true
        )
        for (id, value) in [(olderKidsID, "older data"), (newerKidsID, "newer data")] {
            let profileDirectory = profilesDirectory.appendingPathComponent(
                id.uuidString.lowercased(),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: profileDirectory,
                withIntermediateDirectories: true
            )
            try Data(value.utf8).write(
                to: profileDirectory.appendingPathComponent("sentinel.txt")
            )
        }

        let repaired = try await ViewingProfileStore(
            rootDirectory: directory
        ).snapshot(now: date(10))
        let reloaded = try await ViewingProfileStore(
            rootDirectory: directory
        ).snapshot(now: date(11))

        XCTAssertEqual(repaired, reloaded)
        XCTAssertEqual(repaired.activeProfileID, ownerID)
        XCTAssertEqual(repaired.profiles.map(\.id).sorted { $0.uuidString < $1.uuidString }, [
            ownerID,
            newerKidsID,
        ])
        XCTAssertEqual(repaired.archivedProfiles.map(\.id), [olderKidsID])
        XCTAssertEqual(repaired.archivedProfiles.first?.archivedAt, date(10))
        XCTAssertEqual(
            try Data(contentsOf: profilesDirectory
                .appendingPathComponent(olderKidsID.uuidString.lowercased())
                .appendingPathComponent("sentinel.txt")),
            Data("older data".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: profilesDirectory
                .appendingPathComponent(newerKidsID.uuidString.lowercased())
                .appendingPathComponent("sentinel.txt")),
            Data("newer data".utf8)
        )
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("viewing-profiles.corrupt-") }
        XCTAssertTrue(recoveryFiles.isEmpty)
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

    func testDataDirectoryFailureDoesNotMisclassifyValidManifestAsCorrupt() async throws {
        let directory = temporaryDirectory()
        let original = try await ViewingProfileStore(
            rootDirectory: directory
        ).bootstrap(defaultName: "Original", now: date(1))
        let manifestURL = directory.appendingPathComponent("viewing-profiles.json")
        let originalManifest = try Data(contentsOf: manifestURL)
        let profilePath = directory
            .appendingPathComponent("viewing-profiles", isDirectory: true)
            .appendingPathComponent(original.activeProfileID.uuidString.lowercased())

        try FileManager.default.removeItem(at: profilePath)
        try Data("directory obstruction".utf8).write(to: profilePath)

        do {
            _ = try await ViewingProfileStore(rootDirectory: directory).bootstrap()
            XCTFail("Expected profile data-directory provisioning to fail")
        } catch {
            XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifest)
            let recoveryFiles = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("viewing-profiles.corrupt-") }
            XCTAssertTrue(recoveryFiles.isEmpty)
        }

        try FileManager.default.removeItem(at: profilePath)
        let reloaded = try await ViewingProfileStore(
            rootDirectory: directory
        ).bootstrap()
        XCTAssertEqual(reloaded.activeProfileID, original.activeProfileID)
        XCTAssertEqual(reloaded.activeProfile?.name, "Original")
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
