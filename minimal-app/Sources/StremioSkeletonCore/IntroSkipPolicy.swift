import Foundation

/// Accepts exact, stream-scoped intro metadata and rejects suspicious or
/// low-confidence ranges. It deliberately does not infer a generic duration.
public enum IntroSkipPolicy {
    public static let minimumSegmentDuration: TimeInterval = 2
    public static let maximumSegmentDuration: TimeInterval = 10 * 60
    public static let maximumIntroStart: TimeInterval = 15 * 60
    public static let minimumReportedConfidence = 0.80
    public static let presentationLeadTime: TimeInterval = 2

    public static func bestValidatedSegment(
        from segments: [PlaybackSkipSegment]
    ) -> PlaybackSkipSegment? {
        segments
            .filter(isValidatedIntro)
            .sorted(by: isPreferred)
            .first
    }

    public static func shouldOfferSkip(
        for segment: PlaybackSkipSegment,
        position: TimeInterval
    ) -> Bool {
        guard isValidatedIntro(segment), position.isFinite else { return false }
        return position >= max(segment.start - presentationLeadTime, 0)
            && position < segment.end - 0.25
    }

    public static func targetPosition(for segment: PlaybackSkipSegment) -> TimeInterval? {
        isValidatedIntro(segment) ? segment.end : nil
    }

    public static func isValidatedIntro(_ segment: PlaybackSkipSegment) -> Bool {
        let normalizedType = segment.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["intro", "opening", "opening-credits", "op"].contains(normalizedType),
              segment.start.isFinite,
              segment.end.isFinite,
              segment.start >= 0,
              segment.start <= maximumIntroStart,
              segment.end - segment.start >= minimumSegmentDuration,
              segment.end - segment.start <= maximumSegmentDuration
        else { return false }

        if let confidence = segment.confidence {
            guard confidence.isFinite,
                  confidence >= minimumReportedConfidence,
                  confidence <= 1
            else { return false }
        }
        if let sampleSize = segment.sampleSize, sampleSize <= 0 { return false }
        return true
    }

    private static func isPreferred(
        _ lhs: PlaybackSkipSegment,
        _ rhs: PlaybackSkipSegment
    ) -> Bool {
        let lhsConfidence = lhs.confidence ?? 1
        let rhsConfidence = rhs.confidence ?? 1
        if lhsConfidence != rhsConfidence { return lhsConfidence > rhsConfidence }
        let lhsSamples = lhs.sampleSize ?? 0
        let rhsSamples = rhs.sampleSize ?? 0
        if lhsSamples != rhsSamples { return lhsSamples > rhsSamples }
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.end < rhs.end
    }
}
