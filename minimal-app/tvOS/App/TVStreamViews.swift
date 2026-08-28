import SwiftUI

struct TVStreamShelf: View {
  let streams: [TVPresentedStream]
  let onSelect: (TVPresentedStream) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(alignment: .top, spacing: 28) {
        ForEach(streams) { stream in
          Button {
            onSelect(stream)
          } label: {
            TVStreamCard(stream: stream)
          }
          .buttonStyle(.card)
          .accessibilityIdentifier("tvos-stream-\(stream.id)")
        }
      }
      .padding(.horizontal, TVTheme.horizontalInset)
      .padding(.vertical, 20)
    }
    .focusSection()
  }
}

struct TVStreamCard: View {
  let stream: TVPresentedStream

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        if let quality = stream.quality {
          badge(quality, systemImage: "tv")
        }
        if let size = stream.size {
          badge(size, systemImage: "externaldrive")
        }
        if stream.stream.isTorrent {
          badge("Torrent", systemImage: "arrow.down.circle")
        }
      }

      Text(stream.stream.displayName.firstLine)
        .font(.title3.weight(.semibold))
        .lineLimit(2)
      Text(stream.providerName)
        .font(.headline)
        .foregroundStyle(TVTheme.accent)
        .lineLimit(1)
      if let description = stream.stream.description?.firstLine,
        description != stream.stream.displayName.firstLine
      {
        Text(description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .frame(width: 420, height: 170, alignment: .topLeading)
    .padding(24)
    .background(TVTheme.elevated, in: RoundedRectangle(cornerRadius: 20))
  }

  private func badge(_ text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.caption.weight(.bold))
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(TVTheme.accent.opacity(0.18), in: Capsule())
      .foregroundStyle(TVTheme.accent)
  }
}

struct TVEpisodeStreamsView: View {
  @EnvironmentObject private var model: AppModel
  let series: MetaItem
  let episode: Video

  @State private var providers: [StreamProviderGroup] = []
  @State private var isLoading = true
  @State private var playbackRequest: TVPlaybackRequest?

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      VStack(alignment: .leading, spacing: 42) {
        HStack(alignment: .top, spacing: 38) {
          TVRemoteImage(
            url: episode.thumbnail ?? series.background ?? series.poster,
            systemImage: "play.rectangle"
          )
          .frame(width: 520, height: 292)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

          VStack(alignment: .leading, spacing: 16) {
            Text(location)
              .font(.headline)
              .foregroundStyle(TVTheme.accent)
            Text(episode.title ?? series.name)
              .font(.system(size: 50, weight: .bold))
              .lineLimit(2)
            if let overview = episode.overview, !overview.isEmpty {
              Text(overview)
                .font(.title3)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            }
            if let progress = model.episodeProgress(episode, in: series) {
              Label(
                "Resume from \(Int(progress.position) / 60)m",
                systemImage: "play.circle"
              )
              .font(.headline)
            }
          }
        }

        TVSectionTitle(
          "Choose a Stream",
          subtitle: "If one source fails, Bunny automatically tries the next ranked source"
        )

        if isLoading {
          HStack(spacing: 18) {
            ProgressView()
              .controlSize(.large)
            Text("Checking installed providers…")
              .font(.title2)
          }
          .frame(maxWidth: .infinity, minHeight: 260)
        } else if rankedStreams.isEmpty {
          TVEmptyState(
            title: "No episode streams",
            message: "No installed add-on returned a playable source for this episode.",
            systemImage: "play.slash"
          )
        } else {
          TVStreamShelf(streams: Array(rankedStreams.prefix(40))) { selected in
            playbackRequest = makeRequest(selectedID: selected.id)
          }
          .padding(.horizontal, -TVTheme.horizontalInset)
        }
      }
      .padding(.horizontal, TVTheme.horizontalInset)
      .padding(.top, 52)
      .padding(.bottom, 90)
    }
    .background(TVTheme.background)
    .task(id: episode.id) {
      isLoading = true
      providers = await model.streamProviders(for: series, videoID: episode.id)
      isLoading = false
    }
    .fullScreenCover(item: $playbackRequest) { request in
      TVResolvingPlayerView(request: request)
        .environmentObject(model)
    }
    .navigationTitle(series.name)
    .accessibilityIdentifier("tvos-episode-streams")
  }

  private var rankedStreams: [TVPresentedStream] {
    tvRankedStreams(from: providers)
  }

  private var location: String {
    let season = episode.season ?? 0
    let number = episode.episode ?? 0
    return season == 0 ? "Special \(number)" : "Season \(season), Episode \(number)"
  }

  private func makeRequest(selectedID: String) -> TVPlaybackRequest? {
    TVPlaybackRequest.selected(
      selectedID,
      from: rankedStreams,
      contentIdentity: .episode(seriesID: series.id, videoID: episode.id),
      contentIdentifier: model.episodeContentIdentifier(episode, in: series),
      contentTitle: model.episodeContentTitle(episode, in: series),
      initialPosition: model.episodeProgress(episode, in: series)?.position ?? 0,
      mediaMetadata: .episode(series: series, episode: episode)
    )
  }
}

extension String {
  fileprivate var firstLine: String {
    split(separator: "\n", maxSplits: 1).first.map(String.init) ?? self
  }
}
