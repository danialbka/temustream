import SwiftUI
import UIKit

private extension AppAppearanceMode {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension AppAccentPreset {
    var color: Color {
        switch self {
        case .orange: Color(uiColor: .systemOrange)
        case .coral: Color(red: 1, green: 0.38, blue: 0.35)
        case .pink: Color(uiColor: .systemPink)
        case .purple: Color(uiColor: .systemPurple)
        case .blue: Color(uiColor: .systemBlue)
        case .teal: Color(uiColor: .systemTeal)
        case .green: Color(uiColor: .systemGreen)
        case .custom: AppTheme.customAccentColor
        }
    }

    var referenceRGB: AppThemeRGB {
        switch self {
        case .orange: AppThemeRGB(hexString: "#FF9500")!
        case .coral: AppThemeRGB(hexString: "#FF6159")!
        case .pink: AppThemeRGB(hexString: "#FF2D55")!
        case .purple: AppThemeRGB(hexString: "#AF52DE")!
        case .blue: AppThemeRGB(hexString: "#007AFF")!
        case .teal: AppThemeRGB(hexString: "#30B0C7")!
        case .green: AppThemeRGB(hexString: "#34C759")!
        case .custom: AppearancePreferences.customAccent()
        }
    }
}

enum AppTheme {
    static var accentColor: Color {
        AppearancePreferences.accentPreset().color
    }

    static var onAccentColor: Color {
        AppearancePreferences.accentPreset().referenceRGB.prefersDarkForeground
            ? .black
            : .white
    }

    static var customAccentColor: Color {
        let rgb = AppearancePreferences.customAccent()
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

extension Color {
    static var appAccent: Color { AppTheme.accentColor }
    static var appOnAccent: Color { AppTheme.onAccentColor }

    static let appFieldBackground = Color(uiColor: .secondarySystemBackground)
    static let appCardBackground = Color(uiColor: .secondarySystemBackground)
    static let appPlaceholderBackground = Color(uiColor: .tertiarySystemFill)
    static let appHairline = Color(uiColor: .separator)
    static let appProgressTrack = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.16)
                : UIColor.black.withAlphaComponent(0.14)
        }
    )
}

struct AppThemeHost<Content: View>: View {
    @AppStorage(AppearancePreferences.modeKey)
    private var modeRawValue = AppAppearanceMode.defaultMode.rawValue
    @AppStorage(AppearancePreferences.accentPresetKey)
    private var accentPresetRawValue = AppAccentPreset.defaultPreset.rawValue
    @AppStorage(AppearancePreferences.customAccentHexKey)
    private var customAccentHex = AppearancePreferences.defaultCustomAccentHex

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let mode = AppAppearanceMode(rawValue: modeRawValue) ?? .defaultMode
        let preset = AppAccentPreset(rawValue: accentPresetRawValue) ?? .defaultPreset
        let accent = preset == .custom
            ? customColor(hex: customAccentHex)
            : preset.color

        content
            .tint(accent)
            .preferredColorScheme(mode.colorScheme)
    }

    private func customColor(hex: String) -> Color {
        guard let rgb = AppThemeRGB(hexString: hex) else {
            return AppAccentPreset.defaultPreset.color
        }
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
