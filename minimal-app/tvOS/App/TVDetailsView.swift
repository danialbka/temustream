import SwiftUI

private enum TVDetailsActionFocus: Hashable {
  case library
}

struct TVDetailsView: View {
  @EnvironmentObject private var model: AppModel
  let seed: MetaItem
  let preferredManifestURL: URL?

  @AppStorage("stream-ranking-mode") private var streamRankingMode =
    StreamRankingMode.current
  @State private var item: MetaItem
  @State private var movieProviders: [StreamProviderGroup] = []
  @State private var selectedSeason: Int?
  @State private var isLoadingDetails = true
  @State private var isLoadingStreams = false
  @State private var isUpdatingLibrary = false
  @State private var isQuickPlaying = false
  @State private var playbackRequest: TVPlaybackRequest?
  @State private var actionError: String?
  @FocusState private var focusedAction: TVDetailsActionFocus?

  init(seed: MetaItem, preferredManifestURL: URL? = nil) {
    self.seed = seed
    self.preferredManifestURL = preferredManifestURL
    _item = State(initialValue: seed)
  }

  var body: some View {
    ScrollView(.vertical, showsIndicators: false) {
      LazyVStack(alignment: .leading, spacing: 44) {
        hero

        if item.type == "series" {
          episodeSection
        } else {
          movieStreamsSection
        }

        if !relatedTitles.isEmpty {
          TVMediaShelf(
            title: "More Like This",
            items: relatedTitles
          )
        }
      }
      .padding(.bottom, 90)
    }
    .background(TVTheme.background)
    .task(id: seed.id) { await load() }
    .fullScreenCover(item: $playbackRequest) { request in
      TVResolvingPlayerView(request: request)
        .environmentObject(model)
    }
    .alert(
      "Playback unavailable",
      isPresented: Binding(
        get: { actionError != nil },
        set: { if !$0 { actionError = nil } }
      )
    ) {
      Button("OK", role: .cancel) { actionError = nil }
    } message: {
      Text(actionError ?? "No playable streams were found.")
    }
    .accessibilityIdentifier("tvos-details")
  }

  private var hero: some View {
    TVBackdrop(item: item)
      .frame(height: 700)
      .overlay(alignment: .bottomLeading) {
        HStack(alignment: .bottom, spacing: 46) {
          TVRemoteImage(url: item.poster)
            .frame(width: 270, height: 396)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.55), radius: 24, y: 14)

          VStack(alignment: .leading, spacing: 20) {
            if isLoadingDetails {
              ProgressView()
                .controlSize(.large)
            }

            Text(item.name)
              .font(.system(size: 60, weight: .bold))
              .lineLimit(2)

            metadataLine

            if let description = item.description, !description.isEmpty {
              Text(description)
                .font(.title3)
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(3)
                .frame(maxWidth: 1_050, alignment: .leading)
            }

            actionRow

            if !item.actorNames.isEmpty {
              Text("Cast: \(item.actorNames.prefix(6).joined(separator: ", "))")
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
          .frame(maxWidth: 1_160, alignment: .leading)
        }
        .padding(.horizontal, TVTheme.horizontalInset)
        .padding(.bottom, 46)
      }
  }

  private var metadataLine: some View {
    HStack(spacing: 18) {
      if let releaseInfo = item.releaseInfo {
        Text(releaseInfo)
      }
      if let certification = item.certification {
        Text(certification)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .overlay { RoundedRectangle(cornerRadius: 4).stroke(.secondary) }
      }
      if let runtime = item.runtime {
        Label(runtime, systemImage: "clock")
      }
      if let rating = item.imdbRating {
        Label("IMDb \(rating)", systemImage: "star.fill")
          .foregroundStyle(.yellow)
      }
      if let genre = item.genres?.prefix(3).joined(separator: " · "), !genre.isEmpty {
        Text(genre)
      }
    }
    .font(.headline)
    .foregroundStyle(.secondary)
  }

