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

struct TVPresentedStream: Identifiable {
  let id: String
  let providerName: String
  let stream: Stream
  let quality: String?
  let size: String?
  let playbackPriority: Int

  private static let qualityExpression = try! NSRegularExpression(
    pattern: #"(?:4320P|8K|2160P|4K|1080P|720P|480P)"#,
    options: [.caseInsensitive]
  )
  private static let sizeExpression = try! NSRegularExpression(
    pattern: #"(?<![A-Z0-9])(\d+(?:\.\d+)?)\s*(TB|GB|MB)(?![A-Z0-9])"#,
    options: [.caseInsensitive]
  )

  init(id: String, providerName: String, stream: Stream) {
    self.id = id
    self.providerName = providerName
    self.stream = stream

    let metadata = [stream.title, stream.name, stream.description]
      .compactMap { $0 }
      .joined(separator: " ")
    let uppercased = metadata.uppercased()
    let rawQuality = Self.firstMatch(Self.qualityExpression, in: metadata)?.uppercased()
    quality =
      switch rawQuality {
      case "4320P", "8K": "8K"
      case "2160P", "4K": "4K"
      case let value?: value
      case nil: nil
      }
    size = Self.firstMatch(Self.sizeExpression, in: metadata)?
      .uppercased()
      .replacingOccurrences(of: " ", with: " ")

    var score = metadata.contains("⚡") ? -1_000 : 0
    if uppercased.contains("4320P") || uppercased.contains("8K") {
      score += 300
    } else if uppercased.contains("2160P") || uppercased.contains("4K") {
      score -= 180
    } else if uppercased.contains("1080P") {
      score -= 140
    } else if uppercased.contains("720P") {
      score -= 80
    }
    if uppercased.contains("CAM") || uppercased.contains("TELESYNC") {
      score += 1_000
    }
    playbackPriority = score
  }

  private static func firstMatch(
    _ expression: NSRegularExpression,
    in text: String
  ) -> String? {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = expression.firstMatch(in: text, range: range),
      let swiftRange = Range(match.range, in: text)
    else { return nil }
    return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

func tvRankedStreams(from providers: [StreamProviderGroup]) -> [TVPresentedStream] {
  providers.flatMap { provider in
    provider.streams.enumerated().map { index, stream in
      TVPresentedStream(
        id: "\(provider.id)#\(index)#\(stream.id)",
        providerName: provider.name,
        stream: stream
      )
    }
  }
  .filter { $0.stream.isDirectlyPlayable || $0.stream.isTorrent }
  .sorted {
    if $0.playbackPriority != $1.playbackPriority {
      return $0.playbackPriority < $1.playbackPriority
    }
    return $0.id < $1.id
  }
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
