import Foundation

/// A stream source retained only for the lifetime of an active watch playback
/// session. Callers must not persist this value because provider URLs can carry
/// short-lived authorization material.
public struct WatchPlaybackSource: Identifiable, Equatable, Hashable, Sendable {
    public let providerName: String
    public let stream: Stream

    public init(providerName: String, stream: Stream) {
        self.providerName = providerName
        self.stream = stream
    }

    public var id: String {
        "\(providerName)|\(stream.id)"
    }
}

public enum WatchPlaybackFallbackPolicy {
    /// Places the explicitly chosen source first while preserving provider
    /// order for all remaining sources and removing duplicate identities.
    public static func ordered(
        sources: [WatchPlaybackSource],
        selectedSourceID: String
    ) -> [WatchPlaybackSource] {
        var seen = Set<String>()
        let unique = sources.filter { seen.insert($0.id).inserted }
        guard let selected = unique.first(where: { $0.id == selectedSourceID })
        else { return unique }
        return [selected] + unique.filter { $0.id != selectedSourceID }
    }

    public static func nextIndex(after currentIndex: Int, sourceCount: Int) -> Int? {
        guard currentIndex >= 0, sourceCount > 0 else { return nil }
        let nextIndex = currentIndex + 1
        return nextIndex < sourceCount ? nextIndex : nil
    }
}
