import Foundation

struct TorBoxFileCandidate: Decodable, Equatable, Sendable {
    let id: Int
    let name: String
    let shortName: String?
    let size: Int64
    let mimetype: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size, mimetype
        case shortName = "short_name"
    }
}

enum TorBoxStreamSelection {
    private static let videoExtensions: Set<String> = [
        "3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg",
        "mpg", "mts", "ogv", "ts", "webm", "wmv",
    ]
    private static let secondaryVideoMarkers = [
        "sample", "trailer", "preview", "featurette", "behind the scenes",
        "deleted scene", "extras/", "bonus/",
    ]

    static func expectedSizeBytes(in metadata: [String?]) -> Int64? {
        let text = metadata.compactMap { $0 }.joined(separator: " ")
        let pattern = #"(?i)(\d+(?:[.,]\d+)?)\s*([kmgt]i?b)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let number = Double(text[numberRange].replacingOccurrences(of: ",", with: "."))
        else { return nil }

        let unit = text[unitRange].lowercased()
        let binary = unit.contains("i")
        let base = binary ? 1_024.0 : 1_000.0
        let exponent: Int = switch unit.first {
        case "k": 1
        case "m": 2
        case "g": 3
        case "t": 4
        default: 0
        }
        let bytes = number * pow(base, Double(exponent))
        guard bytes.isFinite,
              bytes > 0,
              let roundedBytes = Int64(exactly: bytes.rounded())
        else { return nil }
        return roundedBytes
    }

    static func shouldRepair(
        expectedSizeBytes: Int64,
        resolvedSizeBytes: Int64
    ) -> Bool {
        guard expectedSizeBytes > 0, resolvedSizeBytes > 0 else { return false }
        let missingBytes = expectedSizeBytes - resolvedSizeBytes
        return missingBytes > 64_000_000
            && Double(resolvedSizeBytes) < Double(expectedSizeBytes) * 0.5
    }

    static func replacementFileID(
        files: [TorBoxFileCandidate],
        currentFileID: Int?,
        expectedSizeBytes: Int64
    ) -> Int? {
        let videos = files.filter(isVideo)
        guard !videos.isEmpty else { return nil }
        let primaryVideos = videos.filter { file in
            let path = displayName(file).lowercased()
            return !secondaryVideoMarkers.contains(where: path.contains)
        }
        let candidates = primaryVideos.isEmpty ? videos : primaryVideos
        guard let best = candidates.min(by: { lhs, rhs in
            distance(lhs.size, from: expectedSizeBytes)
                < distance(rhs.size, from: expectedSizeBytes)
        }), best.id != currentFileID
        else { return nil }
        return best.id
    }

    private static func isVideo(_ file: TorBoxFileCandidate) -> Bool {
        if file.mimetype?.lowercased().hasPrefix("video/") == true { return true }
        let pathExtension = (displayName(file) as NSString).pathExtension.lowercased()
        return videoExtensions.contains(pathExtension)
    }

    private static func displayName(_ file: TorBoxFileCandidate) -> String {
        file.shortName?.isEmpty == false ? file.shortName! : file.name
    }

    private static func distance(_ size: Int64, from expected: Int64) -> Double {
        guard size > 0, expected > 0 else { return .greatestFiniteMagnitude }
        return abs(log(Double(size) / Double(expected)))
    }
}