  private var actionRow: some View {
    HStack(spacing: 20) {
      Button {
        Task { await quickPlay() }
      } label: {
        if isQuickPlaying {
          Label("Finding Best Stream…", systemImage: "antenna.radiowaves.left.and.right")
        } else {
          Label(primaryActionTitle, systemImage: "play.fill")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isQuickPlaying || (item.type != "series" && isLoadingStreams))
      .accessibilityIdentifier("tvos-primary-play")

      Button {
        Task {
          isUpdatingLibrary = true
          await model.toggleLibrary(item)
          isUpdatingLibrary = false
        }
      } label: {
        Label(
          isUpdatingLibrary
            ? "Updating…"
            : model.isInLibrary(item) ? "In My List" : "Add to My List",
          systemImage: model.isInLibrary(item) ? "checkmark" : "plus"
        )
        .foregroundStyle(focusedAction == .library ? Color.black : Color.white)
      }
      .buttonStyle(.bordered)
      .focused($focusedAction, equals: .library)
      .disabled(isUpdatingLibrary)
      .accessibilityIdentifier("tvos-library-toggle")

      Menu {
        reactionMenuButton(.dislike, title: "Not for me", systemImage: "hand.thumbsdown")
        reactionMenuButton(.like, title: "I like this", systemImage: "hand.thumbsup")
        reactionMenuButton(.love, title: "Love this", systemImage: "heart")
        if model.mediaReaction(for: item) != nil {
          Divider()
          Button("Clear Rating", systemImage: "xmark.circle") {
            setReaction(nil)
          }
        }
      } label: {
        Label(reactionTitle, systemImage: reactionSystemImage)
          .foregroundStyle(.white)
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("tvos-media-reaction")
    }
  }

  private var reactionTitle: String {
    switch model.mediaReaction(for: item) {
    case .dislike: "Not for me"
    case .like: "Liked"
    case .love: "Loved"
    case nil: "Rate"
    }
  }

  private var reactionSystemImage: String {
    switch model.mediaReaction(for: item) {
    case .dislike: "hand.thumbsdown.fill"
    case .like: "hand.thumbsup.fill"
    case .love: "heart.fill"
    case nil: "hand.thumbsup"
    }
  }

  private func reactionMenuButton(
    _ reaction: MediaReaction,
    title: String,
    systemImage: String
  ) -> some View {
    Button {
      setReaction(model.mediaReaction(for: item) == reaction ? nil : reaction)
    } label: {
      if model.mediaReaction(for: item) == reaction {
        Label(title, systemImage: "checkmark")
      } else {
        Label(title, systemImage: systemImage)
      }
    }
  }

  private func setReaction(_ reaction: MediaReaction?) {
    Task {
      do {
        try await model.setMediaReaction(reaction, for: item)
      } catch {
        actionError = error.localizedDescription
      }
    }
  }

  @ViewBuilder
  private var movieStreamsSection: some View {
    VStack(alignment: .leading, spacing: 20) {
      TVSectionTitle(
        "Choose a Stream",
        subtitle: "The Play button remembers the last provider that worked"
      )
      .padding(.horizontal, TVTheme.horizontalInset)

      if isLoadingStreams {
        HStack(spacing: 18) {
          ProgressView()
            .controlSize(.large)
          Text("Checking installed providers…")
            .font(.title2)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
      } else if rankedMovieStreams.isEmpty {
        TVEmptyState(
          title: "No playable streams",
          message:
            "Install a compatible stream add-on or configure your streaming server in Settings.",
          systemImage: "play.slash"
        )
      } else {
        TVStreamRankingControl(selection: $streamRankingMode)
          .padding(.horizontal, TVTheme.horizontalInset)

        TVStreamShelf(streams: Array(rankedMovieStreams.prefix(30))) { selected in
          playbackRequest = TVPlaybackRequest.selected(
            selected.id,
            from: rankedMovieStreams,
            contentIdentity: .movie(catalogID: item.id),
            contentIdentifier: "\(item.type):\(item.id)",
            contentTitle: item.name,
            initialPosition: model.resumeProgress(for: item)?.position ?? 0,
            mediaMetadata: .movie(item)
          )
        }
      }
    }
  }

  @ViewBuilder
  private var episodeSection: some View {
    VStack(alignment: .leading, spacing: 24) {
      HStack {
        TVSectionTitle(
          "Episodes",
          subtitle: selectedSeason.map(seasonTitle)
        )
        Spacer()
        if let selectedSeason {
          Menu {
            ForEach(availableSeasons, id: \.self) { season in
              Button(seasonTitle(season)) {
                self.selectedSeason = season
                EpisodeSeasonSelectionStore().setSeason(
                  season,
                  for: item.id
                )
              }
            }
          } label: {
            Label(seasonTitle(selectedSeason), systemImage: "chevron.down")
          }
          .buttonStyle(.bordered)
        }
      }
      .padding(.horizontal, TVTheme.horizontalInset)

      if selectedSeasonEpisodes.isEmpty {
        TVEmptyState(
          title: "No episodes",
          message: "This add-on didn’t return episode metadata for the selected season.",
          systemImage: "list.number"
        )
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(alignment: .top, spacing: 32) {
            ForEach(selectedSeasonEpisodes) { episode in
              NavigationLink {
                TVEpisodeStreamsView(series: item, episode: episode)
              } label: {
                TVEpisodeCard(
                  episode: episode,
                  progress: model.episodeProgress(episode, in: item),
                  isCompleted: model.isEpisodeCompleted(episode, in: item)
                )
              }
              .buttonStyle(.card)
            }
          }
          .padding(.horizontal, TVTheme.horizontalInset)
          .padding(.vertical, 20)
        }
        .focusSection()
      }
    }
  }

  private var rankedMovieStreams: [TVPresentedStream] {
    tvRankedStreams(from: movieProviders, mode: streamRankingMode)
  }

  private var allEpisodes: [Video] {
    var seen = Set<String>()
    return (item.videos ?? [])
      .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
      .sorted(by: Self.episodeOrder)
  }

  private var availableSeasons: [Int] {
    Array(Set(allEpisodes.map { $0.season ?? 0 })).sorted()
  }

  private var selectedSeasonEpisodes: [Video] {
    guard let selectedSeason else { return [] }
    return allEpisodes.filter { ($0.season ?? 0) == selectedSeason }
  }

  private var primaryEpisode: Video? {
    model.seriesResumeSelection(for: item)?.episode
      ?? allEpisodes.first(where: { ($0.season ?? 0) == 1 })
      ?? allEpisodes.first
  }

  private var primaryActionTitle: String {
    if item.type == "series", let episode = primaryEpisode {
      let prefix = model.episodeProgress(episode, in: item) == nil ? "Play" : "Resume"
      return "\(prefix) \(episodeLocation(episode))"
    }
    return model.resumeProgress(for: item) == nil ? "Play" : "Resume"
  }

  private var relatedTitles: [MetaItem] {
    DiscoveryShelfBuilder.relatedItems(
      to: item,
      candidates: model.homeShelves.flatMap(\.items)
        + model.catalog
        + model.library
        + model.searchCatalogs.flatMap(\.items)
    )
  }

  @MainActor
  private func load() async {
    isLoadingDetails = true
    if seed.type == "series" {
      item = await model.details(
        for: seed,
        preferredManifestURL: preferredManifestURL
      )
      let stored = EpisodeSeasonSelectionStore().season(for: item.id)
      selectedSeason = EpisodeSeasonSelector.initialSeason(
        availableSeasons: availableSeasons,
        persistedSeason: stored
      )
    } else {
      async let loadedItem = model.details(
        for: seed,
        preferredManifestURL: preferredManifestURL
      )
      isLoadingStreams = true
      async let loadedProviders = model.streamProviders(for: seed)
      item = await loadedItem
      movieProviders = await loadedProviders
      isLoadingStreams = false
    }
    isLoadingDetails = false
  }

  @MainActor
  private func quickPlay() async {
    isQuickPlaying = true
    defer { isQuickPlaying = false }

    if item.type == "series" {
      guard let episode = primaryEpisode else {
        actionError = "No episode metadata is available."
        return
      }
      let providers = await model.streamProviders(for: item, videoID: episode.id)
      let streams = tvRankedStreams(from: providers, mode: streamRankingMode)
      let progress = model.episodeProgress(episode, in: item)
      playbackRequest = TVPlaybackRequest.oneTap(
        streams: streams,
        contentIdentity: .episode(seriesID: item.id, videoID: episode.id),
        contentIdentifier: model.episodeContentIdentifier(episode, in: item),
        contentTitle: model.episodeContentTitle(episode, in: item),
        initialPosition: progress?.position ?? 0,
        mediaMetadata: .episode(series: item, episode: episode)
      )
    } else {
      playbackRequest = TVPlaybackRequest.oneTap(
        streams: rankedMovieStreams,
        contentIdentity: .movie(catalogID: item.id),
        contentIdentifier: "\(item.type):\(item.id)",
        contentTitle: item.name,
        initialPosition: model.resumeProgress(for: item)?.position ?? 0,
        mediaMetadata: .movie(item)
      )
    }

    if playbackRequest == nil {
      actionError = "No playable streams were returned by your installed add-ons."
    }
  }

  private func seasonTitle(_ season: Int) -> String {
    season == 0 ? "Specials" : "Season \(season)"
  }

  private func episodeLocation(_ episode: Video) -> String {
    let season = episode.season ?? 0
    let number = episode.episode ?? 0
    return season == 0 ? "Special \(number)" : "S\(season) E\(number)"
  }

  private static func episodeOrder(_ lhs: Video, _ rhs: Video) -> Bool {
    let lhsSeason = lhs.season ?? 0
    let rhsSeason = rhs.season ?? 0
    if lhsSeason != rhsSeason { return lhsSeason < rhsSeason }
    let lhsEpisode = lhs.episode ?? Int.max
    let rhsEpisode = rhs.episode ?? Int.max
    if lhsEpisode != rhsEpisode { return lhsEpisode < rhsEpisode }
    return lhs.id < rhs.id
  }
}

struct TVEpisodeCard: View {
  let episode: Video
  let progress: PlaybackProgress?
  let isCompleted: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ZStack(alignment: .bottom) {
        TVRemoteImage(
          url: episode.thumbnail,
          systemImage: "play.rectangle"
        )
        .frame(width: 420, height: 236)
        .clipped()

        if let progress, progress.duration > 0 {
          GeometryReader { proxy in
            let fraction = min(max(progress.position / progress.duration, 0), 1)
            ZStack(alignment: .leading) {
              Color.white.opacity(0.3)
              TVTheme.accent.frame(width: proxy.size.width * fraction)
            }
          }
          .frame(height: 7)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

      HStack {
        Text(location)
          .font(.headline)
        if isCompleted {
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(TVTheme.accent)
        }
      }
      Text(episode.title ?? "Episode")
        .font(.title3.weight(.semibold))
        .lineLimit(1)
      if let overview = episode.overview, !overview.isEmpty {
        Text(overview)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .frame(width: 420, alignment: .leading)
  }

  private var location: String {
    let season = episode.season ?? 0
    let number = episode.episode ?? 0
    return season == 0 ? "Special \(number)" : "S\(season) E\(number)"
  }
}
