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

    func testProgressPersistsAndLatestPositionReplacesPreviousValue() async throws {
        let url = temporaryStoreURL()
        let store = PlaybackProgressStore(fileURL: url)
        let first = progress(identifier: "movie:tt1", position: 120, updatedAt: Date(timeIntervalSince1970: 1))
        let latest = progress(identifier: "movie:tt1", position: 600, updatedAt: Date(timeIntervalSince1970: 2))

        _ = try await store.record(first)
        _ = try await store.record(latest)

        let reloaded = try await PlaybackProgressStore(fileURL: url).items()
        XCTAssertEqual(reloaded, [latest])
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

        XCTAssertEqual(items, [saved])
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
