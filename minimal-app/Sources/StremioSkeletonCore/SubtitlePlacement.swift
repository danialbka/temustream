import Foundation

public enum SubtitleSizePreset: String, CaseIterable, Sendable {
    case small
    case medium
    case large
    case extraLarge

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    public var compactTitle: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        case .extraLarge: "XL"
        }
    }

    public var pointSize: Double {
        switch self {
        case .small: 15
        case .medium: 18
        case .large: 22
        case .extraLarge: 27
        }
    }

    public var relativeScalePercent: Int {
        switch self {
        case .small: 85
        case .medium: 100
        case .large: 125
        case .extraLarge: 150
        }
    }
}

public enum SubtitleColorPreset: String, CaseIterable, Sendable {
    case white
    case yellow
    case cyan
    case green

    public var title: String {
        switch self {
        case .white: "White"
        case .yellow: "Yellow"
        case .cyan: "Cyan"
        case .green: "Green"
        }
    }

    public var hexRGB: String {
        switch self {
        case .white: "FFFFFF"
        case .yellow: "FFD54F"
        case .cyan: "80DEEA"
        case .green: "A5D6A7"
        }
    }

    public var redComponent: Double {
        switch self {
        case .white: 1
        case .yellow: 1
        case .cyan: 128 / 255
        case .green: 165 / 255
        }
    }

    public var greenComponent: Double {
        switch self {
        case .white: 1
        case .yellow: 213 / 255
        case .cyan: 222 / 255
        case .green: 214 / 255
        }
    }

    public var blueComponent: Double {
        switch self {
        case .white: 1
        case .yellow: 79 / 255
        case .cyan: 234 / 255
        case .green: 167 / 255
        }
    }
}

public enum SubtitleWeightPreset: String, CaseIterable, Sendable {
    case regular
    case semibold
    case bold

    public var title: String {
        switch self {
        case .regular: "Regular"
        case .semibold: "Semibold"
        case .bold: "Bold"
        }
    }
}

public struct SubtitleStyle: Equatable, Sendable {
    public static let `default` = SubtitleStyle()

    public let size: SubtitleSizePreset
    public let color: SubtitleColorPreset
    public let weight: SubtitleWeightPreset
    public let backgroundOpacity: Double
    public let shadowEnabled: Bool

    public init(
        size: SubtitleSizePreset = .medium,
        color: SubtitleColorPreset = .white,
        weight: SubtitleWeightPreset = .semibold,
        backgroundOpacity: Double = 0.72,
        shadowEnabled: Bool = true
    ) {
        self.size = size
        self.color = color
        self.weight = weight
        self.backgroundOpacity = min(max(backgroundOpacity.isFinite ? backgroundOpacity : 0.72, 0), 0.9)
        self.shadowEnabled = shadowEnabled
    }

    public init(
        sizeRawValue: String?,
        colorRawValue: String?,
        weightRawValue: String?,
        backgroundOpacity: Double,
        shadowEnabled: Bool
    ) {
        self.init(
            size: SubtitleSizePreset(rawValue: sizeRawValue ?? "") ?? Self.default.size,
            color: SubtitleColorPreset(rawValue: colorRawValue ?? "") ?? Self.default.color,
            weight: SubtitleWeightPreset(rawValue: weightRawValue ?? "") ?? Self.default.weight,
            backgroundOpacity: backgroundOpacity,
            shadowEnabled: shadowEnabled
        )
    }
}

public enum SubtitleStylePreferences {
    public static let sizeKey = "subtitleStyle.size"
    public static let colorKey = "subtitleStyle.color"
    public static let weightKey = "subtitleStyle.weight"
    public static let backgroundOpacityKey = "subtitleStyle.backgroundOpacity"
    public static let shadowEnabledKey = "subtitleStyle.shadowEnabled"

    public static func current(defaults: UserDefaults = .standard) -> SubtitleStyle {
        let fallback = SubtitleStyle.default
        let opacity = defaults.object(forKey: backgroundOpacityKey) == nil
            ? fallback.backgroundOpacity
            : defaults.double(forKey: backgroundOpacityKey)
        let shadowEnabled = defaults.object(forKey: shadowEnabledKey) == nil
            ? fallback.shadowEnabled
            : defaults.bool(forKey: shadowEnabledKey)

        return SubtitleStyle(
            sizeRawValue: defaults.string(forKey: sizeKey),
            colorRawValue: defaults.string(forKey: colorKey),
            weightRawValue: defaults.string(forKey: weightKey),
            backgroundOpacity: opacity,
            shadowEnabled: shadowEnabled
        )
    }

    public static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: sizeKey)
        defaults.removeObject(forKey: colorKey)
        defaults.removeObject(forKey: weightKey)
        defaults.removeObject(forKey: backgroundOpacityKey)
        defaults.removeObject(forKey: shadowEnabledKey)
    }
}

/// A viewport-independent subtitle anchor. Keeping the position normalized
/// prevents a drag made in portrait from becoming an off-screen absolute
/// offset after the player rotates.
public struct SubtitlePlacement: Equatable, Sendable {
    public static let defaultPosition = SubtitlePlacement(
        horizontal: 0.5,
        vertical: 0.89
    )

    public let horizontal: Double
    public let vertical: Double

    public init(horizontal: Double, vertical: Double) {
        self.horizontal = Self.clamp(horizontal, lower: 0.06, upper: 0.94)
        self.vertical = Self.clamp(vertical, lower: 0.08, upper: 0.92)
    }

    public func translated(
        x: Double,
        y: Double,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> Self {
        guard viewportWidth.isFinite, viewportWidth > 0,
              viewportHeight.isFinite, viewportHeight > 0,
              x.isFinite, y.isFinite
        else { return self }

        return Self(
            horizontal: horizontal + x / viewportWidth,
            vertical: vertical + y / viewportHeight
        )
    }

    public func constrained(
        contentWidth: Double,
        contentHeight: Double,
        viewportWidth: Double,
        viewportHeight: Double,
        margin: Double = 12
    ) -> Self {
        guard contentWidth.isFinite, contentWidth >= 0,
              contentHeight.isFinite, contentHeight >= 0,
              viewportWidth.isFinite, viewportWidth > 0,
              viewportHeight.isFinite, viewportHeight > 0,
              margin.isFinite, margin >= 0
        else { return self }

        let horizontalInset = min(
            max((contentWidth / 2 + margin) / viewportWidth, 0.06),
            0.5
        )
        let verticalInset = min(
            max((contentHeight / 2 + margin) / viewportHeight, 0.08),
            0.5
        )
        return Self(
            horizontal: min(max(horizontal, horizontalInset), 1 - horizontalInset),
            vertical: min(max(vertical, verticalInset), 1 - verticalInset)
        )
    }

    private static func clamp(
        _ value: Double,
        lower: Double,
        upper: Double
    ) -> Double {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}
