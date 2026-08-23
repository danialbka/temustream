import XCTest
@testable import StremioSkeletonCore

final class EpisodeResumeSelectionTests: XCTestCase {
    private let stream = Stream(
        url: URL(string: "https://example.test/episode.mp4"),
        externalUrl: nil,
        name: "Direct",
        title: "1080p",
        description: nil,
        infoHash: nil,
        fileIdx: nil,
        sources: nil
    )

    func testSeriesResumeChoosesMostRecentlyUpdatedEpisode() {
        let first = Video(id: "s1e1", title: "One", season: 1, episode: 1)
        let second = Video(id: "s2e1", title: "Two", season: 2, episode: 1)
        let progress = [
            identifier(for: first): makeProgress(
                episode: first,
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            identifier(for: second): makeProgress(
                episode: second,
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
        ]

        let selection = EpisodeResumeSelector.latest(
            episodes: [first, second],
            seriesID: "show",
            progressByIdentifier: progress
        )

        XCTAssertEqual(selection?.episode, second)
    }

    func testSeasonResumeIsScopedToSelectedSeason() {
        let seasonOne = Video(id: "s1e1", title: "One", season: 1, episode: 1)
        let seasonTwo = Video(id: "s2e1", title: "Two", season: 2, episode: 1)
        let progress = [
            identifier(for: seasonOne): makeProgress(
                episode: seasonOne,
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
            identifier(for: seasonTwo): makeProgress(
                episode: seasonTwo,
                updatedAt: Date(timeIntervalSince1970: 20)
            ),
        ]

        let selection = EpisodeResumeSelector.latest(
            episodes: [seasonOne, seasonTwo],
            seriesID: "show",
            season: 1,
            progressByIdentifier: progress
        )

        XCTAssertEqual(selection?.episode, seasonOne)
    }

    func testSeasonWithoutProgressHasNoResumeAction() {
        let episode = Video(id: "s1e1", season: 1, episode: 1)
        XCTAssertNil(
            EpisodeResumeSelector.latest(
                episodes: [episode],
                seriesID: "show",
                season: 1,
                progressByIdentifier: [:]
            )
        )
    }

    func testInitialSeasonPrefersSeasonOneOverSpecials() {
        XCTAssertEqual(
            EpisodeSeasonSelector.initialSeason(
                availableSeasons: [0, 2, 1],
                persistedSeason: nil
            ),
            1
        )
    }

    func testInitialSeasonUsesFirstRegularSeasonThenSpecialsFallback() {
        XCTAssertEqual(
            EpisodeSeasonSelector.initialSeason(
                availableSeasons: [4, 0, 2],
                persistedSeason: nil
            ),
            2
        )
        XCTAssertEqual(
            EpisodeSeasonSelector.initialSeason(
                availableSeasons: [0],
                persistedSeason: nil
            ),
            0
        )
        XCTAssertNil(
            EpisodeSeasonSelector.initialSeason(
                availableSeasons: [],
                persistedSeason: nil
            )
        )
    }

    func testPersistedSeasonWinsWhenAvailableAndInvalidChoiceFallsBack() {
        XCTAssertEqual(
            EpisodeSeasonSelector.initialSeason(
                availableSeasons: [0, 1, 2],
                persistedSeason: 2
            ),
            2
        )
        XCTAssertEqual(
            EpisodeSeasonSelector.initialSeason(
                availableSeasons: [0, 1, 2],
                persistedSeason: 8
            ),
            1
        )
    }

    func testSeasonSelectionPersistsPerSeriesAcrossStoreInstances() throws {
        let suiteName = "EpisodeSeasonSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        EpisodeSeasonSelectionStore(defaults: defaults).setSeason(3, for: "show-a")

        let reloaded = EpisodeSeasonSelectionStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName))
        )
        XCTAssertEqual(reloaded.season(for: "show-a"), 3)
        XCTAssertNil(reloaded.season(for: "show-b"))
    }

    func testEpisodeAutoplayAdvancesAcrossRegularSeasonsAndSkipsSpecials() {
        let special = Video(id: "special", season: 0, episode: 1)
        let first = Video(id: "s1e1", season: 1, episode: 1)
        let second = Video(id: "s1e2", season: 1, episode: 2)
        let nextSeason = Video(id: "s2e1", season: 2, episode: 1)

        XCTAssertEqual(
            EpisodeAutoplaySelector.nextEpisode(
                after: first,
                episodes: [nextSeason, special, second, first]
            ),
            second
        )
        XCTAssertEqual(
            EpisodeAutoplaySelector.nextEpisode(
                after: second,
                episodes: [nextSeason, special, second, first]
            ),
            nextSeason
        )
        XCTAssertNil(
            EpisodeAutoplaySelector.nextEpisode(
                after: nextSeason,
                episodes: [nextSeason, special, second, first]
            )
        )
    }

    func testEpisodeAutoplayKeepsSpecialsInTheirOwnSequence() {
        let first = Video(id: "special-1", season: 0, episode: 1)
        let second = Video(id: "special-2", season: 0, episode: 2)
        let regular = Video(id: "s1e1", season: 1, episode: 1)

        XCTAssertEqual(
            EpisodeAutoplaySelector.nextEpisode(
                after: first,
                episodes: [regular, second, first]
            ),
            second
        )
        XCTAssertNil(
            EpisodeAutoplaySelector.nextEpisode(
                after: second,
                episodes: [regular, second, first]
            )
        )
    }

    func testEpisodeAutoplayOnlyPresentsForFinalNearEndUpdate() {
        XCTAssertFalse(
            EpisodeAutoplayPresentationPolicy.shouldPresent(
                position: 1_798,
                duration: 1_800,
                isFinalUpdate: false
            )
        )
        XCTAssertFalse(
            EpisodeAutoplayPresentationPolicy.shouldPresent(
                position: 1_700,
                duration: 1_800,
                isFinalUpdate: true
            )
        )
        XCTAssertTrue(
            EpisodeAutoplayPresentationPolicy.shouldPresent(
                position: 1_798,
                duration: 1_800,
                isFinalUpdate: true
            )
        )
    }

    private func identifier(for episode: Video) -> String {
        EpisodePlaybackIdentity.contentIdentifier(
            seriesID: "show",
            videoID: episode.id
        )
    }

    private func makeProgress(
        episode: Video,
        updatedAt: Date
    ) -> PlaybackProgress {
        PlaybackProgress(
            contentIdentifier: identifier(for: episode),
            contentTitle: episode.title ?? episode.id,
            stream: stream,
            providerName: "Provider",
            position: 300,
            duration: 1_800,
            updatedAt: updatedAt
        )
    }
}
