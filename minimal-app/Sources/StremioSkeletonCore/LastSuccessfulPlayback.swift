import CryptoKit
import Foundation

public enum PlaybackContentKind: String, Codable, Hashable, Sendable {
    case movie
    case episode
}

/// Stable catalog identity used to scope playback preferences. This deliberately
/// contains no stream URL so a refreshed provider response is always required.
public struct PlaybackContentIdentity: Codable, Hashable, Sendable {
    public let kind: PlaybackContentKind
    public let catalogID: String
    public let videoID: String?

    public init?(
        kind: PlaybackContentKind,
        catalogID: String,
        videoID: String? = nil
    ) {
        guard let catalogID = Self.normalizedIdentifier(catalogID) else { return nil }
        let normalizedVideoID = videoID.flatMap(Self.normalizedIdentifier)
        guard kind != .episode || normalizedVideoID != nil else { return nil }
        self.kind = kind
        self.catalogID = catalogID
        self.videoID = normalizedVideoID
    }

    public static func movie(catalogID: String) -> Self? {
        Self(kind: .movie, catalogID: catalogID)
    }

    public static func episode(seriesID: String, videoID: String) -> Self? {
        Self(kind: .episode, catalogID: seriesID, videoID: videoID)
    }

    public var storageKey: String {
        switch kind {
        case .movie:
            "movie:\(catalogID)"
        case .episode:
            "series:\(catalogID):episode:\(videoID ?? "")"
        }
    }

    private static func normalizedIdentifier(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= 256,
              !TransientPlaybackValueDetector.looksTransient(normalized)
        else { return nil }
        return normalized
    }
}

/// Opaque provider and stream fingerprints. The initializer accepts only
/// stable metadata; playback URLs, query strings, account tokens and raw
/// torrent hashes are never written to preferences.
public struct PlaybackStreamPreferenceKey: Codable, Hashable, Sendable {
    public let providerKey: String
    public let streamKey: String?

    public init?(
        providerName: String?,
        streamName: String?,
        streamTitle: String?,
        torrentInfoHash: String? = nil,
        fileIndex: Int? = nil
    ) {
        guard let providerName = Self.stableText(providerName) else { return nil }
        providerKey = "provider-sha256:\(Self.digest(providerName))"

        var stableParts = [String]()
        if let torrentInfoHash = Self.normalizedInfoHash(torrentInfoHash) {
            stableParts.append("torrent:\(torrentInfoHash)")
            if let fileIndex, fileIndex >= 0 {
                stableParts.append("file:\(fileIndex)")
            }
        }
        if let streamName = Self.stableText(streamName) {
            stableParts.append("name:\(streamName)")
        }
        if let streamTitle = Self.stableText(streamTitle) {
            stableParts.append("title:\(streamTitle)")
        }
        streamKey = stableParts.isEmpty
            ? nil
            : "stream-sha256:\(Self.digest(stableParts.joined(separator: "|")))"
    }

    private static func stableText(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
        guard !normalized.isEmpty,
              normalized.count <= 320,
              !TransientPlaybackValueDetector.looksTransient(normalized)
        else { return nil }
        return normalized
    }

    private static func normalizedInfoHash(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard (32...64).contains(normalized.count),
              normalized.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              })
        else { return nil }
        return normalized
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct LastSuccessfulPlaybackPreference: Codable, Equatable, Sendable {
    public let identity: PlaybackContentIdentity
    public let providerKey: String
    public let streamKey: String?
    public let succeededAt: Date

    public init(
        identity: PlaybackContentIdentity,
        key: PlaybackStreamPreferenceKey,
        succeededAt: Date = Date()
    ) {
        self.identity = identity
        providerKey = key.providerKey
        streamKey = key.streamKey
        self.succeededAt = succeededAt
    }
}

