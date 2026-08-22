import Foundation

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
