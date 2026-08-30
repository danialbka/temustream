import Foundation

public enum PlaybackPresentedCadenceStatus: String, Codable, Sendable {
    case verified
    case implausible
    case unsupported
    case notApplicable
}

public enum PlaybackStressPassPolicy {
    public static func realTimeRatioIsPlausible(_ ratio: Double) -> Bool {
        ratio.isFinite && (0.95...1.10).contains(ratio)
    }

    public static func interactionDropsAreWithinBudget(
        droppedFrames: UInt32,
        seekAttempts: Int,
        pauseResumeAttempts: Int
    ) -> Bool {
        let interactionCount = max(seekAttempts, 0) + max(pauseResumeAttempts, 0)
        let budget = UInt32(clamping: max(interactionCount, 5))
        return droppedFrames <= budget
    }

    public static func presentedCadenceStatus(
        hasVideo: Bool,
        nominalFPS: Double,
        presentedFPS: Double?
    ) -> PlaybackPresentedCadenceStatus {
        guard hasVideo else { return .notApplicable }
        guard let presentedFPS,
              presentedFPS.isFinite,
              presentedFPS > 0
        else { return .unsupported }
        guard nominalFPS.isFinite, nominalFPS > 0 else { return .verified }
        return presentedFPS >= nominalFPS * 0.70
            && presentedFPS <= nominalFPS * 1.30
            ? .verified
            : .implausible
    }
}
