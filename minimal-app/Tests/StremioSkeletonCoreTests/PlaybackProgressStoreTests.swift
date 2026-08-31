import Foundation
import XCTest
@testable import StremioSkeletonCore

final class PlaybackProgressStoreTests: XCTestCase {
    private let movieStream = Stream(
        url: URL(string: "https://example.test/movie.mp4"),
        externalUrl: nil,
        name: "Direct",
        title: "1080p",
        description: nil,
        infoHash: nil,
        fileIdx: nil,
        sources: nil
    )

    func testCorruptProgressIsPreservedAndStoreRemainsWritable() async throws {
        let url = temporaryStoreURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let corrupt = Data("not playback progress json".utf8)
        try corrupt.write(to: url)

        let store = PlaybackProgressStore(fileURL: url)
        let recoveredEmptyItems = try await store.items()
        XCTAssertEqual(recoveredEmptyItems, [])

        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("playback-progress.corrupt-") }
        XCTAssertEqual(recoveryFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: recoveryFiles[0]), corrupt)

        let recovered = progress(identifier: "movie:recovered", position: 120)
        let recoveredItems = try await store.record(recovered)
        XCTAssertEqual(
            recoveredItems.map(\.contentIdentifier),
            [recovered.contentIdentifier]
        )
        let reloadedItems = try await PlaybackProgressStore(fileURL: url).items()
        XCTAssertEqual(
            reloadedItems.map(\.contentIdentifier),
            [recovered.contentIdentifier]
        )
    }

    func testProgressPersistsAndLatestPositionReplacesPreviousValue() async throws {
        let url = temporaryStoreURL()
        let store = PlaybackProgressStore(fileURL: url)
        let first = progress(identifier: "movie:tt1", position: 120, updatedAt: Date(timeIntervalSince1970: 1))
        let latest = progress(identifier: "movie:tt1", position: 600, updatedAt: Date(timeIntervalSince1970: 2))

        _ = try await store.record(first)
        _ = try await store.record(latest)

        let reloaded = try await PlaybackProgressStore(fileURL: url).items()
        XCTAssertEqual(reloaded.map(\.contentIdentifier), [latest.contentIdentifier])
        XCTAssertEqual(reloaded.first?.position, latest.position)
        XCTAssertNil(reloaded.first?.stream.url)
        XCTAssertEqual(reloaded.first?.stream.name, latest.stream.name)
    }

    func testProgressIsKeptSeparatelyPerTitle() async throws {
        let store = PlaybackProgressStore(fileURL: temporaryStoreURL())
        _ = try await store.record(progress(identifier: "movie:tt1", position: 120))
        let items = try await store.record(progress(identifier: "movie:tt2", position: 240))

        XCTAssertEqual(Set(items.map(\.contentIdentifier)), ["movie:tt1", "movie:tt2"])
    }

    func testCompletionRemovesSavedResumePoint() async throws {
        let store = PlaybackProgressStore(fileURL: temporaryStoreURL())
        _ = try await store.record(progress(identifier: "movie:tt1", position: 600))
        let items = try await store.record(progress(identifier: "movie:tt1", position: 3_590))

        XCTAssertTrue(items.isEmpty)
    }

    func testEarlySampleDoesNotOverwriteExistingProgress() async throws {
        let store = PlaybackProgressStore(fileURL: temporaryStoreURL())
        let saved = progress(identifier: "movie:tt1", position: 600)
        _ = try await store.record(saved)
        let items = try await store.record(progress(identifier: "movie:tt1", position: 2))

        XCTAssertEqual(items.first?.contentIdentifier, saved.contentIdentifier)
        XCTAssertEqual(items.first?.position, saved.position)
        XCTAssertNil(items.first?.stream.url)
    }

    func testOlderAsynchronousSampleCannotResurrectCompletedTitle() async throws {
        let store = PlaybackProgressStore(fileURL: temporaryStoreURL())
        let older = progress(
            identifier: "movie:tt1",
            position: 600,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let completed = progress(
            identifier: "movie:tt1",
            position: 3_590,
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        _ = try await store.record(completed)
        let items = try await store.record(older)

        XCTAssertTrue(items.isEmpty)
    }

    func testContinueWatchingKeepsLatestEpisodePerSeriesAndSortsByRecency() {
        let firstEpisode = progress(
            identifier: "series:show:episode:s1e1",
            position: 300,
            updatedAt: Date(timeIntervalSince1970: 10),
            mediaMetadata: PlaybackMediaMetadata(
                mediaID: "show",
                mediaType: "series",
                mediaTitle: "Show",
                episodeID: "s1e1",
                season: 1,
                episode: 1
            )
        )
        let movie = progress(
            identifier: "movie:movie",
            position: 600,
            updatedAt: Date(timeIntervalSince1970: 20),
            mediaMetadata: PlaybackMediaMetadata(
                mediaID: "movie",
                mediaType: "movie",
                mediaTitle: "Movie"
            )
        )
        let latestEpisode = progress(
            identifier: "series:show:episode:s1e2",
            position: 900,
            updatedAt: Date(timeIntervalSince1970: 30),
            mediaMetadata: PlaybackMediaMetadata(
                mediaID: "show",
                mediaType: "series",
                mediaTitle: "Show",
                episodeID: "s1e2",
                season: 1,
                episode: 2
            )
        )

        XCTAssertEqual(
            ContinueWatchingSelector.latest(
                from: [firstEpisode, movie, latestEpisode]
            ).map(\.contentIdentifier),
            [latestEpisode.contentIdentifier, movie.contentIdentifier]
        )
    }

    func testContinueWatchingGroupsLegacyEpisodeIdentifiersWithoutMetadata() {
        let first = progress(
            identifier: "series:show:episode:show:1:1",
            position: 300,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let latest = progress(
            identifier: "series:show:episode:show:1:2",
            position: 600,
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(
            ContinueWatchingSelector.latest(from: [first, latest]),
            [latest]
        )
    }

    func testPlaybackMediaMetadataPersistsWithProgress() async throws {
        let storeURL = temporaryStoreURL()
        let store = PlaybackProgressStore(fileURL: storeURL)
        let metadata = PlaybackMediaMetadata(
            mediaID: "show",
            mediaType: "series",
            mediaTitle: "Show",
            posterURL: URL(string: "https://example.test/poster.jpg"),
            episodeID: "s1e2",
            episodeTitle: "Second Episode",
            season: 1,
            episode: 2,
            episodeThumbnailURL: URL(string: "https://example.test/episode.jpg")
        )
        _ = try await store.record(
            progress(
                identifier: "series:show:episode:s1e2",
                position: 600,
                mediaMetadata: metadata
            )
        )

        let reloaded = try await PlaybackProgressStore(fileURL: storeURL).items()
        XCTAssertEqual(reloaded.first?.mediaMetadata, metadata)
    }

    func testPersistenceOmitsSignedPlaybackURLs() async throws {
        let storeURL = temporaryStoreURL()
        let sensitiveStream = Stream(
            url: URL(string: "https://media.example.test/movie.mkv?token=fixture-private-value"),
            externalUrl: nil,
            name: "Direct",
            title: "1080p",
            description: nil,
            infoHash: nil,
            fileIdx: nil,
            sources: nil
        )
        let progress = PlaybackProgress(
            contentIdentifier: "movie:safe",
            contentTitle: "Movie",
            stream: sensitiveStream,
            position: 60,
            duration: 3_600
        )

        let recorded = try await PlaybackProgressStore(fileURL: storeURL).record(progress)

        let persisted = try String(contentsOf: storeURL, encoding: .utf8)
        XCTAssertFalse(persisted.contains("fixture-private-value"))
        XCTAssertNil(recorded.first?.stream.url)
        let reloaded = try await PlaybackProgressStore(fileURL: storeURL).items()
        XCTAssertNil(reloaded.first?.stream.url)
    }

    func testUnrepresentableTimelineValuesAreRejectedAndRemoved() async throws {
        let storeURL = temporaryStoreURL()
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let extreme = PlaybackProgress(
            contentIdentifier: "movie:extreme",
            contentTitle: "Extreme",
            stream: movieStream,
            position: 1e300,
            duration: 1.5e300
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([extreme]).write(to: storeURL)

        let loaded = try await PlaybackProgressStore(fileURL: storeURL).items()
        XCTAssertTrue(loaded.isEmpty)
        let recorded = try await PlaybackProgressStore(fileURL: storeURL).record(extreme)
        XCTAssertTrue(recorded.isEmpty)
    }

    func testPlaybackTimeFormatterRejectsUnrepresentableValueWithoutTrapping() {
        XCTAssertNil(PlaybackTimeFormatter.wholeSeconds(1e300))
        XCTAssertEqual(PlaybackTimeFormatter.clock(1e300), "0:00")
        XCTAssertEqual(
            PlaybackTimeFormatter.clock(65, zeroPadMinutes: true),
            "01:05"
        )
        XCTAssertEqual(PlaybackTimeFormatter.clock(3_665), "1:01:05")
    }

    private func progress(
        identifier: String,
        position: TimeInterval,
        updatedAt: Date = Date(),
        mediaMetadata: PlaybackMediaMetadata? = nil
    ) -> PlaybackProgress {
        PlaybackProgress(
            contentIdentifier: identifier,
            contentTitle: "Movie",
            stream: movieStream,
            providerName: "Provider",
            position: position,
            duration: 3_600,
            updatedAt: updatedAt,
            mediaMetadata: mediaMetadata
        )
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("playback-progress.json")
    }
}
