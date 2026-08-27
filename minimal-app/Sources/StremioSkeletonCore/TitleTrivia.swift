import Foundation

public struct TitleTriviaFact: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let text: String
    public let isSpoiler: Bool

    public init(id: String, text: String, isSpoiler: Bool) {
        self.id = id
        self.text = text
        self.isSpoiler = isSpoiler
    }
}

/// Presents only facts explicitly supplied by a metadata provider. Ordinary
/// title metadata belongs in the details UI and must never be relabelled as
/// trivia just to keep this section populated.
public enum TitleTriviaBuilder {
    public static func facts(for item: MetaItem, limit: Int = 50) -> [TitleTriviaFact] {
        guard limit > 0 else { return [] }

        var seen = Set<String>()
        var facts: [TitleTriviaFact] = []
        for rawText in item.explicitTriviaFacts {
            guard let parsed = parsedFact(rawText) else { continue }
            let deduplicationKey = parsed.text.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            guard seen.insert(deduplicationKey).inserted else { continue }
            facts.append(
                TitleTriviaFact(
                    id: "provider-trivia-\(facts.count)",
                    text: parsed.text,
                    isSpoiler: parsed.isSpoiler
                )
            )
            if facts.count == limit { break }
        }
        return facts
    }

    private static func parsedFact(_ rawValue: String) -> (text: String, isSpoiler: Bool)? {
        guard let normalizedValue = normalized(rawValue) else { return nil }
        let spoilerPrefix = "SPOILER:"
        let isSpoiler = normalizedValue.range(
            of: spoilerPrefix,
            options: [.anchored, .caseInsensitive]
        ) != nil
        let factValue = isSpoiler
            ? String(normalizedValue.dropFirst(spoilerPrefix.count))
            : normalizedValue
        guard let text = normalized(factValue) else { return nil }
        return (text, isSpoiler)
    }

    private static func normalized(_ value: String?) -> String? {
        let collapsed = value?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed?.isEmpty == false ? collapsed : nil
    }
}
