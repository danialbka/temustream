import Foundation

public enum TitleTriviaKind: String, Equatable, Hashable, Sendable {
    case provided
    case awards
    case episodes
    case status
    case release
    case director
    case writing
    case origin
    case runtime

    public var title: String {
        switch self {
        case .provided: "Did You Know?"
        case .awards: "Awards"
        case .episodes: "Episode Guide"
        case .status: "Series Status"
        case .release: "First Released"
        case .director: "Behind the Camera"
        case .writing: "Writing"
        case .origin: "Origin"
        case .runtime: "Runtime"
        }
    }
}

public struct TitleTriviaFact: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let kind: TitleTriviaKind
    public let text: String

    public init(id: String, kind: TitleTriviaKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// Builds short, provider-backed facts without fabricating plot or production
/// claims. Explicit add-on trivia wins; Cinemeta's awards, release, status,
/// credits, country, runtime, and episode inventory provide useful fallbacks.
public enum TitleTriviaBuilder {
    public static func facts(for item: MetaItem, limit: Int = 6) -> [TitleTriviaFact] {
        guard limit > 0 else { return [] }
        var candidates: [(TitleTriviaKind, String)] = []

        for fact in item.explicitTriviaFacts {
            candidates.append((.provided, fact))
        }
        if let awards = normalized(item.awards), !isUnavailable(awards) {
            candidates.append((.awards, awards))
        }

        if item.type.caseInsensitiveCompare("series") == .orderedSame {
            if let episodeFact = episodeInventoryFact(item.videos) {
                candidates.append((.episodes, episodeFact))
            }
            if let status = normalized(item.status), !isUnavailable(status) {
                candidates.append((.status, statusFact(status)))
            }
        }

        if let released = normalized(item.released),
           let formattedDate = formattedReleaseDate(released) {
            let verb = item.type.caseInsensitiveCompare("series") == .orderedSame
                ? "Premiered"
                : "Released"
            candidates.append((.release, "\(verb) on \(formattedDate)."))
        }

        let directors = normalizedList(item.director)
        if !directors.isEmpty {
            candidates.append((.director, "Directed by \(joinedNames(directors.prefix(3)))."))
        }

        let writers = normalizedList(item.writer)
        if !writers.isEmpty {
            candidates.append((.writing, "Writing credits include \(joinedNames(writers.prefix(3)))."))
        }

        if let country = normalized(item.country), !isUnavailable(country) {
            candidates.append((.origin, "A production from \(country)."))
        }

        if let runtime = normalized(item.runtime), !isUnavailable(runtime) {
            let label = item.type.caseInsensitiveCompare("series") == .orderedSame
                ? "Episodes typically run for \(runtime)."
                : "The listed runtime is \(runtime)."
            candidates.append((.runtime, label))
        }

        var seen = Set<String>()
        var facts: [TitleTriviaFact] = []
        for (kind, rawText) in candidates {
            guard let text = normalized(rawText) else { continue }
            let deduplicationKey = text.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seen.insert(deduplicationKey).inserted else { continue }
            facts.append(
                TitleTriviaFact(
                    id: "\(kind.rawValue)-\(facts.count)",
                    kind: kind,
                    text: text
                )
            )
            if facts.count == limit { break }
        }
        return facts
    }

    private static func episodeInventoryFact(_ videos: [Video]?) -> String? {
        let regularEpisodes = (videos ?? []).filter {
            ($0.season ?? 0) > 0 && ($0.episode ?? 0) > 0
        }
        let uniqueEpisodeIDs = Set(regularEpisodes.map(\.id))
        let seasons = Set(regularEpisodes.compactMap(\.season))
        guard !uniqueEpisodeIDs.isEmpty else { return nil }

        let episodeLabel = uniqueEpisodeIDs.count == 1 ? "episode" : "episodes"
        guard !seasons.isEmpty else {
            return "The provider lists \(uniqueEpisodeIDs.count) \(episodeLabel)."
        }
        let seasonLabel = seasons.count == 1 ? "season" : "seasons"
        return "The provider lists \(uniqueEpisodeIDs.count) \(episodeLabel) across "
            + "\(seasons.count) \(seasonLabel)."
    }

    private static func statusFact(_ status: String) -> String {
        switch status.lowercased() {
        case "continuing", "returning series", "in production":
            "This series is listed as continuing."
        case "ended", "canceled", "cancelled":
            "This series is listed as \(status.lowercased())."
        default:
            "The provider lists the series status as \(status)."
        }
    }

    private static func formattedReleaseDate(_ value: String) -> String? {
        let datePrefix = value.prefix(10)
        let components = datePrefix.split(separator: "-")
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              (1...12).contains(month),
              (1...31).contains(day)
        else { return nil }
        let monthNames = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        ]
        return "\(monthNames[month - 1]) \(day), \(year)"
    }

    private static func joinedNames<S: Sequence>(_ names: S) -> String where S.Element == String {
        let values = Array(names)
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default:
            return values.dropLast().joined(separator: ", ") + ", and " + values.last!
        }
    }

    private static func normalized(_ value: String?) -> String? {
        let collapsed = value?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed?.isEmpty == false ? collapsed : nil
    }

    private static func normalizedList(_ values: [String]?) -> [String] {
        (values ?? []).reduce(into: [String]()) { result, rawValue in
            guard let value = normalized(rawValue),
                  !isUnavailable(value),
                  !result.contains(where: {
                      $0.caseInsensitiveCompare(value) == .orderedSame
                  })
            else { return }
            result.append(value)
        }
    }

    private static func isUnavailable(_ value: String) -> Bool {
        let normalizedValue = value.lowercased()
        return normalizedValue == "n/a" || normalizedValue == "unknown" || normalizedValue == "-"
    }
}
