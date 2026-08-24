import XCTest
@testable import StremioSkeletonCore

final class AppearancePreferencesTests: XCTestCase {
    func testDefaultsPreserveExistingDarkOrangeAppearance() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppearancePreferences.mode(defaults: defaults), .dark)
        XCTAssertEqual(AppearancePreferences.accentPreset(defaults: defaults), .orange)
        XCTAssertEqual(
            AppearancePreferences.customAccent(defaults: defaults).hexString,
            "#FF9500"
        )
    }

    func testAppearanceSelectionPersistsAndRejectsInvalidValues() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppAppearanceMode.light.rawValue, forKey: AppearancePreferences.modeKey)
        defaults.set(AppAccentPreset.custom.rawValue, forKey: AppearancePreferences.accentPresetKey)
        defaults.set("  #7c4dff  ", forKey: AppearancePreferences.customAccentHexKey)

        XCTAssertEqual(AppearancePreferences.mode(defaults: defaults), .light)
        XCTAssertEqual(AppearancePreferences.accentPreset(defaults: defaults), .custom)
        XCTAssertEqual(AppearancePreferences.customAccent(defaults: defaults).hexString, "#7C4DFF")

        defaults.set("unsupported", forKey: AppearancePreferences.modeKey)
        defaults.set("invisible", forKey: AppearancePreferences.accentPresetKey)
        defaults.set("#oops", forKey: AppearancePreferences.customAccentHexKey)
        XCTAssertEqual(AppearancePreferences.mode(defaults: defaults), .dark)
        XCTAssertEqual(AppearancePreferences.accentPreset(defaults: defaults), .orange)
        XCTAssertEqual(AppearancePreferences.customAccent(defaults: defaults).hexString, "#FF9500")
    }

    func testHexColorNormalizationAndForegroundContrast() throws {
        XCTAssertEqual(AppThemeRGB(hexString: "ffffff")?.hexString, "#FFFFFF")
        XCTAssertEqual(AppThemeRGB(hexString: "#000000")?.hexString, "#000000")
        XCTAssertNil(AppThemeRGB(hexString: "#12345"))
        XCTAssertTrue(try XCTUnwrap(AppThemeRGB(hexString: "#FF9500")).prefersDarkForeground)
        XCTAssertFalse(try XCTUnwrap(AppThemeRGB(hexString: "#251044")).prefersDarkForeground)
    }

    func testResetRestoresDefaults() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("light", forKey: AppearancePreferences.modeKey)
        defaults.set("blue", forKey: AppearancePreferences.accentPresetKey)
        defaults.set("#123456", forKey: AppearancePreferences.customAccentHexKey)

        AppearancePreferences.reset(defaults: defaults)

        XCTAssertEqual(AppearancePreferences.mode(defaults: defaults), .dark)
        XCTAssertEqual(AppearancePreferences.accentPreset(defaults: defaults), .orange)
        XCTAssertEqual(AppearancePreferences.customAccent(defaults: defaults).hexString, "#FF9500")
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "AppearancePreferencesTests-\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}
