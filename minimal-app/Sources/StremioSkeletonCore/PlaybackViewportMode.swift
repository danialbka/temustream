import Foundation

/// The two intentional video presentation modes exposed by every player.
/// Keeping this binary avoids leaving playback at an accidental, arbitrary
/// zoom level after a pinch gesture.
public enum PlaybackViewportMode: String, CaseIterable, Equatable, Sendable {
    case fit
    case fill

    public var toggled: Self {
        self == .fit ? .fill : .fit
    }

    /// Pinching out fills the viewport; pinching in restores the full frame.
    /// Small magnification changes are ignored so normal two-finger contact
    /// does not unexpectedly crop the picture.
    public func applying(magnification: Double, threshold: Double = 0.08) -> Self {
        guard magnification.isFinite, threshold >= 0 else { return self }
        if magnification >= 1 + threshold { return .fill }
        if magnification <= 1 - threshold { return .fit }
        return self
    }

    /// Scale applied to an aspect-fit render surface so it completely covers
    /// the viewport while preserving the source aspect ratio.
    public func renderScale(
        videoWidth: Double,
        videoHeight: Double,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> Double {
        guard self == .fill,
              videoWidth > 0, videoHeight > 0,
              viewportWidth > 0, viewportHeight > 0,
              videoWidth.isFinite, videoHeight.isFinite,
              viewportWidth.isFinite, viewportHeight.isFinite
        else { return 1 }

        let videoAspect = videoWidth / videoHeight
        let viewportAspect = viewportWidth / viewportHeight
        return max(videoAspect / viewportAspect, viewportAspect / videoAspect)
    }
}
