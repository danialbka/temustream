import Foundation
import XCTest
@testable import StremioSkeletonCore

final class PlaybackCompletionStoreTests: XCTestCase {
    func testEpisodeIdentitySeparatesEpisodesWithinTheSameSeries() {
        let first = EpisodePlaybackIdentity.contentIdentifier(
            seriesID: "tt-series",
            videoID: "tt-series:1:1"
        )
        let second = EpisodePlaybackIdentity.contentIdentifier(
            seriesID: "tt-series",
            videoID: "tt-series:1:2"
        )

        XCTAssertEqual(first, "series:tt-series:episode:tt-series:1:1")
        XCTAssertNotEqual(first, second)
    }

    func testEpisodeTitleIncludesSeasonEpisodeAndName() {
        let video = Video(
            id: "tt-series:2:3",
            title: "The Return",
            season: 2,
            episode: 3,
            released: nil
        )

        XCTAssertEqual(
            EpisodePlaybackIdentity.contentTitle(seriesTitle: "Fixture Show", video: video),
            "Fixture Show • S2 E3 • The Return"
        )
    }

    func testCompletedEpisodesPersistIndependently() async throws {
        let url = temporaryStoreURL()
        let store = PlaybackCompletionStore(fileURL: url)
        let first = "series:tt-series:episode:tt-series:1:1"
        let second = "series:tt-series:episode:tt-series:1:2"

        _ = try await store.markCompleted(
            contentIdentifier: first,
            completedAt: Date(timeIntervalSince1970: 1)
        )
        _ = try await store.markCompleted(
            contentIdentifier: second,
            completedAt: Date(timeIntervalSince1970: 2)
        )
        _ = try await store.markCompleted(
            contentIdentifier: first,
            completedAt: Date(timeIntervalSince1970: 3)
        )

        let reloaded = try await PlaybackCompletionStore(fileURL: url).items()
        XCTAssertEqual(reloaded.map(\.contentIdentifier), [first, second])
        XCTAssertEqual(reloaded.first?.completedAt, Date(timeIntervalSince1970: 3))
    }

    func testSelectingCompletedEpisodeDoesNotClearIt() {
        XCTAssertEqual(
            EpisodePlaybackCompletionPolicy.transition(
                isCompleted: true,
                position: 0,
                duration: 1_800
            ),
            .noChange
        )
        XCTAssertEqual(
            EpisodePlaybackCompletionPolicy.transition(
                isCompleted: true,
                position: PlaybackProgress.minimumResumePosition - 0.1,
                duration: 1_800
            ),
            .noChange
        )
    }

    func testMeaningfulRewatchProgressClearsCompletedState() {
        XCTAssertEqual(
            EpisodePlaybackCompletionPolicy.transition(
                isCompleted: true,
                position: 30,
                duration: 1_800
            ),
            .markIncomplete
        )
    }

    func testOrdinaryResumeDoesNotChangeIncompleteState() {
        XCTAssertEqual(
            EpisodePlaybackCompletionPolicy.transition(
                isCompleted: false,
                position: 600,
                duration: 1_800
            ),
            .noChange
        )
    }

    func testFinishingRewatchMarksEpisodeCompletedAgain() {
        XCTAssertEqual(
            EpisodePlaybackCompletionPolicy.transition(
                isCompleted: false,
                position: 1_799,
                duration: 1_800
            ),
            .markCompleted
        )
    }

    func testRewatchCompletionStatePersistsAcrossReloads() async throws {
        let url = temporaryStoreURL()
        let identifier = "series:tt-series:episode:tt-series:1:1"
        let store = PlaybackCompletionStore(fileURL: url)

        _ = try await store.markCompleted(
            contentIdentifier: identifier,
            completedAt: Date(timeIntervalSince1970: 1)
        )
        _ = try await store.markIncomplete(
            contentIdentifier: identifier,
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let cleared = try await PlaybackCompletionStore(fileURL: url).items()
        XCTAssertTrue(cleared.isEmpty)

        _ = try await store.markCompleted(
            contentIdentifier: identifier,
            completedAt: Date(timeIntervalSince1970: 3)
        )
        let reloaded = try await PlaybackCompletionStore(fileURL: url).items()
        XCTAssertEqual(reloaded.map(\.contentIdentifier), [identifier])
    }

    func testOlderIncompleteUpdateCannotOverrideNewerCompletion() async throws {
        let url = temporaryStoreURL()
        let identifier = "series:tt-series:episode:tt-series:1:1"
        let store = PlaybackCompletionStore(fileURL: url)

        _ = try await store.markCompleted(
            contentIdentifier: identifier,
            completedAt: Date(timeIntervalSince1970: 3)
        )
        _ = try await store.markIncomplete(
            contentIdentifier: identifier,
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        let completions = try await store.items()
        XCTAssertEqual(completions.map(\.contentIdentifier), [identifier])
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("playback-completions.json")
    }
}
