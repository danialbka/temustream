import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum StreamingServerError: LocalizedError, Equatable {
    case invalidServerURL
    case unavailable
    case invalidInfoHash
    case invalidResponse
    case httpStatus(Int)
    case compatibilityPlaybackUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "Use HTTPS, localhost, or a private-network streaming-server URL."
        case .unavailable:
            "The torrent streaming server is offline."
        case .invalidInfoHash:
            "The add-on returned an invalid torrent info hash."
        case .invalidResponse:
            "The torrent streaming server returned an invalid response."
        case let .httpStatus(status):
            "The torrent streaming server returned HTTP \(status)."
        case .compatibilityPlaybackUnavailable:
            "This stream needs the configured streaming server's compatibility converter."
        }
    }
}

public protocol HTTPRequestLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPRequestLoading {}

public struct StreamingServerEndpoint: Equatable, Sendable {
    public let baseURL: URL

    public init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && url.host?.isLocalNetworkHost == true)
        else { throw StreamingServerError.invalidServerURL }
        baseURL = url
    }
}

public struct TorrentStreamingClient: Sendable {
    public let endpoint: StreamingServerEndpoint
    private let loader: any HTTPRequestLoading

    public init(
        endpoint: StreamingServerEndpoint,
        loader: any HTTPRequestLoading = URLSession.shared
    ) {
        self.endpoint = endpoint
        self.loader = loader
    }

    public func isOnline() async -> Bool {
        do {
            let url = endpoint.baseURL.appendingPathComponent("heartbeat")
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            let (_, response) = try await loader.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    public func playbackURL(for stream: Stream) async throws -> URL {
        guard let rawHash = stream.infoHash?.lowercased(),
              rawHash.count == 40,
              rawHash.allSatisfy(\.isHexDigit)
        else { throw StreamingServerError.invalidInfoHash }

        let trackers = (stream.sources ?? []).map { source in
            source.hasPrefix("tracker:") ? String(source.dropFirst("tracker:".count)) : source
        }
        let createURL = endpoint.baseURL
            .appendingPathComponent(rawHash)
            .appendingPathComponent("create")
        let body = CreateTorrentBody(
            peerSearch: .init(sources: ["dht:\(rawHash)"] + trackers.map { "tracker:\($0)" })
        )
        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StreamingServerError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw StreamingServerError.httpStatus(http.statusCode)
        }
        if let failure = try? JSONDecoder().decode(ServerFailure.self, from: data),
           let message = failure.error, !message.isEmpty {
            throw StreamingServerError.unavailable
        }

        let index = stream.fileIdx ?? -1
        var components = URLComponents(
            url: endpoint.baseURL
                .appendingPathComponent(rawHash)
                .appendingPathComponent(String(index)),
            resolvingAgainstBaseURL: false
        )
        if !trackers.isEmpty {
            components?.queryItems = trackers.map { URLQueryItem(name: "tr", value: $0) }
        }
        guard let url = components?.url else { throw StreamingServerError.invalidResponse }
        return url
    }

    /// Creates the Stremio server HLS master-playlist URL used for containers
    /// and codecs that AVPlayer cannot consume directly (for example MKV/AV1).
    public func compatibilityPlaybackURL(
        for mediaURL: URL,
        sessionID: String = UUID().uuidString
    ) async throws -> URL {
        guard let scheme = mediaURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { throw StreamingServerError.compatibilityPlaybackUnavailable }

        let settings = await playbackSettings()
        var components = URLComponents(
            url: endpoint.baseURL
                .appendingPathComponent("hlsv2")
                .appendingPathComponent(sessionID)
                .appendingPathComponent("master.m3u8"),
            resolvingAgainstBaseURL: false
        )
        var queryItems = [
            URLQueryItem(name: "mediaURL", value: mediaURL.absoluteString),
            URLQueryItem(name: "maxAudioChannels", value: "2"),
            URLQueryItem(name: "forceTranscoding", value: "1"),
            URLQueryItem(name: "videoCodecs", value: "h264"),
            URLQueryItem(name: "videoCodecs", value: "hevc"),
            URLQueryItem(name: "audioCodecs", value: "aac"),
            URLQueryItem(name: "audioCodecs", value: "mp3"),
        ]
        if let profile = settings.profile {
            queryItems.append(URLQueryItem(name: "profile", value: profile))
        }
        if let maxWidth = settings.maxWidth {
            queryItems.append(URLQueryItem(name: "maxWidth", value: String(maxWidth)))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw StreamingServerError.compatibilityPlaybackUnavailable
        }
        return url
    }

    private func playbackSettings() async -> PlaybackSettings {
        do {
            let url = endpoint.baseURL.appendingPathComponent("settings")
            var request = URLRequest(url: url)
            request.timeoutInterval = 3
            let (data, response) = try await loader.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let envelope = try? JSONDecoder().decode(ServerSettingsEnvelope.self, from: data)
            else { return .init(profile: nil, maxWidth: 1920) }
            return .init(
                profile: envelope.values.transcodeProfile
                    ?? envelope.values.allTranscodeProfiles?.first,
                maxWidth: envelope.values.transcodeMaxWidth ?? 1920
            )
        } catch {
            return .init(profile: nil, maxWidth: 1920)
        }
    }
}

private struct PlaybackSettings: Sendable {
    let profile: String?
    let maxWidth: Int?
}

private struct ServerSettingsEnvelope: Decodable {
    let values: Values

    struct Values: Decodable {
        let transcodeProfile: String?
        let allTranscodeProfiles: [String]?
        let transcodeMaxWidth: Int?
    }
}

private struct CreateTorrentBody: Encodable {
    let peerSearch: PeerSearch

    struct PeerSearch: Encodable {
        let sources: [String]
    }
}

private struct ServerFailure: Decodable {
    let error: String?
}

private extension String {
    var isLocalNetworkHost: Bool {
        let host = lowercased()
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return true
        }
        if host.hasPrefix("10.") || host.hasPrefix("192.168.") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 172 && (16...31).contains(parts[1])
    }
}
