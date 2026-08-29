import SwiftUI

struct WatchSearchView: View {
    @EnvironmentObject private var model: WatchAppModel
    @State private var query = ""
    @State private var mediaType = "all"

    var body: some View {
        List {
            Picker("Type", selection: $mediaType) {
                Text("All").tag("all")
                Text("Movies").tag("movie")
                Text("Series").tag("series")
            }

            if query.isEmpty, !model.recentSearches.isEmpty {
                Section("Recent") {
                    ForEach(model.recentSearches, id: \.self) { recent in
                        Button {
                            query = recent
                            Task { await submitSearch() }
                        } label: {
                            Label(recent, systemImage: "clock.arrow.circlepath")
                        }
                    }
                    Button(role: .destructive) {
                        model.clearRecentSearches()
                    } label: {
                        Label("Clear Recent", systemImage: "trash")
                    }
                }
            }

            if model.isSearching {
                ProgressView("Searching")
            } else if !query.isEmpty && model.searchResults.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different title or add another catalog add-on.")
                )
            } else {
                ForEach(model.searchResults) { route in
                    NavigationLink {
                        WatchDetailsView(route: route)
                    } label: {
                        WatchMediaRow(item: route.item)
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Movies and series")
        .onSubmit(of: .search) {
            Task { await submitSearch() }
        }
    }

    private func submitSearch() async {
        await model.search(
            query,
            mediaType: mediaType == "all" ? nil : mediaType
        )
    }
}

struct WatchLibraryView: View {
    @EnvironmentObject private var model: WatchAppModel

    var body: some View {
        List {
            if model.library.isEmpty {
                ContentUnavailableView(
                    "Library Empty",
                    systemImage: "bookmark",
                    description: Text("Save a movie or series from its details screen.")
                )
            } else {
                ForEach(model.library) { item in
                    NavigationLink {
                        WatchDetailsView(
                            route: WatchMediaRoute(
                                item: item,
                                manifestURL: WatchAppModel.defaultManifestURL
                            )
                        )
                    } label: {
                        WatchMediaRow(item: item)
                    }
                }
            }
        }
        .navigationTitle("My Library")
    }
}

struct WatchCatalogBrowseView: View {
    @EnvironmentObject private var model: WatchAppModel
    let section: WatchCatalogSection

    @State private var accumulator: CatalogPageAccumulator
    @State private var isLoadingMore = false
    @State private var loadError: String?

    init(section: WatchCatalogSection) {
        self.section = section
        var initial = CatalogPageAccumulator()
        initial.append(section.items.map(\.item), supportsSkip: section.supportsSkip)
        _accumulator = State(initialValue: initial)
    }

    var body: some View {
        List {
            ForEach(accumulator.items) { item in
                NavigationLink {
                    WatchDetailsView(
                        route: WatchMediaRoute(
                            item: item,
                            manifestURL: section.manifestURL
                        )
                    )
                } label: {
                    WatchMediaRow(item: item)
                }
            }

            if accumulator.canLoadMore {
                Button {
                    Task { await loadMore() }
                } label: {
                    if isLoadingMore {
                        ProgressView()
                    } else {
                        Label("Load More", systemImage: "arrow.down.circle")
                    }
                }
                .disabled(isLoadingMore)
            }

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle(section.title)
    }

    private func loadMore() async {
        guard !isLoadingMore, accumulator.canLoadMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await model.catalogPage(
                for: section,
                skip: accumulator.nextSkip
            )
            accumulator.append(page.map(\.item), supportsSkip: section.supportsSkip)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

struct WatchDetailsView: View {
    @EnvironmentObject private var model: WatchAppModel
    let route: WatchMediaRoute

    @State private var resolvedRoute: WatchMediaRoute
    @State private var isLoading = true
    @State private var selectedSeason: Int?
    @State private var wikipediaTrivia: WikipediaTitleTrivia?
    @State private var isLoadingTrivia = false
    @State private var revealsSpoilers = false
    @State private var showsTrivia = false
    @State private var selectedTrailer: WatchPlaybackRequest?
    @State private var trailerError: String?

    init(route: WatchMediaRoute) {
        self.route = route
        _resolvedRoute = State(initialValue: route)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                WatchArtwork(url: resolvedRoute.item.poster)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(0.72, contentMode: .fit)
                    .frame(maxHeight: 150)

                Text(resolvedRoute.item.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                metadata
                reactionControls

                HStack {
                    Button {
                        Task { await model.toggleLibrary(resolvedRoute.item) }
                    } label: {
                        Label(
                            model.isInLibrary(resolvedRoute.item) ? "Saved" : "Save",
                            systemImage: model.isInLibrary(resolvedRoute.item)
                                ? "bookmark.fill"
                                : "bookmark"
                        )
                    }
                    .buttonStyle(.bordered)

                    if resolvedRoute.item.type != "series" {
                        NavigationLink {
                            WatchStreamSelectionView(route: resolvedRoute)
                        } label: {
                            Label("Play", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                trailerAction

                if let description = resolvedRoute.item.description,
                   !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                richMetadata
                triviaAndAwards

                if resolvedRoute.item.type == "series" {
                    episodeList
                }

                relatedTitles
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle("Details")
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .fullScreenCover(item: $selectedTrailer) { request in
            WatchPlaybackSessionView(request: request)
                .environmentObject(model)
        }
        .alert(
            "Trailer",
            isPresented: Binding(
                get: { trailerError != nil },
                set: { if !$0 { trailerError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { trailerError = nil }
        } message: {
            Text(trailerError ?? "The trailer could not be opened.")
        }
        .task(id: route.id) {
            isLoading = true
            resolvedRoute = await model.details(for: route)
            let seasons = availableSeasons
            selectedSeason = model.selectedSeason(
                for: resolvedRoute.item,
                availableSeasons: seasons
            )
            isLoading = false
            await loadWikipediaTrivia()
        }
    }

    private var reactionControls: some View {
        HStack(spacing: 6) {
            reactionButton(.dislike, symbol: "hand.thumbsdown.fill", label: "Dislike")
            reactionButton(.like, symbol: "hand.thumbsup.fill", label: "Like")
            reactionButton(.love, symbol: "heart.fill", label: "Love")
        }
    }

    private func reactionButton(
        _ reaction: MediaReaction,
        symbol: String,
        label: String
    ) -> some View {
        let selected = model.reaction(for: resolvedRoute.item) == reaction
        return Button {
            Task {
                await model.setReaction(
                    selected ? nil : reaction,
                    for: resolvedRoute.item
                )
            }
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(selected ? WatchTheme.accent : .secondary)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    @ViewBuilder
    private var trailerAction: some View {
        if let url = resolvedRoute.item.preferredTrailerURL {
            let assessment = WatchStreamCompatibility.assess(url: url)
            if assessment.isPlayable {
                Button {
                    do {
                        selectedTrailer = try model.resolveTrailerPlaybackRequest(
                            url: url,
                            title: resolvedRoute.item.name
                        )
                    } catch {
                        trailerError = error.localizedDescription
                    }
                } label: {
                    Label("Watch Trailer", systemImage: "play.rectangle.fill")
                }
                .buttonStyle(.bordered)
            } else if url.scheme?.lowercased() == "https" {
                Link(destination: url) {
                    Label("Open Trailer Link", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var richMetadata: some View {
        let item = resolvedRoute.item
        VStack(alignment: .leading, spacing: 7) {
            detailLine("Genres", values: item.genres ?? [])
            detailLine("Director", values: item.director ?? [])
            detailLine("Writers", values: item.writer ?? [])
            detailLine("Cast", values: item.actorNames)
            detailLine(
                "Details",
                values: [
                    item.runtime,
                    item.certification,
                    item.country,
                    item.language,
                    item.status,
                ].compactMap { $0 }
            )
        }
    }

    @ViewBuilder
    private func detailLine(_ title: String, values: [String]) -> some View {
        let normalized = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !normalized.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(WatchTheme.accent)
                Text(normalized.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var triviaAndAwards: some View {
        let providerFacts = TitleTriviaBuilder.facts(for: resolvedRoute.item)
        if resolvedRoute.item.awards?.isEmpty == false
            || !providerFacts.isEmpty
            || wikipediaTrivia != nil
            || isLoadingTrivia {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    showsTrivia.toggle()
                } label: {
                    HStack {
                        Label("Trivia & Awards", systemImage: "sparkles")
                        Spacer()
                        Image(systemName: showsTrivia ? "chevron.up" : "chevron.down")
                    }
                }
                .buttonStyle(.plain)

                if showsTrivia {
                VStack(alignment: .leading, spacing: 7) {
                    if let awards = resolvedRoute.item.awards, !awards.isEmpty {
                        detailLine("Awards", values: [awards])
                    }
                    ForEach(providerFacts.filter { revealsSpoilers || !$0.isSpoiler }) { fact in
                        Label(fact.text, systemImage: "sparkles")
                            .font(.caption2)
                    }
                    if providerFacts.contains(where: \.isSpoiler) {
                        Toggle("Show Spoilers", isOn: $revealsSpoilers)
                            .font(.caption2)
                    }
                    if isLoadingTrivia {
                        ProgressView("Loading sourced trivia")
                            .font(.caption2)
                    }
                    if let wikipediaTrivia {
                        ForEach(wikipediaTrivia.excerpts.prefix(4)) { excerpt in
                            Text(excerpt.text)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Link("Wikipedia source", destination: wikipediaTrivia.revisionURL)
                            .font(.caption2)
                        Link("CC BY-SA 4.0", destination: WikipediaTitleTrivia.licenseURL)
                            .font(.caption2)
                    }
                }
                .padding(.top, 5)
                }
            }
            .font(.caption.weight(.semibold))
        }
    }

    @ViewBuilder
    private var relatedTitles: some View {
        let related = model.relatedRoutes(to: resolvedRoute.item)
        if !related.isEmpty {
            Text("Related")
                .font(.headline)
            ForEach(related.prefix(4)) { relatedRoute in
                NavigationLink {
                    WatchDetailsView(route: relatedRoute)
                } label: {
                    WatchMediaRow(item: relatedRoute.item)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 5) {
            if let releaseInfo = resolvedRoute.item.releaseInfo {
                WatchStatusPill(symbol: "calendar", text: releaseInfo)
            }
            if let rating = resolvedRoute.item.imdbRating {
                WatchStatusPill(symbol: "star.fill", text: rating, color: .yellow)
            }
        }
    }

    @ViewBuilder
    private var episodeList: some View {
        let videos = filteredEpisodes
        if videos.isEmpty {
            Text("No episodes were returned by this metadata add-on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            if let resume = model.resumeRecord(for: resolvedRoute.item),
               let video = resume.video {
                NavigationLink {
                    WatchStreamSelectionView(route: resolvedRoute, video: video)
                } label: {
                    Label(
                        "Resume \(episodeLabel(video)) · \(WatchTimeFormatter.compact(resume.position))",
                        systemImage: "play.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
            }

            Text("Episodes")
                .font(.headline)
            if availableSeasons.count > 1 {
                Picker(
                    "Season",
                    selection: Binding(
                        get: { selectedSeason ?? availableSeasons.first ?? 1 },
                        set: { season in
                            selectedSeason = season
                            model.setSelectedSeason(season, for: resolvedRoute.item)
                        }
                    )
                ) {
                    ForEach(availableSeasons, id: \.self) { season in
                        Text(season == 0 ? "Specials" : "Season \(season)")
                            .tag(season)
                    }
                }
            }
            ForEach(videos) { video in
                NavigationLink {
                    WatchStreamSelectionView(route: resolvedRoute, video: video)
                } label: {
                    HStack(spacing: 7) {
                        if let thumbnail = video.thumbnail {
                            WatchArtwork(url: thumbnail)
                                .frame(width: 38, height: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(episodeLabel(video))
                                    .font(.subheadline.weight(.semibold))
                                if model.isEpisodeCompleted(video, in: resolvedRoute.item) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(WatchTheme.playable)
                                }
                            }
                            if let title = video.title {
                                Text(title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            if let progress = model.progressRecord(
                                for: video,
                                in: resolvedRoute.item
                            ) {
                                ProgressView(
                                    value: progress.duration > 0
                                        ? progress.position / progress.duration
                                        : 0
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var availableSeasons: [Int] {
        Array(Set((resolvedRoute.item.videos ?? []).map { $0.season ?? 0 })).sorted()
    }

    private var filteredEpisodes: [Video] {
        (resolvedRoute.item.videos ?? [])
            .filter { selectedSeason == nil || ($0.season ?? 0) == selectedSeason }
            .sorted {
                ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
            }
    }

    private func loadWikipediaTrivia() async {
        guard WikipediaTitleIdentifier.imdbID(from: resolvedRoute.item.id) != nil else {
            wikipediaTrivia = nil
            return
        }
        isLoadingTrivia = true
        defer { isLoadingTrivia = false }
        wikipediaTrivia = try? await WikipediaTriviaClient(
            requestTimeout: 6,
            maximumSections: 2,
            excerptsPerSection: 1
        ).trivia(for: resolvedRoute.item)
    }

    private func episodeLabel(_ video: Video) -> String {
        if let season = video.season, let episode = video.episode {
            return "S\(season) E\(episode)"
        }
        return video.title ?? "Episode"
    }
}

struct WatchStreamSelectionView: View {
    @EnvironmentObject private var model: WatchAppModel
    let route: WatchMediaRoute
    var video: Video?

    @AppStorage("stream-ranking-mode") private var streamRankingMode =
        StreamRankingMode.current
    @State private var groups: [WatchStreamGroup] = []
    @State private var selectedPlayback: WatchPlaybackRequest?
    @State private var isLoading = true
    @State private var resolvingStreamID: String?
    @State private var resolutionError: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView("Finding streams")
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No Streams",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Install a stream add-on or open a direct HTTPS URL.")
                )
                NavigationLink("Open Stream URL") {
                    WatchManualStreamView()
                }
            } else {
                Section("Order") {
                    Picker("Stream order", selection: $streamRankingMode) {
                        ForEach(StreamRankingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.navigationLink)
                    .accessibilityIdentifier("watch-stream-order")
                }

                Section("Streams") {
                    ForEach(rankedStreams) { presented in
                        streamRow(presented)
                    }
                }
                if let resolutionError {
                    Section {
                        Label(resolutionError, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle(video?.title ?? "Streams")
        .task(id: "\(route.id)|\(video?.id ?? "movie")") {
            isLoading = true
            groups = await model.streams(for: route, video: video)
            isLoading = false
        }
        .fullScreenCover(item: $selectedPlayback) { request in
            WatchPlaybackSessionView(request: request)
                .environmentObject(model)
        }
    }

    private var rankedStreams: [PresentedStream] {
        let presented = groups.flatMap { group in
            group.streams.enumerated().map { index, stream in
                PresentedStream(
                    id: "\(group.id)#\(index)#\(stream.id)",
                    providerID: group.id,
                    providerName: group.providerName,
                    stream: stream
                )
            }
        }
        return StreamPresentationPolicy.ranked(presented, mode: streamRankingMode)
    }

    @ViewBuilder
    private func streamRow(_ presented: PresentedStream) -> some View {
        let stream = presented.stream
        let assessment = WatchStreamCompatibility.assess(stream)
        let canUseServer = model.canResolveWithStreamingServer(stream)
        if assessment.isPlayable || canUseServer {
            Button {
                Task {
                    await open(
                        stream,
                        providerName: presented.providerName
                    )
                }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stream.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if resolvingStreamID == stream.id {
                        ProgressView("Preparing")
                            .font(.caption2)
                    } else {
                        HStack(spacing: 5) {
                            Text(presented.providerName)
                                .foregroundStyle(WatchTheme.accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Spacer(minLength: 2)
                            if presented.isCached {
                                Image(systemName: "bolt.fill")
                                    .foregroundStyle(WatchTheme.accent)
                            }
                            Label(
                                presented.fileSizeBadge
                                    ?? presented.qualityBadge
                                    ?? (canUseServer
                                        ? "HLS"
                                        : assessment.kind?.displayName ?? "Play"),
                                systemImage: canUseServer ? "server.rack" : "play.fill"
                            )
                            .foregroundStyle(WatchTheme.playable)
                            .lineLimit(1)
                        }
                        .font(.caption2.weight(.semibold))
                    }
                }
            }
            .disabled(resolvingStreamID != nil)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(stream.displayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(presented.providerName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Label(
                    assessment.incompatibility?.message ?? "Unavailable on Apple Watch",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func open(_ stream: Stream, providerName: String) async {
        resolvingStreamID = stream.id
        resolutionError = nil
        defer { resolvingStreamID = nil }
        do {
            selectedPlayback = try await model.resolvePlaybackRequest(
                stream: stream,
                providerName: providerName,
                route: route,
                video: video,
                fallbackSources: rankedStreams.map { presented in
                    WatchPlaybackSource(
                        providerName: presented.providerName,
                        stream: presented.stream
                    )
                }
            )
        } catch {
            resolutionError = error.localizedDescription
        }
    }
}