/// Small, bounded preference store. It remembers only opaque fingerprints and
/// never owns a resolved stream, URL or provider token.
public final class LastSuccessfulPlaybackPreferenceStore: @unchecked Sendable {
    public static let shared = LastSuccessfulPlaybackPreferenceStore()
    public static let defaultStorageKey = "lastSuccessfulPlaybackPreferences.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    private let capacity: Int
    private let maxAge: TimeInterval
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = defaultStorageKey,
        capacity: Int = 96,
        maxAge: TimeInterval = 90 * 24 * 60 * 60
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.capacity = max(capacity, 1)
        self.maxAge = max(maxAge, 0)
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970
    }

    public func preference(
        for identity: PlaybackContentIdentity,
        now: Date = Date()
    ) -> LastSuccessfulPlaybackPreference? {
        withLock {
            let current = loadPruned(now: now)
            persist(current)
            return current.first { $0.identity == identity }
        }
    }

    @discardableResult
    public func recordSuccess(
        identity: PlaybackContentIdentity,
        key: PlaybackStreamPreferenceKey,
        at date: Date = Date()
    ) -> LastSuccessfulPlaybackPreference {
        withLock {
            let preference = LastSuccessfulPlaybackPreference(
                identity: identity,
                key: key,
                succeededAt: date
            )
            var current = loadPruned(now: date)
            current.removeAll { $0.identity == identity }
            current.insert(preference, at: 0)
            if current.count > capacity {
                current.removeLast(current.count - capacity)
            }
            persist(current)
            return preference
        }
    }

    public func remove(for identity: PlaybackContentIdentity) {
        withLock {
            var current = loadPruned(now: Date())
            current.removeAll { $0.identity == identity }
            persist(current)
        }
    }

    public func removeAll() {
        withLock { defaults.removeObject(forKey: storageKey) }
    }

    private func loadPruned(now: Date) -> [LastSuccessfulPlaybackPreference] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? decoder.decode(
                  [LastSuccessfulPlaybackPreference].self,
                  from: data
              )
        else { return [] }
        let cutoff = now.addingTimeInterval(-maxAge)
        var seen = Set<PlaybackContentIdentity>()
        return decoded
            .filter { maxAge == 0 || $0.succeededAt >= cutoff }
            .sorted { $0.succeededAt > $1.succeededAt }
            .filter { seen.insert($0.identity).inserted }
            .prefix(capacity)
            .map { $0 }
    }

    private func persist(_ values: [LastSuccessfulPlaybackPreference]) {
        guard !values.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? encoder.encode(values) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

public enum LastSuccessfulPlaybackRanker {
    /// Promotes the last proven stream for this exact movie or episode, then a
    /// same-provider candidate, while preserving the caller's ranked order for
    /// every remaining failover.
    public static func rank<C>(
        _ candidates: [C],
        identity: PlaybackContentIdentity,
        preference: LastSuccessfulPlaybackPreference?,
        key: (C) -> PlaybackStreamPreferenceKey?
    ) -> [C] {
        guard let preference, preference.identity == identity else {
            return candidates
        }
        return candidates.enumerated().sorted { lhs, rhs in
            let lhsScore = score(key(lhs.element), preference: preference)
            let rhsScore = score(key(rhs.element), preference: preference)
            return lhsScore == rhsScore ? lhs.offset < rhs.offset : lhsScore < rhsScore
        }.map(\.element)
    }

    private static func score(
        _ key: PlaybackStreamPreferenceKey?,
        preference: LastSuccessfulPlaybackPreference
    ) -> Int {
        guard let key, key.providerKey == preference.providerKey else { return 2 }
        guard let preferredStream = preference.streamKey else { return 0 }
        return key.streamKey == preferredStream ? 0 : 1
    }
}

private enum TransientPlaybackValueDetector {
    static func looksTransient(_ value: String) -> Bool {
        let normalized = value.lowercased()
        if normalized.contains("://") || normalized.contains("?") { return true }
        let sensitiveMarkers = [
            "authorization", "bearer ", "token=", "access_token", "auth=",
            "signature=", "expires=", "x-amz-", "x-goog-", "apikey",
            "api_key", "session=", "jwt=",
        ]
        return sensitiveMarkers.contains(where: normalized.contains)
    }
}
