import Foundation

public enum WatchVoiceControlState: String, Codable, Equatable, Sendable {
    case off
    case enabling
    case live
    case denied
    case unavailable

    public var isCapturing: Bool { self == .live }

    public var statusText: String {
        switch self {
        case .off: "Microphone off"
        case .enabling: "Starting microphone…"
        case .live: "Microphone live"
        case .denied: "Microphone permission denied"
        case .unavailable: "Voice unavailable"
        }
    }

    public var controlText: String {
        switch self {
        case .off: "Muted"
        case .enabling: "Starting"
        case .live: "Live"
        case .denied: "Denied"
        case .unavailable: "Offline"
        }
    }

    public func canToggle(roomConnected: Bool) -> Bool {
        roomConnected && self != .enabling && self != .denied && self != .unavailable
    }
}

public struct WatchPlaybackVersion: Codable, Equatable, Hashable, Sendable, Comparable {
    /// Convex persists this value as a float64. Keep every accepted peer
    /// counter exactly representable and reserve the next exact integer for a
    /// local event that must advance beyond it.
    public static let maximumPeerCounter: Int64 = 9_007_199_254_740_990
    fileprivate static let maximumLocalCounter = maximumPeerCounter + 1

    public let counter: Int64
    public let actorID: String

    public init(counter: Int64, actorID: String) {
        self.counter = min(max(counter, 0), Self.maximumPeerCounter)
        self.actorID = actorID
    }

    fileprivate init(localCounter: Int64, actorID: String) {
        counter = min(max(localCounter, 0), Self.maximumLocalCounter)
        self.actorID = actorID
    }

    private enum CodingKeys: String, CodingKey {
        case counter
        case actorID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCounter = try container.decode(Int64.self, forKey: .counter)
        let decodedActorID = try container.decode(String.self, forKey: .actorID)

        // The one reserved successor is a legitimate value produced by this
        // client and must survive its wire round trip. Values beyond that
        // protocol domain are untrusted peer input and normalize through the
        // public initializer, leaving the successor available locally.
        if decodedCounter == Self.maximumLocalCounter {
            self.init(localCounter: decodedCounter, actorID: decodedActorID)
        } else {
            self.init(counter: decodedCounter, actorID: decodedActorID)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(counter, forKey: .counter)
        try container.encode(actorID, forKey: .actorID)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.actorID < rhs.actorID
    }
}

public enum WatchPlaybackEventKind: String, Codable, Equatable, Sendable {
    case play
    case pause
    case seek
    case heartbeat
}

public struct WatchPlaybackEvent: Codable, Equatable, Sendable {
    public let eventID: UUID
    public let contentKey: String
    public let kind: WatchPlaybackEventKind
    public let position: TimeInterval
    public let isPlaying: Bool
    public let rate: Double
    public let version: WatchPlaybackVersion
    public let sentAtMilliseconds: Int64

    public init(
        eventID: UUID = UUID(),
        contentKey: String,
        kind: WatchPlaybackEventKind,
        position: TimeInterval,
        isPlaying: Bool,
        rate: Double,
        version: WatchPlaybackVersion,
        sentAtMilliseconds: Int64
    ) {
        self.eventID = eventID
        self.contentKey = contentKey
        self.kind = kind
        self.position = max(position.isFinite ? position : 0, 0)
        self.isPlaying = isPlaying
        self.rate = min(max(rate.isFinite ? rate : 1, 0.25), 4)
        self.version = version
        self.sentAtMilliseconds = sentAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case eventID
        case contentKey
        case kind
        case position
        case isPlaying
        case rate
        case version
        case sentAtMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            eventID: try container.decode(UUID.self, forKey: .eventID),
            contentKey: try container.decode(String.self, forKey: .contentKey),
            kind: try container.decode(WatchPlaybackEventKind.self, forKey: .kind),
            position: try container.decode(TimeInterval.self, forKey: .position),
            isPlaying: try container.decode(Bool.self, forKey: .isPlaying),
            rate: try container.decode(Double.self, forKey: .rate),
            version: try container.decode(WatchPlaybackVersion.self, forKey: .version),
            sentAtMilliseconds: try container.decode(Int64.self, forKey: .sentAtMilliseconds)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(contentKey, forKey: .contentKey)
        try container.encode(kind, forKey: .kind)
        try container.encode(position, forKey: .position)
        try container.encode(isPlaying, forKey: .isPlaying)
        try container.encode(rate, forKey: .rate)
        try container.encode(version, forKey: .version)
        try container.encode(sentAtMilliseconds, forKey: .sentAtMilliseconds)
    }

