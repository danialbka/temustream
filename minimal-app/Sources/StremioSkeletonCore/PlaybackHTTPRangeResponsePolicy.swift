import Foundation

public enum PlaybackHTTPRangeResponseValidation: Equatable, Sendable {
    case accepted
    case invalidStatus
    case invalidContentRange
}

/// Validates the response metadata for a byte-range request before any body
/// bytes are made available to a progressive media reader.
public enum PlaybackHTTPRangeResponsePolicy {
    public static func validate(
        statusCode: Int,
        contentRange: String?,
        expectedLowerBound: UInt64,
        expectedUpperBound: UInt64,
        expectedTotalLength: UInt64?
    ) -> PlaybackHTTPRangeResponseValidation {
        guard statusCode == 206 else { return .invalidStatus }
        guard let parsed = ParsedContentRange(contentRange),
              parsed.lowerBound == expectedLowerBound,
              parsed.upperBound == expectedUpperBound,
              expectedTotalLength.map({ $0 == parsed.totalLength }) ?? true
        else { return .invalidContentRange }
        return .accepted
    }

    private struct ParsedContentRange {
        let lowerBound: UInt64
        let upperBound: UInt64
        let totalLength: UInt64

        init?(_ value: String?) {
            guard let value else { return nil }
            let pieces = value.split { character in
                character == " " || character == "/" || character == "-"
            }
            guard pieces.count == 4,
                  pieces[0].lowercased() == "bytes",
                  let lowerBound = UInt64(pieces[1]),
                  let upperBound = UInt64(pieces[2]),
                  let totalLength = UInt64(pieces[3]),
                  lowerBound <= upperBound,
                  upperBound < totalLength
            else { return nil }
            self.lowerBound = lowerBound
            self.upperBound = upperBound
            self.totalLength = totalLength
        }
    }
}
