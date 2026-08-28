/// Media-packet classes used to decide whether a completed read remains valid
/// while switching one selected track.
public enum PlaybackPacketTrackKind: Sendable {
    case video
    case audio
    case subtitle
    case other
}

/// Prevents track selection from dropping an unrelated completed packet. In
/// particular, switching to a preferred audio language must not throw away the
/// first video keyframe already returned by the demuxer.
public enum PlaybackTrackSelectionPacketPolicy {
    public static func preservesCompletedPacket(
        kind: PlaybackPacketTrackKind,
        audioSelectionChanged: Bool,
        subtitleSelectionChanged: Bool
    ) -> Bool {
        switch kind {
        case .audio:
            return !audioSelectionChanged
        case .subtitle:
            return !subtitleSelectionChanged
        case .video, .other:
            return true
        }
    }
}
