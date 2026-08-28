import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum WikipediaTriviaError: LocalizedError, Equatable {
    case unsupportedIdentifier
    case articleNotFound
    case noRelevantSections
    case invalidResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedIdentifier:
            "This title does not have a usable IMDb identifier."
        case .articleNotFound:
            "Wikipedia does not have a matching English article for this title."
        case .noRelevantSections:
            "Wikipedia does not currently have production trivia for this title."
        case .invalidResponse:
            "Wikipedia returned an invalid response."
        case let .httpStatus(status):
            "Wikipedia returned HTTP \(status)."
        }
    }
}

public struct WikipediaTriviaExcerpt: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

public struct WikipediaTriviaSection: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let excerpts: [WikipediaTriviaExcerpt]

    public init(id: String, title: String, excerpts: [WikipediaTriviaExcerpt]) {
        self.id = id
        self.title = title
        self.excerpts = excerpts
    }
}

public struct WikipediaTitleTrivia: Equatable, Hashable, Sendable {
    public let pageTitle: String
    public let articleURL: URL
    public let revisionURL: URL
    public let revisionID: Int
    public let sections: [WikipediaTriviaSection]

    public init(
        pageTitle: String,
        articleURL: URL,
        revisionURL: URL,
        revisionID: Int,
        sections: [WikipediaTriviaSection]
    ) {
        self.pageTitle = pageTitle
        self.articleURL = articleURL
        self.revisionURL = revisionURL
        self.revisionID = revisionID
        self.sections = sections
    }

    public var excerpts: [WikipediaTriviaExcerpt] {
        sections.flatMap(\.excerpts)
    }

    public static let licenseURL = URL(
        string: "https://creativecommons.org/licenses/by-sa/4.0/"
    )!
}

public enum WikipediaTitleIdentifier {
    /// Stremio series video identifiers may append `:season:episode`; only the
    /// canonical title prefix is eligible for exact Wikidata matching.
    public static func imdbID(from rawIdentifier: String) -> String? {
        let candidate = rawIdentifier
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let candidate,
              candidate.hasPrefix("tt"),
              (7...10).contains(candidate.dropFirst(2).count),
              candidate.dropFirst(2).allSatisfy(\.isNumber)
        else { return nil }
        return candidate
    }
}

/// Loads exact, source-attributed production facts without fuzzy title search.
/// The IMDb identifier is resolved through Wikidata's P345 property and the
/// resulting English Wikipedia article is read through the MediaWiki API.
public struct WikipediaTriviaClient: Sendable {
    private static let wikidataEndpoint = URL(string: "https://query.wikidata.org/sparql")!
    private static let wikipediaEndpoint = URL(string: "https://en.wikipedia.org/w/api.php")!
    private static let userAgent = "Bunny/1.3 (https://github.com/danialbka/temustream)"

    private let loader: any HTTPRequestLoading
    private let requestTimeout: TimeInterval
    private let maximumSections: Int
    private let excerptsPerSection: Int

    public init(
        loader: any HTTPRequestLoading = URLSession.shared,
        requestTimeout: TimeInterval = 8,
        maximumSections: Int = 4,
        excerptsPerSection: Int = 2
    ) {
        self.loader = loader
        self.requestTimeout = requestTimeout
        self.maximumSections = max(1, maximumSections)
        self.excerptsPerSection = max(1, excerptsPerSection)
    }

    public func trivia(for item: MetaItem) async throws -> WikipediaTitleTrivia {
        try await trivia(forIMDbID: item.id)
    }

    public func trivia(forIMDbID rawIdentifier: String) async throws -> WikipediaTitleTrivia {
        guard let imdbID = WikipediaTitleIdentifier.imdbID(from: rawIdentifier) else {
            throw WikipediaTriviaError.unsupportedIdentifier
        }
        let articleURL = try await resolveArticleURL(forIMDbID: imdbID)
        guard let pageTitle = Self.pageTitle(from: articleURL) else {
            throw WikipediaTriviaError.invalidResponse
        }
        let directory = try await loadSectionDirectory(pageTitle: pageTitle)
        let descriptors = Self.relevantSections(from: directory.sections)
            .prefix(maximumSections)
        guard !descriptors.isEmpty else {
            throw WikipediaTriviaError.noRelevantSections
        }

        let orderedSections = await withTaskGroup(
            of: (Int, WikipediaTriviaSection?).self,
            returning: [WikipediaTriviaSection].self
        ) { group in
            for (order, descriptor) in descriptors.enumerated() {
                group.addTask {
                    do {
                        let html = try await loadSectionHTML(
                            revisionID: directory.revisionID,
                            sectionIndex: descriptor.index
                        )
                        let excerpts = Self.excerpts(
                            from: html,
                            maximumCount: excerptsPerSection
                        )
                        guard !excerpts.isEmpty else { return (order, nil) }
                        return (
                            order,
                            WikipediaTriviaSection(
                                id: "wikipedia-section-\(descriptor.index)",
                                title: descriptor.line,
                                excerpts: excerpts.enumerated().map { index, text in
                                    WikipediaTriviaExcerpt(
                                        id: "wikipedia-\(descriptor.index)-\(index)",
                                        text: text
                                    )
                                }
                            )
                        )
                    } catch {
                        return (order, nil)
                    }
                }
            }

            var loaded: [(Int, WikipediaTriviaSection)] = []
            for await (order, section) in group {
                if let section { loaded.append((order, section)) }
            }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }

        guard !orderedSections.isEmpty else {
            throw WikipediaTriviaError.noRelevantSections
        }
        guard let revisionURL = Self.revisionURL(
            pageTitle: pageTitle,
            revisionID: directory.revisionID
        ) else {
            throw WikipediaTriviaError.invalidResponse
        }
        return WikipediaTitleTrivia(
            pageTitle: directory.title,
            articleURL: articleURL,
            revisionURL: revisionURL,
            revisionID: directory.revisionID,
            sections: orderedSections
        )
    }

