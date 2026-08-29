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

    func testRemoteCustomPlaybackDoesNotExpireAtOldTwentySecondOpeningLimit() {
        XCTAssertNil(
            CustomPlaybackStartupPolicy.expiredTimeout(
                attemptElapsed: 20,
                openElapsed: nil,
                isRemote: true,
                isUltraHD: false
            )
        )
        XCTAssertEqual(
            CustomPlaybackStartupPolicy.expiredTimeout(
                attemptElapsed: 60,
                openElapsed: nil,
                isRemote: true,
                isUltraHD: false
            ),
            CustomPlaybackStartupTimeout(phase: .opening, limit: 60)
        )
    }

    func testRemoteCustomPlaybackGetsFreshFirstFrameBudgetAfterOpening() {
        XCTAssertNil(
            CustomPlaybackStartupPolicy.expiredTimeout(
                attemptElapsed: 79,
                openElapsed: 19,
                isRemote: true,
                isUltraHD: false
            )
        )
        XCTAssertEqual(
            CustomPlaybackStartupPolicy.expiredTimeout(
                attemptElapsed: 80,
                openElapsed: 20,
                isRemote: true,
                isUltraHD: false
            ),
            CustomPlaybackStartupTimeout(phase: .firstFrame, limit: 20)
        )
    }

    func testRemoteUltraHDPlaybackGetsExtendedFirstFrameBudget() {
        XCTAssertNil(
            CustomPlaybackStartupPolicy.expiredTimeout(
                attemptElapsed: 94,
                openElapsed: 34.9,
                isRemote: true,
                isUltraHD: true
            )
        )
        XCTAssertEqual(
            CustomPlaybackStartupPolicy.expiredTimeout(
                attemptElapsed: 95,
                openElapsed: 35,
                isRemote: true,
                isUltraHD: true
            ),
            CustomPlaybackStartupTimeout(phase: .firstFrame, limit: 35)
        )
    }

    func testLocalCustomPlaybackKeepsOriginalBoundedAttempt() {
        XCTAssertNil(
            CustomPlaybackStartupPolicy.expiredTimeout(
                attemptElapsed: 19.9,
                openElapsed: 10,
                isRemote: false,
                isUltraHD: true
            )
        )
        XCTAssertEqual(
            CustomPlaybackStartupPolicy.expiredTimeout(
                attemptElapsed: 20,
                openElapsed: 10,
                isRemote: false,
                isUltraHD: true
            ),
            CustomPlaybackStartupTimeout(phase: .firstFrame, limit: 20)
        )
    }

}
