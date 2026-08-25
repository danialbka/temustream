import Foundation
import XCTest
@testable import StremioSkeletonCore

final class WatchTogetherPreferencesTests: XCTestCase {
    func testWatchTogetherDefaultsToDisabled() throws {
        let suiteName = "WatchTogetherPreferencesTests.default.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(WatchTogetherPreferences.isEnabled(in: defaults))
    }

    func testExplicitPreferenceCanEnableAndDisableWatchTogether() throws {
        let suiteName = "WatchTogetherPreferencesTests.persisted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: WatchTogetherPreferences.enabledKey)
        XCTAssertTrue(WatchTogetherPreferences.isEnabled(in: defaults))

        defaults.set(false, forKey: WatchTogetherPreferences.enabledKey)
        XCTAssertFalse(WatchTogetherPreferences.isEnabled(in: defaults))
    }
}
