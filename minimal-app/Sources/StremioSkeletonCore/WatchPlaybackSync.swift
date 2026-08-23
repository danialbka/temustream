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
    public let counter: Int64
    public let actorID: String

    public init(counter: Int64, actorID: String) {
        self.counter = max(counter, 0)
        self.actorID = actorID
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

    public func projectedPosition(at nowMilliseconds: Int64) -> TimeInterval {
        guard isPlaying else { return position }
        let elapsed = min(max(Double(nowMilliseconds - sentAtMilliseconds) / 1_000, 0), 30)
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
        lamportCounter = max(lamportCounter, lastAppliedVersion?.counter ?? 0) + 1
        let version = WatchPlaybackVersion(counter: lamportCounter, actorID: actorID)
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
        lamportCounter = max(lamportCounter, remote.version.counter)
        if let lastAppliedVersion, remote.version <= lastAppliedVersion { return nil }
        lastAppliedVersion = remote.version

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
