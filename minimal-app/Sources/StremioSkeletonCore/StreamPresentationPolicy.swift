import Foundation

struct PresentedStream: Identifiable, Sendable {
    let id: String
    let providerID: String
    let providerName: String
    let stream: Stream
    let playbackPriority: Int
    let fileSizeBadge: String?
    let fileSizeBytes: Int64?
    let qualityBadge: String?
    let isCached: Bool

    init(id: String, providerID: String, providerName: String, stream: Stream) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.stream = stream

        let metadata = [stream.title, stream.name, stream.description]
            .compactMap { $0 }
            .joined(separator: " ")
        let uppercased = metadata.uppercased()
        let fileSize = StreamPresentationPolicy.fileSize(in: metadata)
        fileSizeBadge = fileSize?.text
            .uppercased()
            .replacingOccurrences(of: " ", with: " ")
        fileSizeBytes = fileSize?.bytes
        isCached = metadata.contains("⚡")

        if let quality = StreamPresentationPolicy.firstMatch(
            StreamPresentationPolicy.qualityExpression,
            in: metadata
        ) {
            qualityBadge = switch quality.uppercased() {
            case "4320P", "8K": "8K"
            case "2160P", "4K": "4K"
            default: quality.uppercased()
            }
        } else {
            qualityBadge = nil
        }

        var score = isCached ? -1_000 : 0
        if uppercased.contains("4320P") || uppercased.contains("8K") {
            score += 1_000
        } else if uppercased.contains("1080P") {
            score -= 120
        } else if uppercased.contains("2160P") || uppercased.contains("4K") {
            score -= 100
        } else if uppercased.contains("720P") {
            score -= 70
        }
        if uppercased.contains("REMUX") { score += 12 }
        playbackPriority = score
    }
}

enum StreamRankingMode: String, CaseIterable, Identifiable, Sendable {
    case current
    case biggestFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: "Current"
        case .biggestFiles: "Big files"
        }
    }
}

enum StreamPresentationPolicy {
    fileprivate static let sizeExpression = try! NSRegularExpression(
        pattern: #"(?<![A-Z0-9])(\d+(?:\.\d+)?)\s*(TB|GB|MB)(?![A-Z0-9])"#,
        options: [.caseInsensitive]
    )
    fileprivate static let qualityExpression = try! NSRegularExpression(
        pattern: #"(?:4320P|8K|2160P|4K|1080P|720P|480P)"#,
        options: [.caseInsensitive]
    )

    /// Ranking changes display order only and never removes a provider result.
    /// Cached sources are a hard first tier in either user-selectable mode.
    static func ranked(
        _ streams: [PresentedStream],
        mode: StreamRankingMode = .current
    ) -> [PresentedStream] {
        streams.sorted {
            if $0.isCached != $1.isCached {
                return $0.isCached
            }
            if mode == .biggestFiles, $0.fileSizeBytes != $1.fileSizeBytes {
                return ($0.fileSizeBytes ?? -1) > ($1.fileSizeBytes ?? -1)
            }
            return currentOrder($0, precedes: $1)
        }
    }

    private static func currentOrder(
        _ lhs: PresentedStream,
        precedes rhs: PresentedStream
    ) -> Bool {
        if lhs.playbackPriority != rhs.playbackPriority {
            return lhs.playbackPriority < rhs.playbackPriority
        }
        return lhs.id < rhs.id
    }

    fileprivate static func fileSize(in text: String) -> (text: String, bytes: Int64)? {
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = sizeExpression.firstMatch(
            in: text,
            options: [],
            range: searchRange
        ), match.numberOfRanges == 3,
           let fullRange = Range(match.range(at: 0), in: text),
           let numberRange = Range(match.range(at: 1), in: text),
           let unitRange = Range(match.range(at: 2), in: text),
           let number = Double(text[numberRange])
        else { return nil }

        let multiplier: Double = switch text[unitRange].uppercased() {
        case "TB": 1_099_511_627_776
        case "GB": 1_073_741_824
        default: 1_048_576
        }
        let bytes = number * multiplier
        guard bytes.isFinite, bytes > 0, bytes <= Double(Int64.max) else { return nil }
        return (
            String(text[fullRange]).trimmingCharacters(in: .whitespacesAndNewlines),
            Int64(bytes.rounded())
        )
    }

    fileprivate static func firstMatch(
        _ expression: NSRegularExpression,
        in text: String
    ) -> String? {
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(
            in: text,
            options: [],
            range: searchRange
        ), let range = Range(match.range, in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
