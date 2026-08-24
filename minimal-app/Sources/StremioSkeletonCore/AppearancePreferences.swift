import Foundation

enum AppAppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    static let defaultMode: Self = .dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum AppAccentPreset: String, CaseIterable, Identifiable, Sendable {
    case orange
    case coral
    case pink
    case purple
    case blue
    case teal
    case green
    case custom

    static let defaultPreset: Self = .orange

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orange: "Orange"
        case .coral: "Coral"
        case .pink: "Pink"
        case .purple: "Purple"
        case .blue: "Blue"
        case .teal: "Teal"
        case .green: "Green"
        case .custom: "Custom"
        }
    }

    static var selectablePresets: [Self] {
        allCases.filter { $0 != .custom }
    }
}

struct AppThemeRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
    }

    init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6, let value = UInt64(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var hexString: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }

    var prefersDarkForeground: Bool {
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast
    }

    private func linear(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

enum AppearancePreferences {
    static let modeKey = "appearance.mode"
    static let accentPresetKey = "appearance.accentPreset"
    static let customAccentHexKey = "appearance.customAccentHex"
    static let defaultCustomAccentHex = "#FF9500"

    static func mode(defaults: UserDefaults = .standard) -> AppAppearanceMode {
        AppAppearanceMode(rawValue: defaults.string(forKey: modeKey) ?? "")
            ?? .defaultMode
    }

    static func accentPreset(defaults: UserDefaults = .standard) -> AppAccentPreset {
        AppAccentPreset(rawValue: defaults.string(forKey: accentPresetKey) ?? "")
            ?? .defaultPreset
    }

    static func customAccent(defaults: UserDefaults = .standard) -> AppThemeRGB {
        AppThemeRGB(hexString: defaults.string(forKey: customAccentHexKey) ?? "")
            ?? AppThemeRGB(hexString: defaultCustomAccentHex)!
    }

    static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: modeKey)
        defaults.removeObject(forKey: accentPresetKey)
        defaults.removeObject(forKey: customAccentHexKey)
    }
}