    private func resolveArticleURL(forIMDbID imdbID: String) async throws -> URL {
        let query = """
        PREFIX schema: <http://schema.org/>
        PREFIX wdt: <http://www.wikidata.org/prop/direct/>
        SELECT ?article WHERE {
          ?item wdt:P345 \"\(imdbID)\".
          ?article schema:about ?item;
                   schema:isPartOf <https://en.wikipedia.org/>.
        }
        LIMIT 1
        """
        guard var components = URLComponents(
            url: Self.wikidataEndpoint,
            resolvingAgainstBaseURL: false
        ) else { throw WikipediaTriviaError.invalidResponse }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { throw WikipediaTriviaError.invalidResponse }
        let response = try JSONDecoder().decode(
            WikidataArticleResponse.self,
            from: try await fetch(url, accept: "application/sparql-results+json")
        )
        guard let rawURL = response.results.bindings.first?.article.value,
              let articleURL = URL(string: rawURL),
              articleURL.scheme == "https",
              articleURL.host?.lowercased() == "en.wikipedia.org",
              Self.pageTitle(from: articleURL) != nil
        else { throw WikipediaTriviaError.articleNotFound }
        return articleURL
    }

    private func loadSectionDirectory(pageTitle: String) async throws -> SectionDirectory {
        let url = try wikipediaURL(queryItems: [
            URLQueryItem(name: "action", value: "parse"),
            URLQueryItem(name: "page", value: pageTitle),
            URLQueryItem(name: "prop", value: "sections|revid"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ])
        let response = try JSONDecoder().decode(
            WikipediaSectionsResponse.self,
            from: try await fetch(url, accept: "application/json")
        )
        guard response.parse.revisionID > 0 else {
            throw WikipediaTriviaError.invalidResponse
        }
        return SectionDirectory(
            title: response.parse.title,
            revisionID: response.parse.revisionID,
            sections: response.parse.sections
        )
    }

    private func loadSectionHTML(revisionID: Int, sectionIndex: String) async throws -> String {
        let url = try wikipediaURL(queryItems: [
            URLQueryItem(name: "action", value: "parse"),
            URLQueryItem(name: "oldid", value: String(revisionID)),
            URLQueryItem(name: "prop", value: "text"),
            URLQueryItem(name: "section", value: sectionIndex),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ])
        let response = try JSONDecoder().decode(
            WikipediaSectionTextResponse.self,
            from: try await fetch(url, accept: "application/json")
        )
        return response.parse.text
    }

    private func wikipediaURL(queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(
            url: Self.wikipediaEndpoint,
            resolvingAgainstBaseURL: false
        ) else { throw WikipediaTriviaError.invalidResponse }
        components.queryItems = queryItems
        guard let url = components.url else { throw WikipediaTriviaError.invalidResponse }
        return url
    }

    private func fetch(_ url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WikipediaTriviaError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WikipediaTriviaError.httpStatus(http.statusCode)
        }
        return data
    }
}

private extension WikipediaTriviaClient {
    struct SectionDirectory: Sendable {
        let title: String
        let revisionID: Int
        let sections: [WikipediaSectionDescriptor]
    }

    struct WikidataArticleResponse: Decodable {
        let results: Results

        struct Results: Decodable {
            let bindings: [Binding]
        }

        struct Binding: Decodable {
            let article: Value
        }

        struct Value: Decodable {
            let value: String
        }
    }

    struct WikipediaSectionsResponse: Decodable {
        let parse: Payload

        struct Payload: Decodable {
            let title: String
            let revisionID: Int
            let sections: [WikipediaSectionDescriptor]

            enum CodingKeys: String, CodingKey {
                case title
                case revisionID = "revid"
                case sections
            }
        }
    }

    struct WikipediaSectionTextResponse: Decodable {
        let parse: Payload

        struct Payload: Decodable {
            let text: String
        }
    }

    struct WikipediaSectionDescriptor: Decodable, Sendable {
        let level: String
        let line: String
        let index: String
    }

