import Foundation

public enum WatchStreamKind: String, Codable, Equatable, Sendable {
    case hls
    case directFile
    case negotiatedHTTPS

    public var displayName: String {
        switch self {
        case .hls:
            "HLS"
        case .directFile:
            "Direct video"
        case .negotiatedHTTPS:
            "HTTPS stream"
        }
    }
}

public enum WatchStreamIncompatibility: Equatable, Sendable {
    case missingDirectURL
    case insecureTransport
    case embeddedCredentials
    case torrent
    case externalOnly
    case unsupportedContainer(String)
    case requiresCompatibilityPlayer
    case untrustedStreamingServerOutput

    public var message: String {
        switch self {
        case .missingDirectURL:
            "This source does not include a direct playback URL."
        case .insecureTransport:
            "Apple Watch playback requires an HTTPS stream."
        case .embeddedCredentials:
            "URLs with embedded usernames or passwords are not accepted."
        case .torrent:
            "Torrent sources need a streaming server and cannot play directly on Apple Watch."
        case .externalOnly:
            "External-app links cannot be opened by the watch player."
        case let .unsupportedContainer(container):
            "The \(container.uppercased()) container is not supported by the watch player."
        case .requiresCompatibilityPlayer:
            "This source needs transcoding or a desktop-class compatibility player."
        case .untrustedStreamingServerOutput:
            "The streaming server returned a playback URL from an unexpected origin."
        }
    }
}

public struct WatchStreamAssessment: Equatable, Sendable {
    public let playbackURL: URL?
    public let kind: WatchStreamKind?
    public let incompatibility: WatchStreamIncompatibility?

    public init(
        playbackURL: URL?,
        kind: WatchStreamKind?,
        incompatibility: WatchStreamIncompatibility?
    ) {
        self.playbackURL = playbackURL
        self.kind = kind
        self.incompatibility = incompatibility
    }

    public var isPlayable: Bool {
        playbackURL != nil && kind != nil && incompatibility == nil
    }
}

public enum WatchStreamCompatibility {
    private static let directFileExtensions = Set(["m4v", "mov", "mp4"])
    private static let unsupportedExtensions = Set([
        "avi", "flv", "mkv", "mpd", "webm", "wmv",
    ])

    public static func assess(_ stream: Stream) -> WatchStreamAssessment {
        guard let url = stream.url else {
            if stream.isTorrent {
                return rejected(.torrent)
            }
            if stream.externalUrl != nil {
                return rejected(.externalOnly)
            }
            return rejected(.missingDirectURL)
        }

        let transport = assess(url: url)
        guard transport.isPlayable else { return transport }
        guard !stream.isTorrent else { return rejected(.torrent) }
        guard !stream.prefersCompatibilityPlayback else {
            return rejected(.requiresCompatibilityPlayer)
        }
        return transport
    }

    public static func assess(url: URL) -> WatchStreamAssessment {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            return rejected(.insecureTransport)
        }
        guard url.user == nil, url.password == nil else {
            return rejected(.embeddedCredentials)
        }

        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "m3u8" {
            return WatchStreamAssessment(
                playbackURL: url,
                kind: .hls,
                incompatibility: nil
            )
        }
        if directFileExtensions.contains(pathExtension) {
            return WatchStreamAssessment(
                playbackURL: url,
                kind: .directFile,
                incompatibility: nil
            )
        }
        if unsupportedExtensions.contains(pathExtension) {
            return rejected(.unsupportedContainer(pathExtension))
        }
        return WatchStreamAssessment(
            playbackURL: url,
            kind: .negotiatedHTTPS,
            incompatibility: nil
        )
    }

    /// Validates the HLS URL produced by a user-configured streaming server.
    /// Private-network HTTP remains limited to that exact configured origin;
    /// arbitrary insecure provider URLs are still rejected by `assess(url:)`.
    public static func assessStreamingServerURL(
        _ url: URL,
        endpoint: StreamingServerEndpoint
    ) -> WatchStreamAssessment {
        guard url.user == nil,
              url.password == nil,
              sameOrigin(url, endpoint.baseURL),
              url.pathExtension.lowercased() == "m3u8"
        else { return rejected(.untrustedStreamingServerOutput) }

        return WatchStreamAssessment(
            playbackURL: url,
            kind: .hls,
            incompatibility: nil
        )
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lhsScheme = lhs.scheme?.lowercased(),
              let rhsScheme = rhs.scheme?.lowercased(),
              let lhsHost = lhs.host?.lowercased(),
              let rhsHost = rhs.host?.lowercased()
        else { return false }
        return lhsScheme == rhsScheme
            && lhsHost == rhsHost
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func rejected(
        _ reason: WatchStreamIncompatibility
    ) -> WatchStreamAssessment {
        WatchStreamAssessment(
            playbackURL: nil,
            kind: nil,
            incompatibility: reason
        )
    }
}
