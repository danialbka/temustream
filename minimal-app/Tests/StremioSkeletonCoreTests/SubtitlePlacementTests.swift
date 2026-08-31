import XCTest
@testable import StremioSkeletonCore

final class SubtitlePlacementTests: XCTestCase {
    func testSubtitleStyleDefaultsMatchCurrentPlayerPresentation() {
        XCTAssertEqual(SubtitleStyle.default.size, .medium)
        XCTAssertEqual(SubtitleStyle.default.color, .white)
        XCTAssertEqual(SubtitleStyle.default.weight, .semibold)
        XCTAssertEqual(SubtitleStyle.default.backgroundOpacity, 0.72, accuracy: 0.001)
        XCTAssertTrue(SubtitleStyle.default.shadowEnabled)
    }

    func testSubtitleStyleFallsBackAndClampsInvalidPersistedValues() {
        let style = SubtitleStyle(
            sizeRawValue: "enormous",
            colorRawValue: "invisible",
            weightRawValue: "heavy",
            backgroundOpacity: 4,
            shadowEnabled: false
        )

        XCTAssertEqual(style.size, .medium)
        XCTAssertEqual(style.color, .white)
        XCTAssertEqual(style.weight, .semibold)
        XCTAssertEqual(style.backgroundOpacity, 0.9, accuracy: 0.001)
        XCTAssertFalse(style.shadowEnabled)
    }

    func testSubtitleStyleClampsExtremeAndNonfinitePersistedOpacity() throws {
        let suiteName = "SubtitleStyleExtremeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(1e300, forKey: SubtitleStylePreferences.backgroundOpacityKey)
        XCTAssertEqual(
            SubtitleStylePreferences.current(defaults: defaults).backgroundOpacity,
            0.9,
            accuracy: 0.001
        )

        defaults.set(Double.infinity, forKey: SubtitleStylePreferences.backgroundOpacityKey)
        XCTAssertEqual(
            SubtitleStylePreferences.current(defaults: defaults).backgroundOpacity,
            SubtitleStyle.default.backgroundOpacity,
            accuracy: 0.001
        )
    }

    func testSubtitleStylePreferencesPersistAndReset() throws {
        let suiteName = "SubtitleStyleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(SubtitleSizePreset.extraLarge.rawValue, forKey: SubtitleStylePreferences.sizeKey)
        defaults.set(SubtitleColorPreset.cyan.rawValue, forKey: SubtitleStylePreferences.colorKey)
        defaults.set(SubtitleWeightPreset.bold.rawValue, forKey: SubtitleStylePreferences.weightKey)
        defaults.set(0.35, forKey: SubtitleStylePreferences.backgroundOpacityKey)
        defaults.set(false, forKey: SubtitleStylePreferences.shadowEnabledKey)

        let persisted = SubtitleStylePreferences.current(defaults: defaults)
        XCTAssertEqual(persisted.size, .extraLarge)
        XCTAssertEqual(persisted.color, .cyan)
        XCTAssertEqual(persisted.weight, .bold)
        XCTAssertEqual(persisted.backgroundOpacity, 0.35, accuracy: 0.001)
        XCTAssertFalse(persisted.shadowEnabled)

        SubtitleStylePreferences.reset(defaults: defaults)
        XCTAssertEqual(SubtitleStylePreferences.current(defaults: defaults), .default)
    }

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