    static func pageTitle(from articleURL: URL) -> String? {
        let prefix = "/wiki/"
        guard articleURL.path.hasPrefix(prefix) else { return nil }
        let encodedTitle = String(articleURL.path.dropFirst(prefix.count))
        guard !encodedTitle.isEmpty,
              let decodedTitle = encodedTitle.removingPercentEncoding
        else { return nil }
        return decodedTitle.replacingOccurrences(of: "_", with: " ")
    }

    static func revisionURL(pageTitle: String, revisionID: Int) -> URL? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/index.php")
        components?.queryItems = [
            URLQueryItem(name: "title", value: pageTitle),
            URLQueryItem(name: "oldid", value: String(revisionID)),
        ]
        return components?.url
    }

    static func relevantSections(
        from sections: [WikipediaSectionDescriptor]
    ) -> [WikipediaSectionDescriptor] {
        let ranked = sections.compactMap { section -> (Int, WikipediaSectionDescriptor)? in
            guard let rank = relevanceRank(for: section.line) else { return nil }
            return (rank, section)
        }
        let topLevel = ranked.filter { $0.1.level == "2" }
        let candidates = topLevel.isEmpty ? ranked : topLevel
        return candidates.sorted(by: { lhs, rhs in
            if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
            return sectionOrder(lhs.1.index).lexicographicallyPrecedes(
                sectionOrder(rhs.1.index)
            )
        }).map(\.1)
    }

    static func relevanceRank(for rawTitle: String) -> Int? {
        let title = normalizedText(rawTitle)?.lowercased() ?? ""
        let rankedTerms = [
            "production", "development", "writing", "casting", "filming",
            "animation", "visual effects", "special effects", "design",
            "music", "soundtrack", "legacy",
        ]
        return rankedTerms.firstIndex { term in
            title == term
                || title.hasPrefix(term + " ")
                || title.hasSuffix(" " + term)
                || title.contains(term + " and ")
        }
    }

    static func sectionOrder(_ index: String) -> [Int] {
        index.split(separator: ".").map { Int($0) ?? Int.max }
    }

    static func excerpts(from html: String, maximumCount: Int) -> [String] {
        let withoutNonContent = html
            .replacingOccurrences(
                of: #"(?is)<(sup|style|script|table|figure)\b[^>]*>.*?</\1>"#,
                with: " ",
                options: [.regularExpression]
            )
            .replacingOccurrences(
                of: #"(?s)<!--.*?-->"#,
                with: " ",
                options: [.regularExpression]
            )
        guard let paragraphExpression = try? NSRegularExpression(
            pattern: #"<p\b[^>]*>(.*?)</p>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(withoutNonContent.startIndex..., in: withoutNonContent)
        var seen = Set<String>()
        var excerpts: [String] = []
        for match in paragraphExpression.matches(in: withoutNonContent, range: range) {
            guard let contentRange = Range(match.range(at: 1), in: withoutNonContent) else {
                continue
            }
            let untagged = String(withoutNonContent[contentRange])
                .replacingOccurrences(
                    of: #"<br\s*/?>"#,
                    with: " ",
                    options: [.regularExpression, .caseInsensitive]
                )
                .replacingOccurrences(
                    of: #"<[^>]+>"#,
                    with: " ",
                    options: [.regularExpression]
                )
            guard let decoded = normalizedText(decodeHTMLEntities(untagged)),
                  decoded.count >= 40,
                  !decoded.localizedCaseInsensitiveContains("needs additional citations")
            else { continue }
            let excerpt = boundedExcerpt(decoded)
            let key = excerpt.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(key).inserted else { continue }
            excerpts.append(excerpt)
            if excerpts.count == maximumCount { break }
        }
        return excerpts
    }

    static func boundedExcerpt(_ text: String, maximumLength: Int = 700) -> String {
        guard text.count > maximumLength else { return text }
        let prefix = String(text.prefix(maximumLength))
        let characters = Array(prefix)
        if characters.count > 220 {
            for index in stride(from: characters.count - 1, through: 220, by: -1) {
                if ".!?".contains(characters[index]) {
                    return String(characters[...index])
                }
            }
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    static func normalizedText(_ value: String?) -> String? {
        let collapsed = value?
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed?.isEmpty == false ? collapsed : nil
    }

    static func decodeHTMLEntities(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: #"&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z]+);"#
        ) else { return value }
        let mutable = NSMutableString(string: value)
        let matches = expression.matches(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)
        )
        for match in matches.reversed() {
            let token = (value as NSString).substring(with: match.range(at: 1))
            guard let replacement = decodedEntity(token) else { continue }
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    static func decodedEntity(_ token: String) -> String? {
        if token.hasPrefix("#x"),
           let scalarValue = UInt32(token.dropFirst(2), radix: 16),
           let scalar = UnicodeScalar(scalarValue) {
            return String(scalar)
        }
        if token.hasPrefix("#"),
           let scalarValue = UInt32(token.dropFirst()),
           let scalar = UnicodeScalar(scalarValue) {
            return String(scalar)
        }
        return [
            "amp": "&", "apos": "'", "gt": ">", "lt": "<", "nbsp": " ",
            "quot": "\"", "ndash": "–", "mdash": "—", "hellip": "…",
            "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        ][token.lowercased()]
    }
}
