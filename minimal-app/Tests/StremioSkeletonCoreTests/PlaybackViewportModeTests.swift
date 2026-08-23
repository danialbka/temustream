import XCTest
@testable import StremioSkeletonCore

final class PlaybackViewportModeTests: XCTestCase {
    func testPinchOutFillsAndPinchInFits() {
        XCTAssertEqual(PlaybackViewportMode.fit.applying(magnification: 1.2), .fill)
        XCTAssertEqual(PlaybackViewportMode.fill.applying(magnification: 0.8), .fit)
    }

    func testSmallPinchDoesNotChangePresentation() {
        XCTAssertEqual(PlaybackViewportMode.fit.applying(magnification: 1.04), .fit)
        XCTAssertEqual(PlaybackViewportMode.fill.applying(magnification: 0.96), .fill)
    }

    func testFillScaleCoversPortraitAndLandscapeViewports() {
        XCTAssertEqual(
            PlaybackViewportMode.fill.renderScale(
                videoWidth: 1_920,
                videoHeight: 1_080,
                viewportWidth: 390,
                viewportHeight: 844
            ),
            (16.0 / 9.0) / (390.0 / 844.0),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PlaybackViewportMode.fill.renderScale(
                videoWidth: 1_080,
                videoHeight: 1_920,
                viewportWidth: 844,
                viewportHeight: 390
            ),
            (844.0 / 390.0) / (9.0 / 16.0),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PlaybackViewportMode.fit.renderScale(
                videoWidth: 1_920,
                videoHeight: 1_080,
                viewportWidth: 390,
                viewportHeight: 844
            ),
            1
        )
    }
}
