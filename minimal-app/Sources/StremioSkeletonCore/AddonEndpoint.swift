import Foundation

public enum AddonEndpointError: LocalizedError, Equatable {
    case invalidManifestURL
    case invalidResourceURL

    public var errorDescription: String? {
        switch self {
        case .invalidManifestURL:
            "Enter a valid HTTPS manifest URL or a localhost HTTP URL."
        case .invalidResourceURL:
            "The add-on resource URL could not be constructed."
        }
    }
}

public struct AddonEndpoint: Equatable, Sendable {
    public let manifestURL: URL
    public let baseURL: URL

    public init(manifestURL: URL) throws {
        guard let scheme = manifestURL.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && manifestURL.isLoopback),
              manifestURL.lastPathComponent == "manifest.json"
        else {
            throw AddonEndpointError.invalidManifestURL
        }
        self.manifestURL = manifestURL
        baseURL = manifestURL.deletingLastPathComponent()
    }

    public init(manifestInput: String) throws {
        var value = manifestInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.hasSuffix("/manifest.json") {
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            value += "/manifest.json"
        }
        guard let url = URL(string: value) else {
            throw AddonEndpointError.invalidManifestURL
        }
        try self.init(manifestURL: url)
    }

    public func catalogURL(
        type: String,
        id: String,
        search: String? = nil,
        skip: Int? = nil
    ) throws -> URL {
        var extra: [String] = []
        if let search, !search.isEmpty {
            extra.append("search=\(search)")
        }
        if let skip, skip > 0 {
            extra.append("skip=\(skip)")
        }
        return try resourceURL(resource: "catalog", type: type, id: id, extra: extra)
    }

    public func metaURL(type: String, id: String) throws -> URL {
        try resourceURL(resource: "meta", type: type, id: id)
    }

    public func streamURL(type: String, id: String) throws -> URL {
        try resourceURL(resource: "stream", type: type, id: id)
    }

    public func subtitlesURL(type: String, id: String) throws -> URL {
        try resourceURL(resource: "subtitles", type: type, id: id)
    }

    private func resourceURL(
        resource: String,
        type: String,
        id: String,
        extra: [String] = []
    ) throws -> URL {
        let segments = [resource, type, id] + (extra.isEmpty ? [] : [extra.joined(separator: "&")])
        var url = baseURL
        for segment in segments {
            url.appendPathComponent(segment)
        }
        url.appendPathExtension("json")
        guard URLComponents(url: url, resolvingAgainstBaseURL: false) != nil else {
            throw AddonEndpointError.invalidResourceURL
        }
        return url
    }
}

private extension URL {
    var isLoopback: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
