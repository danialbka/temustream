import Foundation
import XCTest
@testable import StremioSkeletonCore

final class LastSuccessfulPlaybackTests: XCTestCase {
    private struct Candidate: Equatable {
        let label: String
        let key: PlaybackStreamPreferenceKey?
    }

    func testExactStreamIsPromotedWithoutDisturbingFallbackOrder() throws {
        let identity = try XCTUnwrap(PlaybackContentIdentity.movie(catalogID: "tt123"))
        let firstKey = try XCTUnwrap(
            PlaybackStreamPreferenceKey(
                providerName: "Provider A",
                streamName: "1080p",
                streamTitle: "Movie 1080p"
            )
        )
        let preferredKey = try XCTUnwrap(
            PlaybackStreamPreferenceKey(
                providerName: "Provider B",
                streamName: "4K",
                streamTitle: "Movie 4K"
            )
        )
        let sameProviderKey = try XCTUnwrap(
            PlaybackStreamPreferenceKey(
                providerName: "Provider B",
                streamName: "720p",
                streamTitle: "Movie 720p"
            )
        )
        let candidates = [
            Candidate(label: "ranked-first", key: firstKey),
            Candidate(label: "same-provider", key: sameProviderKey),
            Candidate(label: "last-success", key: preferredKey),
        ]
        let preference = LastSuccessfulPlaybackPreference(
            identity: identity,
            key: preferredKey
        )

        XCTAssertEqual(
            LastSuccessfulPlaybackRanker.rank(
                candidates,
                identity: identity,
                preference: preference,
                key: \Candidate.key
            ).map(\.label),
            ["last-success", "same-provider", "ranked-first"]
        )
    }

    func testPreferenceNeverCrossesMovieOrEpisodeIdentity() throws {
        let movie = try XCTUnwrap(PlaybackContentIdentity.movie(catalogID: "tt123"))
        let episode = try XCTUnwrap(
            PlaybackContentIdentity.episode(seriesID: "tt123", videoID: "tt123:1:2")
        )
        let key = try XCTUnwrap(
            PlaybackStreamPreferenceKey(
                providerName: "Provider",
                streamName: "Source",
                streamTitle: nil
            )
        )
        let candidates = [
            Candidate(label: "first", key: nil),
            Candidate(label: "second", key: key),
        ]

        XCTAssertEqual(
            LastSuccessfulPlaybackRanker.rank(
                candidates,
                identity: episode,
                preference: .init(identity: movie, key: key),
                key: \Candidate.key
            ).map(\.label),
            ["first", "second"]
        )
    }

    func testStoreIsBoundedExpiresOldEntriesAndPersistsNoRawStreamSecrets() throws {
        let suite = "LastSuccessfulPlaybackTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageKey = "test.last-success"
        let store = LastSuccessfulPlaybackPreferenceStore(
            defaults: defaults,
            storageKey: storageKey,
            capacity: 2,
            maxAge: 60
        )
        let base = Date(timeIntervalSince1970: 10_000)
        let streamKey = try XCTUnwrap(
            PlaybackStreamPreferenceKey(
                providerName: "Provider",
                streamName: "English 1080p",
                streamTitle: "Feature"
            )
        )
        let first = try XCTUnwrap(PlaybackContentIdentity.movie(catalogID: "tt1"))
        let second = try XCTUnwrap(PlaybackContentIdentity.movie(catalogID: "tt2"))
        let third = try XCTUnwrap(PlaybackContentIdentity.movie(catalogID: "tt3"))
        store.recordSuccess(identity: first, key: streamKey, at: base)
        store.recordSuccess(identity: second, key: streamKey, at: base.addingTimeInterval(1))
        store.recordSuccess(identity: third, key: streamKey, at: base.addingTimeInterval(2))

        XCTAssertNil(store.preference(for: first, now: base.addingTimeInterval(2)))
        XCTAssertNotNil(store.preference(for: third, now: base.addingTimeInterval(2)))
        XCTAssertNil(store.preference(for: third, now: base.addingTimeInterval(100)))

        store.recordSuccess(identity: third, key: streamKey, at: base.addingTimeInterval(101))
        let persisted = try XCTUnwrap(defaults.data(forKey: storageKey))
        let persistedText = String(decoding: persisted, as: UTF8.self)
        XCTAssertFalse(persistedText.contains("Provider"))
        XCTAssertFalse(persistedText.contains("English 1080p"))
        XCTAssertFalse(persistedText.contains("https://"))
    }

    func testTransientMetadataIsRejectedInsteadOfRemembered() {
        XCTAssertNil(
            PlaybackStreamPreferenceKey(
                providerName: "https://provider.example?token=secret",
                streamName: "1080p",
                streamTitle: "Movie"
            )
        )
        let providerOnly = PlaybackStreamPreferenceKey(
            providerName: "Provider",
            streamName: "https://cdn.example/file?token=secret",
            streamTitle: nil
        )
        XCTAssertNotNil(providerOnly)
        XCTAssertNil(providerOnly?.streamKey)
    }
}