    public func projectedPosition(at nowMilliseconds: Int64) -> TimeInterval {
        guard isPlaying else { return position }
        let elapsedMilliseconds = Double(nowMilliseconds) - Double(sentAtMilliseconds)
        let elapsed = min(max(elapsedMilliseconds / 1_000, 0), 30)
        return position + elapsed * rate
    }
}

public struct WatchLocalPlaybackSample: Equatable, Sendable {
    public let position: TimeInterval
    public let isPlaying: Bool
    public let rate: Double

    public init(position: TimeInterval, isPlaying: Bool, rate: Double) {
        self.position = max(position.isFinite ? position : 0, 0)
        self.isPlaying = isPlaying
        self.rate = min(max(rate.isFinite ? rate : 1, 0.25), 4)
    }
}

public struct WatchPlaybackAdjustment: Equatable, Sendable {
    public let targetPosition: TimeInterval?
    public let shouldPlay: Bool?
    public let playbackRate: Double?
    public let temporaryRate: Double?
    public let temporaryRateDuration: TimeInterval

    public init(
        targetPosition: TimeInterval? = nil,
        shouldPlay: Bool? = nil,
        playbackRate: Double? = nil,
        temporaryRate: Double? = nil,
        temporaryRateDuration: TimeInterval = 0
    ) {
        self.targetPosition = targetPosition
        self.shouldPlay = shouldPlay
        self.playbackRate = playbackRate
        self.temporaryRate = temporaryRate
        self.temporaryRateDuration = temporaryRateDuration
    }

    public var hasChanges: Bool {
        targetPosition != nil || shouldPlay != nil || playbackRate != nil || temporaryRate != nil
    }
}

/// Lamport-versioned playback reconciliation shared by every player surface.
/// Remote versions are observed before the next local event is issued, so a
/// participant can always advance beyond a peer with a previously higher counter.
public struct WatchPlaybackReconciler: Sendable {
    public private(set) var lamportCounter: Int64
    public private(set) var lastAppliedVersion: WatchPlaybackVersion?
    private let actorID: String

    public init(actorID: String, initialVersion: WatchPlaybackVersion? = nil) {
        self.actorID = actorID
        self.lastAppliedVersion = initialVersion
        self.lamportCounter = initialVersion?.counter ?? 0
    }

    public mutating func makeLocalEvent(
        contentKey: String,
        kind: WatchPlaybackEventKind,
        sample: WatchLocalPlaybackSample,
        nowMilliseconds: Int64
    ) -> WatchPlaybackEvent {
        let observedCounter = max(lamportCounter, lastAppliedVersion?.counter ?? 0)
        lamportCounter = observedCounter >= WatchPlaybackVersion.maximumLocalCounter
            ? WatchPlaybackVersion.maximumLocalCounter
            : observedCounter + 1
        let version = WatchPlaybackVersion(localCounter: lamportCounter, actorID: actorID)
        lastAppliedVersion = version
        return WatchPlaybackEvent(
            contentKey: contentKey,
            kind: kind,
            position: sample.position,
            isPlaying: sample.isPlaying,
            rate: sample.rate,
            version: version,
            sentAtMilliseconds: nowMilliseconds
        )
    }

    public mutating func reconcile(
        remote: WatchPlaybackEvent,
        local: WatchLocalPlaybackSample,
        nowMilliseconds: Int64
    ) -> WatchPlaybackAdjustment? {
        let observedVersion = WatchPlaybackVersion(
            counter: remote.version.counter,
            actorID: remote.version.actorID
        )
        lamportCounter = max(lamportCounter, observedVersion.counter)
        if let lastAppliedVersion, observedVersion <= lastAppliedVersion { return nil }
        lastAppliedVersion = observedVersion

        let target = remote.projectedPosition(at: nowMilliseconds)
        let drift = target - local.position
        let stateChanged = remote.isPlaying != local.isPlaying
        let rateChanged = abs(remote.rate - local.rate) >= 0.02

        if stateChanged || abs(drift) >= 0.75 {
            return WatchPlaybackAdjustment(
                targetPosition: abs(drift) >= 0.20 ? target : nil,
                shouldPlay: stateChanged ? remote.isPlaying : nil,
                playbackRate: rateChanged ? remote.rate : nil
            )
        }

        if rateChanged {
            return WatchPlaybackAdjustment(playbackRate: remote.rate)
        }

        if remote.isPlaying, abs(drift) >= 0.18 {
            let direction = drift > 0 ? 1.03 : 0.97
            return WatchPlaybackAdjustment(
                temporaryRate: min(max(remote.rate * direction, 0.25), 4),
                temporaryRateDuration: min(max(abs(drift) * 0.8, 0.4), 1.5)
            )
        }

        return WatchPlaybackAdjustment()
    }
}
