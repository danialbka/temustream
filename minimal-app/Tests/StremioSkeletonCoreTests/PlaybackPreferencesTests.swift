import XCTest
@testable import StremioSkeletonCore

final class PlaybackPreferencesTests: XCTestCase {
    func testEnglishMatcherUnderstandsCodesAndLabels() {
        let options = [
            PlaybackLanguageOption(languageTag: "jpn", displayName: "Japanese"),
            PlaybackLanguageOption(languageTag: "eng", displayName: "Main audio"),
            PlaybackLanguageOption(languageTag: nil, displayName: "English SDH"),
        ]

        XCTAssertEqual(
            PlaybackLanguageMatcher.bestMatchIndex(
                in: options,
                preferredLanguage: "en-US"
            ),
            1
        )
        XCTAssertEqual(
            PlaybackLanguageMatcher.bestMatchIndex(
                in: Array(options.dropFirst(2)),
                preferredLanguage: "English"
            ),
            0
        )
    }

    func testLanguagePreferencesDefaultToEnabledEnglishAndPersistSelections() throws {
        let suiteName = "PlaybackPreferencesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            PlaybackLanguagePreferences.preferredAudioLanguage(defaults: defaults),
            "en"
        )
        XCTAssertEqual(
            PlaybackLanguagePreferences.preferredSubtitleLanguage(defaults: defaults),
            "en"
        )
        XCTAssertTrue(PlaybackLanguagePreferences.subtitlesEnabled(defaults: defaults))

        PlaybackLanguagePreferences.rememberAudioSelection(
            languageTag: "jpn",
            displayName: "Japanese",
            defaults: defaults
        )
        PlaybackLanguagePreferences.rememberSubtitleSelection(
            languageTag: nil,
            displayName: "English CC",
            defaults: defaults
        )
        XCTAssertEqual(
            PlaybackLanguagePreferences.preferredAudioLanguage(defaults: defaults),
            "ja"
        )
        XCTAssertEqual(
            PlaybackLanguagePreferences.preferredSubtitleLanguage(defaults: defaults),
            "en"
        )
        XCTAssertTrue(PlaybackLanguagePreferences.subtitlesEnabled(defaults: defaults))

        PlaybackLanguagePreferences.rememberSubtitlesDisabled(defaults: defaults)
        XCTAssertFalse(PlaybackLanguagePreferences.subtitlesEnabled(defaults: defaults))
    }

    func testFailoverPolicyCountsDownAndStopsAtLastSource() {
        XCTAssertEqual(StreamFailoverPolicy.countdownValues, [3, 2, 1])
        XCTAssertEqual(
            StreamFailoverPolicy.nextSourceIndex(after: 0, sourceCount: 3),
            1
        )
        XCTAssertEqual(
            StreamFailoverPolicy.nextSourceIndex(after: 1, sourceCount: 3),
            2
        )
        XCTAssertNil(StreamFailoverPolicy.nextSourceIndex(after: 2, sourceCount: 3))
        XCTAssertNil(StreamFailoverPolicy.nextSourceIndex(after: -1, sourceCount: 3))
    }

    func testVLCRoutesAppleNativeStreamsToHardwareFastPath() throws {
        XCTAssertEqual(
            VLCPlaybackRouting.backend(
                for: try XCTUnwrap(URL(string: "https://media.example/movie/master.m3u8"))
            ),
            .nativeHardware
        )
        XCTAssertEqual(
            VLCPlaybackRouting.backend(
                for: try XCTUnwrap(URL(string: "https://media.example/signed/playback")),
                detectedMIMEType: "video/mp4; charset=binary"
            ),
            .nativeHardware
        )
        XCTAssertEqual(
            VLCPlaybackRouting.backend(
                for: try XCTUnwrap(URL(string: "https://media.example/movie.mkv")),
                detectedMIMEType: "video/x-matroska"
            ),
            .compatibility
        )
        XCTAssertEqual(
            VLCPlaybackRouting.backend(
                for: try XCTUnwrap(URL(string: "https://media.example/movie.webm"))
            ),
            .compatibility
        )
        XCTAssertEqual(
            VLCPlaybackRouting.backend(
                for: try XCTUnwrap(
                    URL(string: "https://addon.debridio.com/signed/movie.mp4")
                ),
                detectedMIMEType: "video/mp4"
            ),
            .compatibility
        )
    }
}
