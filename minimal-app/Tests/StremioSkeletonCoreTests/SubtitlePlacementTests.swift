import XCTest
@testable import StremioSkeletonCore

final class SubtitlePlacementTests: XCTestCase {
    func testDefaultPositionStartsLowAndCentered() {
        XCTAssertEqual(SubtitlePlacement.defaultPosition.horizontal, 0.5)
        XCTAssertEqual(SubtitlePlacement.defaultPosition.vertical, 0.89)
    }

    func testTranslationUsesViewportIndependentCoordinates() {
        let moved = SubtitlePlacement.defaultPosition.translated(
            x: 100,
            y: -200,
            viewportWidth: 1_000,
            viewportHeight: 1_000
        )

        XCTAssertEqual(moved.horizontal, 0.6, accuracy: 0.001)
        XCTAssertEqual(moved.vertical, 0.69, accuracy: 0.001)
    }

    func testTranslationClampsSubtitleInsideVisiblePlayerBounds() {
        let moved = SubtitlePlacement.defaultPosition.translated(
            x: -10_000,
            y: 10_000,
            viewportWidth: 390,
            viewportHeight: 844
        )

        XCTAssertEqual(moved.horizontal, 0.06, accuracy: 0.001)
        XCTAssertEqual(moved.vertical, 0.92, accuracy: 0.001)
    }

    func testContentAwareConstraintKeepsLongSubtitleFullyVisible() {
        let constrained = SubtitlePlacement(horizontal: 0.06, vertical: 0.5)
            .constrained(
                contentWidth: 210,
                contentHeight: 36,
                viewportWidth: 390,
                viewportHeight: 844
            )

        XCTAssertEqual(constrained.horizontal, 117 / 390, accuracy: 0.001)
        XCTAssertEqual(constrained.vertical, 0.5, accuracy: 0.001)
    }
}
