import Foundation

struct TVMediaRoute: Hashable {
  let item: MetaItem
  let preferredManifestURL: URL?

  init(item: MetaItem, preferredManifestURL: URL? = nil) {
    self.item = item
    self.preferredManifestURL = preferredManifestURL
  }
}

struct TVEpisodeRoute: Hashable {
  let series: MetaItem
  let episode: Video
}

typealias TVPresentedStream = PresentedStream

func tvRankedStreams(
  from providers: [StreamProviderGroup],
  mode: StreamRankingMode = .current
) -> [TVPresentedStream] {
  let presented = providers.flatMap { provider in
    provider.streams.enumerated().map { index, stream in
      TVPresentedStream(
        id: "\(provider.id)#\(index)#\(stream.id)",
        providerID: provider.id,
        providerName: provider.name,
        stream: stream
      )
    }
  }
  .filter { $0.stream.isDirectlyPlayable || $0.stream.isTorrent }

  return StreamPresentationPolicy.ranked(presented, mode: mode)
}

struct TVPlaybackCandidate: Identifiable {
  let id: String
  let stream: Stream
  let providerName: String

  var preferenceKey: PlaybackStreamPreferenceKey? {
    PlaybackStreamPreferenceKey(
      providerName: providerName,
      streamName: stream.name,
      streamTitle: stream.title,
      torrentInfoHash: stream.infoHash,
      fileIndex: stream.fileIdx
    )
  }
}

struct TVPlaybackRequest: Identifiable {
  let id = UUID()
  let candidates: [TVPlaybackCandidate]
  let contentIdentity: PlaybackContentIdentity?
  let contentIdentifier: String
  let contentTitle: String
  let initialPosition: TimeInterval
  let mediaMetadata: PlaybackMediaMetadata

  static func selected(
    _ selectedID: String,
    from streams: [TVPresentedStream],
    contentIdentity: PlaybackContentIdentity?,
    contentIdentifier: String,
    contentTitle: String,
    initialPosition: TimeInterval,
    mediaMetadata: PlaybackMediaMetadata
  ) -> Self? {
    guard let selectedIndex = streams.firstIndex(where: { $0.id == selectedID }) else {
      return nil
    }
    let ordered = Array(streams[selectedIndex...]) + Array(streams[..<selectedIndex])
    return make(
      streams: ordered,
      contentIdentity: contentIdentity,
      contentIdentifier: contentIdentifier,
      contentTitle: contentTitle,
      initialPosition: initialPosition,
      mediaMetadata: mediaMetadata,
      preferLastSuccess: false
    )
  }

  static func oneTap(
    streams: [TVPresentedStream],
    contentIdentity: PlaybackContentIdentity?,
    contentIdentifier: String,
    contentTitle: String,
    initialPosition: TimeInterval,
    mediaMetadata: PlaybackMediaMetadata
  ) -> Self? {
    make(
      streams: streams,
      contentIdentity: contentIdentity,
      contentIdentifier: contentIdentifier,
      contentTitle: contentTitle,
      initialPosition: initialPosition,
      mediaMetadata: mediaMetadata,
      preferLastSuccess: true
    )
  }

  private static func make(
    streams: [TVPresentedStream],
    contentIdentity: PlaybackContentIdentity?,
    contentIdentifier: String,
    contentTitle: String,
    initialPosition: TimeInterval,
    mediaMetadata: PlaybackMediaMetadata,
    preferLastSuccess: Bool
  ) -> Self? {
    var candidates = streams.map {
      TVPlaybackCandidate(
        id: $0.id,
        stream: $0.stream,
        providerName: $0.providerName
      )
    }
    guard !candidates.isEmpty else { return nil }
    if preferLastSuccess, let contentIdentity {
      candidates = LastSuccessfulPlaybackRanker.rank(
        candidates,
        identity: contentIdentity,
        preference: LastSuccessfulPlaybackPreferenceStore.shared.preference(
          for: contentIdentity
        ),
        key: \TVPlaybackCandidate.preferenceKey
      )
    }
    return Self(
      candidates: candidates,
      contentIdentity: contentIdentity,
      contentIdentifier: contentIdentifier,
      contentTitle: contentTitle,
      initialPosition: max(initialPosition, 0),
      mediaMetadata: mediaMetadata
    )
  }
}
