import Foundation

enum WatchTogetherPreferences {
    static let enabledKey = "watchTogetherEnabled"
    static let defaultEnabled = false

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else {
            return defaultEnabled
        }
        return defaults.bool(forKey: enabledKey)
    }
}
