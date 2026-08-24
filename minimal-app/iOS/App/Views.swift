import Foundation
import SafariServices
import SwiftUI

private let grid = [GridItem(.adaptive(minimum: 132), spacing: 16)]

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var watchTogether: WatchTogetherModel
    @State private var selectedTab = ProcessInfo.processInfo.environment[
        "SKELETON_SELECTED_TAB"
    ] ?? "home"

    var body: some View {
        if ProcessInfo.processInfo.environment["SKELETON_E2E"] == "1" {
            E2EStatusView()
        } else {
            TabView(selection: $selectedTab) {
                NavigationStack { HomeView() }
                    .tabItem { Label("Home", systemImage: "rectangle.grid.2x2") }
                    .tag("home")
                NavigationStack { LibraryView() }
                    .tabItem { Label("Library", systemImage: "bookmark") }
                    .tag("library")
                NavigationStack { AddonsView() }
                    .tabItem { Label("Add-ons", systemImage: "shippingbox") }
                    .tag("addons")
                NavigationStack { AccountView() }
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    .tag("account")
                NavigationStack { FriendsView() }
                    .tabItem { Label("Friends", systemImage: "person.2") }
                    .tag("friends")
                NavigationStack { SettingsView() }
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag("settings")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { await watchTogether.start() }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""

    var body: some View {
        GeometryReader { viewport in
            VStack(spacing: 12) {
                catalogSourceMenu
                    .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search catalog", text: $search)
                    .submitLabel(.search)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(Color.appFieldBackground)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.appHairline, lineWidth: 0.5)
            }
            .padding(.horizontal, 16)
            .accessibilityIdentifier("catalog-search-field")

                Group {
                    if !trimmedSearch.isEmpty {
                        searchContent
                    } else {
                        browseContent
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.top, 8)
            .frame(
                width: viewport.size.width,
                height: viewport.size.height,
                alignment: .top
            )
        }
        .navigationBarHidden(true)
        .navigationDestination(for: MetaItem.self) { DetailsView(seed: $0) }
        .task(id: search) {
            guard !trimmedSearch.isEmpty else {
                model.clearSearch()
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.searchAllCatalogs(trimmedSearch)
        }
        .refreshable {
            if trimmedSearch.isEmpty {
                try? await model.loadHome()
            } else {
                await model.searchAllCatalogs(trimmedSearch)
            }
        }
    }

    private var catalogSourceMenu: some View {
        Menu {
            ForEach(model.catalogSources) { source in
                Button {
                    search = ""
                    Task {
                        do { try await model.selectCatalogSource(source) }
                        catch { model.errorMessage = error.localizedDescription }
                    }
                } label: {
                    if source.id == model.selectedCatalogSourceID {
                        Label(source.title, systemImage: "checkmark")
                    } else {
                        Text(source.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedCatalogSource?.title ?? "Catalog")
                        .font(.title3.bold())
                    Text(model.selectedCatalogSource?.subtitle ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.caption.bold())
            }
            .foregroundStyle(Color.appAccent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("catalog-source-menu")
        .accessibilityLabel("Catalog source")
    }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var browseContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if !model.continueWatching.isEmpty {
                    continueWatchingSection
                }

                if model.isLoading && model.catalog.isEmpty {
                    ProgressView("Loading catalog…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, model.continueWatching.isEmpty ? 120 : 28)
                } else if let error = model.errorMessage, model.catalog.isEmpty {
                    EmptyStateView(
                        title: "Catalog unavailable",
                        systemImage: "wifi.exclamationmark",
                        message: error
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                } else {
                    LazyVGrid(columns: grid, spacing: 20) {
                        ForEach(model.catalog) { item in
                            NavigationLink(value: item) { PosterCard(item: item) }
                                .buttonStyle(.plain)
                                .onAppear {
                                    Task { await model.loadNextPageIfNeeded(currentItem: item) }
                                }
                        }
                        if model.isLoadingNextPage {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding()
                                .accessibilityLabel("Loading more recommendations")
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 96)
        }
    }

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Continue Watching")
                .font(.headline)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(model.continueWatching) { entry in
                        NavigationLink {
                            ContinueWatchingDestination(entry: entry)
                        } label: {
                            ContinueWatchingCard(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("continue-watching-\(entry.id)")
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .accessibilityIdentifier("continue-watching-row")
    }

    @ViewBuilder
    private var searchContent: some View {
        if model.isSearching && model.searchCatalogs.isEmpty {
            ProgressView("Searching all catalogs…")
                .accessibilityIdentifier("global-search-loading")
        } else if model.searchCatalogs.isEmpty {
            EmptyStateView(
                title: "No results",
                systemImage: "magnifyingglass",
                message: "No installed search catalog found “\(trimmedSearch)”."
            )
            .accessibilityIdentifier("global-search-empty")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(model.searchCatalogs) { group in
                        SearchCatalogRow(group: group)
                    }
                }
                .padding(.vertical)
            }
            .accessibilityIdentifier("global-search-results")
        }
    }
}

private struct ContinueWatchingCard: View {
    let entry: ContinueWatchingEntry

    var body: some View {
        ZStack {
            poster
            LinearGradient(
                colors: [.clear, .black.opacity(0.05), .black.opacity(0.48)],
                startPoint: .top,
                endPoint: .bottom
            )

            Image(systemName: "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 1)
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.72), in: Circle())
                .overlay {
                    Circle().stroke(Color.white.opacity(0.82), lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.45), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 0) {
                if let episodeLabel {
                    Text(episodeLabel)
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.74), in: Capsule())
                        .padding(8)
                }
                Spacer(minLength: 0)
                progressEdge
                    .padding(.horizontal, 7)
                    .padding(.bottom, 7)
            }
        }
        .frame(width: 112, height: 168)
        .background(Color.appPlaceholderBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.appHairline, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Resumes playback")
    }

    @ViewBuilder
    private var poster: some View {
        if let posterURL = entry.item.poster {
            AsyncImage(url: posterURL, transaction: Transaction(animation: nil)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                case .empty:
                    posterPlaceholder.overlay { ProgressView().controlSize(.small) }
                case .failure:
                    posterPlaceholder
                @unknown default:
                    posterPlaceholder
                }
            }
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        Rectangle()
            .fill(Color.appPlaceholderBackground)
            .overlay {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }

    private var progressEdge: some View {
        DotMatrixProgressBar(
            value: entry.progress.position,
            total: entry.progress.duration,
            trackColor: .white.opacity(0.24)
        )
    }

    private var episodeLabel: String? {
        guard let episode = entry.episode else { return nil }
        if let season = episode.season, let number = episode.episode {
            return "S\(season) E\(number)"
        }
        if let number = episode.episode { return "E\(number)" }
        return "EPISODE"
    }

    private var accessibilityLabel: String {
        var label = "Continue \(entry.item.name)"
        if let episodeLabel { label += ", \(episodeLabel)" }
        return label + ", from \(formattedTime(entry.progress.position))"
    }

    private func formattedTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let total = Int(value.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

private struct ContinueWatchingDestination: View {
    @EnvironmentObject private var model: AppModel
    let entry: ContinueWatchingEntry
    @State private var resolvedSeries: MetaItem?
    @State private var resolvedEpisode: Video?

    var body: some View {
        Group {
            if let fallbackEpisode = entry.episode {
                if let resolvedSeries, let resolvedEpisode {
                    EpisodeResumeResolvingScreen(
                        series: resolvedSeries,
                        episode: resolvedEpisode,
                        progress: entry.progress
                    )
                } else {
                    ProgressView("Refreshing episode…")
                        .accessibilityIdentifier("continue-watching-episode-refreshing")
                        .task(id: entry.progress.updatedAt) {
                            let details = await model.details(for: entry.item)
                            guard !Task.isCancelled else { return }
                            resolvedSeries = details
                            resolvedEpisode = details.videos?.first {
                                $0.id == fallbackEpisode.id
                            } ?? fallbackEpisode
                        }
                }
            } else {
                ResolvingPlayerScreen(
                    candidate: StreamPlaybackCandidate(
                        stream: entry.progress.stream,
                        providerName: entry.progress.providerName,
                        contentIdentifier: entry.progress.contentIdentifier,
                        contentTitle: entry.progress.contentTitle,
                        initialPosition: entry.progress.position,
                        mediaMetadata: entry.progress.mediaMetadata ?? entry.mediaMetadata
                    ),
                    minimumVideoDuration: entry.item.type == "movie" ? 20 * 60 : 5 * 60
                )
            }
        }
        .navigationTitle(entry.item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SearchCatalogRow: View {
    let group: SearchCatalogGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.catalogName)
                    .font(.headline)
                Text(group.providerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(group.items) { item in
                        NavigationLink {
                            DetailsView(
                                seed: item,
                                preferredManifestURL: group.manifestURL
                            )
                        } label: {
                            PosterCard(item: item)
                                .frame(width: 132)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search-catalog-\(group.catalogName)")
    }
}

struct PosterCard: View {
    let item: MetaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PosterArtwork(item: item)
            Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let release = item.releaseInfo {
                Text(release).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("catalog-item-\(item.id)")
    }
}

private struct PosterArtwork: View {
    let item: MetaItem

    var body: some View {
        AsyncImage(url: item.poster) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            ZStack {
                Color.appPlaceholderBackground
                Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 198)
        .background(Color.appPlaceholderBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct DetailsView: View {
    private static let allProvidersID = "all-providers"
    private static let streamBatchSize = 60
    private let seasonSelectionStore = EpisodeSeasonSelectionStore()

    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let seed: MetaItem
    let preferredManifestURL: URL?
    @State private var item: MetaItem
    @State private var streamProviders: [StreamProviderGroup] = []
    @State private var selectedProviderID = Self.allProvidersID
    @State private var selectedSeason: Int?
    @State private var visibleStreamLimit = Self.streamBatchSize
    @State private var streamLoadRevision = 0
    @State private var isLoading = true
    @State private var isUpdatingLibrary = false
    @State private var activeTrailer: TrailerDestination?

    init(seed: MetaItem, preferredManifestURL: URL? = nil) {
        self.seed = seed
        self.preferredManifestURL = preferredManifestURL
        _item = State(initialValue: seed)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    PosterArtwork(item: item).frame(width: 132)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.name).font(.title2.bold())
                        Text(item.releaseInfo ?? item.type.capitalized)
                            .foregroundStyle(.secondary)
                        Button {
                            Task {
                                isUpdatingLibrary = true
                                await model.toggleLibrary(item)
                                isUpdatingLibrary = false
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if isUpdatingLibrary {
                                    ProgressView()
                                        .controlSize(.small)
                                        .tint(
                                            model.isInLibrary(item)
                                                ? Color.appAccent
                                                : Color.appOnAccent
                                        )
                                } else {
                                    Image(systemName: model.isInLibrary(item) ? "bookmark.fill" : "bookmark")
                                }
                                Text(isUpdatingLibrary
                                     ? "Updating…"
                                     : model.isInLibrary(item) ? "In Library" : "Add to Library")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(
                                model.isInLibrary(item)
                                    ? Color.appAccent
                                    : Color.appOnAccent
                            )
                            .background(
                                model.isInLibrary(item)
                                    ? Color.appAccent.opacity(0.14)
                                    : Color.appAccent
                            )
                            .overlay {
                                if model.isInLibrary(item) {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.appAccent.opacity(0.55), lineWidth: 1)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isUpdatingLibrary)
                        .accessibilityIdentifier("library-toggle")

                        if item.type != "series",
                           let progress = model.resumeProgress(for: item) {
                            NavigationLink {
                                ResolvingPlayerScreen(
                                    candidates: resumeCandidates(for: progress),
                                    minimumVideoDuration: minimumVideoDuration
                                )
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "play.fill")
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("Resume")
                                            Text("From \(formatPlaybackTime(progress.position))")
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .font(.subheadline.weight(.semibold))

                                    if progress.duration > 0 {
                                        DotMatrixProgressBar(
                                            value: min(progress.position, progress.duration),
                                            total: progress.duration
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .foregroundStyle(Color.appAccent)
                                .background(Color.appAccent.opacity(0.12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.appAccent.opacity(0.45), lineWidth: 1)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Resume \(item.name) from \(formatPlaybackTime(progress.position))"
                            )
                            .accessibilityIdentifier("resume-playback")
                        }

                        if item.type == "series",
                           let selection = model.seriesResumeSelection(for: item) {
                            NavigationLink {
                                EpisodeResumeResolvingScreen(
                                    series: item,
                                    episode: selection.episode,
                                    progress: selection.progress
                                )
                            } label: {
                                seriesResumeCard(selection)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Resume \(item.name), \(episodeLocation(selection.episode)), "
                                    + "from \(formatPlaybackTime(selection.progress.position))"
                            )
                            .accessibilityIdentifier("resume-series")
                        }

                        if let trailerURL = item.preferredTrailerURL {
                            Button {
                                activeTrailer = TrailerDestination(url: trailerURL)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "play.rectangle.fill")
                                    Text("Watch Trailer")
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption.weight(.bold))
                                }
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .foregroundStyle(Color.appAccent)
                                .background(Color.appAccent.opacity(0.12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.appAccent.opacity(0.45), lineWidth: 1)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the official trailer")
                            .accessibilityIdentifier("watch-trailer")
                        }
                    }
                }
                if let description = item.description { Text(description) }
            }

            if item.type == "series" {
                episodeSection
            }

            if item.type != "series" {
                Section {
                    if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(Color.appAccent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resolving add-ons…")
                                .font(.subheadline.weight(.semibold))
                            Text("Checking installed providers for streams")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Resolving add-ons")
                    .accessibilityIdentifier("stream-resolution-status")
                } else if streamProviders.isEmpty {
                    EmptyStateView(
                        title: "No streams",
                        systemImage: "play.slash",
                        message: "Install a compatible direct or torrent add-on."
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            providerButton(
                                id: Self.allProvidersID,
                                title: "All",
                                count: streamProviders.reduce(0) { $0 + $1.streams.count }
                            )
                            ForEach(streamProviders) { provider in
                                providerButton(
                                    id: provider.id,
                                    title: provider.name,
                                    count: provider.streams.count
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("stream-provider-selector")

                    let rankedStreams = visibleStreams
                    if rankedStreams.isEmpty {
                        Label(
                            "No streams from \(selectedProviderName)",
                            systemImage: "play.slash"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(rankedStreams.prefix(visibleStreamLimit))) { presented in
                            let stream = presented.stream
                            if stream.isDirectlyPlayable || stream.isTorrent {
                                NavigationLink {
                                    ResolvingPlayerScreen(
                                        candidates: orderedPlaybackCandidates(
                                            from: rankedStreams,
                                            startingAt: presented.id,
                                            contentIdentifier: "\(item.type):\(item.id)",
                                            contentTitle: item.name,
                                            initialPosition: 0,
                                            mediaMetadata: .movie(item)
                                        ),
                                        minimumVideoDuration: minimumVideoDuration
                                    )
                                } label: {
                                    streamRow(presented)
                                }
                            } else if let external = stream.externalUrl {
                                Button { openURL(external) } label: { streamRow(presented) }
                            } else {
                                streamRow(presented, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if visibleStreamLimit < rankedStreams.count {
                            Button {
                                visibleStreamLimit = min(
                                    visibleStreamLimit + Self.streamBatchSize,
                                    rankedStreams.count
                                )
                            } label: {
                                Label(
                                    "Show more streams (\(rankedStreams.count - visibleStreamLimit) remaining)",
                                    systemImage: "arrow.down.circle"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.appAccent)
                            .accessibilityIdentifier("show-more-streams")
                        }
                    }
                }
                } header: {
                    Text("Streams")
                }
                .id("streams-section")
            }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(false)
            .task {
                item = await model.details(
                    for: seed,
                    preferredManifestURL: preferredManifestURL
                )
                if item.type == "series" {
                    configureInitialSeason()
                    isLoading = false
                } else {
                    await loadStreams()
                }
                #if SKELETON_SCREENSHOT_HARNESS
                if ProcessInfo.processInfo.environment["UI_SCREENSHOT_STATE"] == "details-streams" {
                    try? await Task.sleep(for: .milliseconds(100))
                    proxy.scrollTo("streams-section", anchor: .top)
                } else if ProcessInfo.processInfo.environment["UI_SCREENSHOT_STATE"]
                    == "details-trailer-active", let trailerURL = item.preferredTrailerURL {
                    activeTrailer = TrailerDestination(url: trailerURL)
                }
                #endif
            }
        }
        .fullScreenCover(item: $activeTrailer) { destination in
            TrailerBrowser(url: destination.url)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var episodeSection: some View {
        Section {
            if allEpisodes.isEmpty {
                Label(
                    "No episode metadata is available",
                    systemImage: "list.number"
                )
                .foregroundStyle(.secondary)
            } else {
                if let selectedSeason,
                   let selection = model.seasonResumeSelection(selectedSeason, in: item) {
                    NavigationLink {
                        EpisodeResumeResolvingScreen(
                            series: item,
                            episode: selection.episode,
                            progress: selection.progress
                        )
                    } label: {
                        seasonResumeRow(selection, season: selectedSeason)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "Resume \(seasonLabel(selectedSeason)), "
                            + "\(episodeLocation(selection.episode)), "
                            + "from \(formatPlaybackTime(selection.progress.position))"
                    )
                    .accessibilityIdentifier("resume-season-\(selectedSeason)")
                }

                ForEach(selectedSeasonEpisodes) { episode in
                    NavigationLink {
                        EpisodeStreamsView(series: item, episode: episode)
                    } label: {
                        episodeRow(episode)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("episode-\(episode.id)")
                    .accessibilityHint("Shows available streams for this episode")
                }
            }
        } header: {
            HStack {
                Text("Episodes")
                Spacer()
                if let selectedSeason {
                    Menu {
                        ForEach(availableSeasons, id: \.self) { season in
                            Button {
                                selectSeason(season)
                            } label: {
                                if season == selectedSeason {
                                    Label(seasonLabel(season), systemImage: "checkmark")
                                } else {
                                    Text(seasonLabel(season))
                                }
                            }
                        }
                    } label: {
                        Label(seasonLabel(selectedSeason), systemImage: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                    }
                    .textCase(nil)
                    .accessibilityIdentifier("season-selector")
                }
            }
        }
    }

    private var allEpisodes: [Video] {
        var seen = Set<String>()
        return (item.videos ?? [])
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let lhsSeason = lhs.season ?? 0
                let rhsSeason = rhs.season ?? 0
                if lhsSeason != rhsSeason { return lhsSeason < rhsSeason }
                let lhsEpisode = lhs.episode ?? Int.max
                let rhsEpisode = rhs.episode ?? Int.max
                if lhsEpisode != rhsEpisode { return lhsEpisode < rhsEpisode }
                if lhs.released != rhs.released {
                    return (lhs.released ?? "") < (rhs.released ?? "")
                }
                return lhs.id < rhs.id
            }
    }

    private var availableSeasons: [Int] {
        Array(Set(allEpisodes.map { $0.season ?? 0 })).sorted()
    }

    private var selectedSeasonEpisodes: [Video] {
        guard let selectedSeason else { return [] }
        return allEpisodes.filter { ($0.season ?? 0) == selectedSeason }
    }

    private func seriesResumeCard(_ selection: EpisodeResumeSelection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: "play.fill")
                    .font(.caption.bold())
                    .frame(width: 28, height: 28)
                    .background(Color.appAccent, in: Circle())
                    .foregroundStyle(Color.appOnAccent)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Resume Series")
                        .font(.subheadline.weight(.semibold))
                    Text(
                        "\(episodeLocation(selection.episode)) · "
                            + "\(episodeDisplayTitle(selection.episode)) · "
                            + "\(formatPlaybackTime(selection.progress.position))"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if selection.progress.duration > 0 {
                DotMatrixProgressBar(
                    value: min(selection.progress.position, selection.progress.duration),
                    total: selection.progress.duration
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .foregroundStyle(Color.appAccent)
        .background(Color.appAccent.opacity(0.12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.appAccent.opacity(0.45), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func seasonResumeRow(
        _ selection: EpisodeResumeSelection,
        season: Int
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: "play.fill")
                .font(.caption.bold())
                .foregroundStyle(Color.appOnAccent)
                .frame(width: 30, height: 30)
                .background(Color.appAccent, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("Resume \(seasonLabel(season))")
                    .font(.subheadline.weight(.semibold))
                Text(
                    "\(episodeLocation(selection.episode)) · "
                        + "\(episodeDisplayTitle(selection.episode)) · "
                        + "\(formatPlaybackTime(selection.progress.position))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if selection.progress.duration > 0 {
                    DotMatrixProgressBar(
                        value: min(selection.progress.position, selection.progress.duration),
                        total: selection.progress.duration
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.appAccent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func episodeRow(_ episode: Video) -> some View {
        let isCompleted = model.isEpisodeCompleted(episode, in: item)
        let progress = model.episodeProgress(episode, in: item)
        let accessibilityLabel = episodeAccessibilityLabel(
            episode,
            isCompleted: isCompleted,
            progress: progress
        )

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                episodeArtwork(
                    episode,
                    isCompleted: isCompleted
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(episodeLocation(episode))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(episodeDisplayTitle(episode))
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }

                    if let summary = episodeSummary(episode) {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if isCompleted {
                        Text("Watched")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    } else if let released = episode.released, !released.isEmpty {
                        Text(String(released.prefix(10)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !isCompleted, let progress, progress.duration > 0 {
                EpisodeDotMatrixTimeline(
                    position: progress.position,
                    duration: progress.duration
                )
                .accessibilityIdentifier("episode-progress-\(episode.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func episodeAccessibilityLabel(
        _ episode: Video,
        isCompleted: Bool,
        progress: PlaybackProgress?
    ) -> String {
        var components = [episodeLocation(episode), episodeDisplayTitle(episode)]
        if let summary = episodeSummary(episode) {
            components.append(summary)
        }
        if isCompleted {
            components.append("watched")
        } else if let progress {
            components.append("resume at \(formatPlaybackTime(progress.position))")
        } else {
            components.append("not watched")
        }
        return components.joined(separator: ", ")
    }

    @ViewBuilder
    private func episodeArtwork(
        _ episode: Video,
        isCompleted: Bool
    ) -> some View {
        if let thumbnail = episode.thumbnail {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: thumbnail, transaction: Transaction(animation: nil)) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        Rectangle()
                            .fill(Color.secondary.opacity(0.12))
                            .overlay {
                                ProgressView()
                                    .controlSize(.small)
                            }
                    case .failure:
                        episodeThumbnailPlaceholder
                    @unknown default:
                        episodeThumbnailPlaceholder
                    }
                }
                .frame(width: 104, height: 58)
                .clipped()

                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.green, in: Circle())
                        .overlay {
                            Circle().stroke(.white.opacity(0.9), lineWidth: 1.5)
                        }
                        .padding(5)
                }
            }
            .frame(width: 104, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        Color.secondary.opacity(0.18),
                        lineWidth: 1
                    )
            }
            .accessibilityHidden(true)
        } else {
            episodeArtworkFallback(
                isCompleted: isCompleted
            )
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
        }
    }

    private var episodeThumbnailPlaceholder: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.12))
            Image(systemName: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func episodeArtworkFallback(
        isCompleted: Bool
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isCompleted
                        ? Color.green.opacity(0.18)
                        : Color.appAccent.opacity(0.10)
                )
            Image(
                systemName: isCompleted
                    ? "checkmark"
                    : "play"
            )
            .font(.caption.bold())
            .foregroundStyle(isCompleted ? Color.green : Color.appAccent)
        }
    }

    private func configureInitialSeason() {
        selectedSeason = EpisodeSeasonSelector.initialSeason(
            availableSeasons: availableSeasons,
            persistedSeason: seasonSelectionStore.season(for: item.id)
        )
    }

    private func selectSeason(_ season: Int) {
        guard selectedSeason != season else { return }
        selectedSeason = season
        seasonSelectionStore.setSeason(season, for: item.id)
    }

    @MainActor
    private func loadStreams() async {
        streamLoadRevision += 1
        let revision = streamLoadRevision
        isLoading = true
        streamProviders = []
        selectedProviderID = Self.allProvidersID
        visibleStreamLimit = Self.streamBatchSize

        let loaded = await model.streamProviders(for: item)
        guard revision == streamLoadRevision, !Task.isCancelled else { return }
        streamProviders = loaded
        isLoading = false
    }

    private func seasonLabel(_ season: Int) -> String {
        season == 0 ? "Specials" : "Season \(season)"
    }

    private func episodeLocation(_ episode: Video) -> String {
        if let season = episode.season, let number = episode.episode {
            return "S\(season) E\(number)"
        }
        if let number = episode.episode { return "E\(number)" }
        return "Episode"
    }

    private func episodeDisplayTitle(_ episode: Video) -> String {
        guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return episodeLocation(episode) }
        return title
    }

    private func episodeSummary(_ episode: Video) -> String? {
        guard let overview = episode.overview?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !overview.isEmpty else { return nil }
        return overview
    }

    private var visibleStreams: [PresentedStream] {
        let providers = selectedProviderID == Self.allProvidersID
            ? streamProviders
            : streamProviders.filter { $0.id == selectedProviderID }
        return rankedPresentedStreams(from: providers)
    }

    private var selectedProviderName: String {
        guard selectedProviderID != Self.allProvidersID else { return "installed providers" }
        return streamProviders.first { $0.id == selectedProviderID }?.name ?? "this provider"
    }

    private var minimumVideoDuration: TimeInterval {
        item.type == "movie" ? 20 * 60 : 5 * 60
    }

    private func resumeCandidates(for progress: PlaybackProgress) -> [StreamPlaybackCandidate] {
        let rankedStreams = rankedPresentedStreams(from: streamProviders)
        let refreshed = rankedStreams.first { presented in
            let stream = presented.stream
            return stream.id == progress.stream.id
                || (stream.infoHash != nil
                    && stream.infoHash == progress.stream.infoHash
                    && stream.fileIdx == progress.stream.fileIdx)
                || (presented.providerName == progress.providerName
                    && stream.name == progress.stream.name
                    && stream.title == progress.stream.title)
        }

        if let refreshed {
            return orderedPlaybackCandidates(
                from: rankedStreams,
                startingAt: refreshed.id,
                contentIdentifier: progress.contentIdentifier,
                contentTitle: progress.contentTitle,
                initialPosition: progress.position,
                mediaMetadata: progress.mediaMetadata ?? .movie(item)
            )
        }

        let savedCandidate = StreamPlaybackCandidate(
            stream: progress.stream,
            providerName: progress.providerName,
            contentIdentifier: progress.contentIdentifier,
            contentTitle: progress.contentTitle,
            initialPosition: progress.position,
            mediaMetadata: progress.mediaMetadata ?? .movie(item)
        )
        let alternatives = rankedStreams.compactMap { presented -> StreamPlaybackCandidate? in
            guard presented.stream.isDirectlyPlayable || presented.stream.isTorrent,
                  presented.stream.id != progress.stream.id
            else { return nil }
            return StreamPlaybackCandidate(
                stream: presented.stream,
                providerName: presented.providerName,
                contentIdentifier: progress.contentIdentifier,
                contentTitle: progress.contentTitle,
                initialPosition: progress.position,
                mediaMetadata: progress.mediaMetadata ?? .movie(item),
                sourceID: presented.id
            )
        }
        return [savedCandidate] + alternatives
    }

    private func formatPlaybackTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let total = Int(value.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func providerButton(id: String, title: String, count: Int) -> some View {
        let isSelected = selectedProviderID == id
        return Button {
            selectedProviderID = id
            visibleStreamLimit = Self.streamBatchSize
        } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isSelected
                            ? Color.appOnAccent.opacity(0.18)
                            : Color.appAccent.opacity(0.12)
                    )
                    .clipShape(Capsule())
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? Color.appOnAccent : Color.appAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.appAccent : Color.appAccent.opacity(0.10))
            .overlay {
                Capsule().stroke(Color.appAccent.opacity(isSelected ? 0 : 0.45), lineWidth: 1)
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) streams")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func streamRow(
        _ presented: PresentedStream,
        systemImage: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage ?? (presented.stream.isTorrent ? "arrow.down.circle" : "play.circle"))
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text(presented.stream.displayName)
                    .font(.subheadline)
                    .lineLimit(3)
                if presented.qualityBadge != nil || presented.fileSizeBadge != nil {
                    HStack(spacing: 6) {
                        if let quality = presented.qualityBadge {
                            StreamMetadataBadge(text: quality, systemImage: "tv")
                        }
                        if let fileSize = presented.fileSizeBadge {
                            StreamMetadataBadge(text: fileSize, systemImage: "externaldrive")
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(presented.providerName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                if let description = presented.stream.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct EpisodeDotMatrixTimeline: View {
    let position: TimeInterval
    let duration: TimeInterval

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(formattedTime(position))
                    .foregroundStyle(Color.appAccent)
                Spacer(minLength: 8)
                Text(formattedTime(duration))
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospacedDigit().weight(.semibold))

            DotMatrixProgressBar(value: position, total: duration)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Watched \(formattedTime(position)) of \(formattedTime(duration))"
        )
    }

    private func formattedTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let total = Int(value.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

private struct DotMatrixProgressBar: View {
    let value: Double
    let total: Double
    var trackColor: Color = .appProgressTrack

    var body: some View {
        GeometryReader { proxy in
            let dotSize: CGFloat = 4
            let spacing: CGFloat = 3
            let dotCount = max(
                Int((proxy.size.width + spacing) / (dotSize + spacing)),
                1
            )
            let rawFilled = Int(ceil(completionFraction * Double(dotCount)))
            let filledDots = completionFraction > 0 ? max(rawFilled, 1) : 0

            HStack(spacing: spacing) {
                ForEach(0..<dotCount, id: \.self) { index in
                    Circle()
                        .fill(
                            index < filledDots
                                ? Color.appAccent
                                : trackColor
                        )
                        .frame(width: dotSize, height: dotSize)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    private var completionFraction: Double {
        guard value.isFinite, total.isFinite, total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }
}

private struct EpisodeResumeResolvingScreen: View {
    @EnvironmentObject private var model: AppModel
    let series: MetaItem
    let episode: Video
    let progress: PlaybackProgress
    @State private var candidates: [StreamPlaybackCandidate] = []
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if !candidates.isEmpty {
                ResolvingPlayerScreen(
                    candidates: candidates,
                    minimumVideoDuration: 5 * 60,
                    episodeAutoplayContext: EpisodeAutoplayContext(
                        series: series,
                        episode: episode
                    )
                )
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 44))
                    Text("Fresh stream unavailable")
                        .font(.title3.bold())
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .accessibilityIdentifier("episode-resume-refresh-error")
            } else {
                ProgressView("Refreshing episode streams…")
                    .accessibilityIdentifier("episode-resume-refreshing")
            }
        }
        .navigationTitle(progress.contentTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: progress.updatedAt) {
            await refreshCandidate()
        }
    }

    @MainActor
    private func refreshCandidate() async {
        candidates = []
        errorMessage = nil
        let providers = await model.streamProviders(for: series, videoID: episode.id)
        guard !Task.isCancelled else { return }

        let playable = rankedPresentedStreams(from: providers).filter {
            $0.stream.isDirectlyPlayable || $0.stream.isTorrent
        }
        let previous = progress.stream
        let exact = playable.first { presented in
            let stream = presented.stream
            if stream.id == previous.id { return true }
            if let infoHash = previous.infoHash,
               stream.infoHash == infoHash,
               stream.fileIdx == previous.fileIdx {
                return true
            }
            let hasStableLabel = previous.name != nil || previous.title != nil
            return hasStableLabel
                && presented.providerName == progress.providerName
                && stream.name == previous.name
                && stream.title == previous.title
        }
        let sameProvider = playable.first { presented in
            presented.providerName == progress.providerName
        }

        guard let refreshed = exact ?? sameProvider ?? playable.first else {
            errorMessage = "No add-on returned a current stream. Go back and choose an episode stream."
            return
        }
        candidates = orderedPlaybackCandidates(
            from: playable,
            startingAt: refreshed.id,
            contentIdentifier: progress.contentIdentifier,
            contentTitle: progress.contentTitle,
            initialPosition: progress.position,
            mediaMetadata: progress.mediaMetadata ?? .episode(
                series: series,
                episode: episode
            )
        )
    }
}

struct EpisodeStreamsView: View {
    private static let allProvidersID = "all-providers"
    private static let streamBatchSize = 60

    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let series: MetaItem
    let episode: Video
    @State private var streamProviders: [StreamProviderGroup] = []
    @State private var selectedProviderID = Self.allProvidersID
    @State private var visibleStreamLimit = Self.streamBatchSize
    @State private var isLoading = true

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        episodeThumbnail
                        VStack(alignment: .leading, spacing: 6) {
                            Text(episodeDisplayTitle)
                                .font(.headline)
                                .lineLimit(2)
                            Text(series.name)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if isCompleted {
                                Label("Watched", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            } else if let progress {
                                NavigationLink {
                                    EpisodeResumeResolvingScreen(
                                        series: series,
                                        episode: episode,
                                        progress: progress
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Label(
                                            "Resume at \(formatPlaybackTime(progress.position))",
                                            systemImage: "play.circle.fill"
                                        )
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.appAccent)
                                        if progress.duration > 0 {
                                            DotMatrixProgressBar(
                                                value: min(progress.position, progress.duration),
                                                total: progress.duration
                                            )
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        Color.appAccent.opacity(0.10),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.appAccent.opacity(0.25), lineWidth: 1)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                                .accessibilityLabel(
                                    "Resume \(episodeLocation) from "
                                        + formatPlaybackTime(progress.position)
                                )
                                .accessibilityIdentifier("episode-streams-resume")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let episodeSummary {
                        Text(episodeSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("episode-streams-summary")
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("episode-streams-header")
            } header: {
                Text(episodeLocation)
            }

            Section {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(Color.appAccent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Resolving add-ons…")
                                .font(.subheadline.weight(.semibold))
                            Text("Checking installed providers for episode streams")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Resolving episode streams")
                    .accessibilityIdentifier("stream-resolution-status")
                } else if streamProviders.isEmpty {
                    EmptyStateView(
                        title: "No streams",
                        systemImage: "play.slash",
                        message: "No installed add-on returned a stream for this episode."
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            providerButton(
                                id: Self.allProvidersID,
                                title: "All",
                                count: streamProviders.reduce(0) { $0 + $1.streams.count }
                            )
                            ForEach(streamProviders) { provider in
                                providerButton(
                                    id: provider.id,
                                    title: provider.name,
                                    count: provider.streams.count
                                )
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityIdentifier("stream-provider-selector")

                    if visibleStreams.isEmpty {
                        Label(
                            "No streams from \(selectedProviderName)",
                            systemImage: "play.slash"
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    } else {
                        let rankedStreams = visibleStreams
                        ForEach(Array(rankedStreams.prefix(visibleStreamLimit))) { presented in
                            let stream = presented.stream
                            if stream.isDirectlyPlayable || stream.isTorrent {
                                NavigationLink {
                                    ResolvingPlayerScreen(
                                        candidates: orderedPlaybackCandidates(
                                            from: rankedStreams,
                                            startingAt: presented.id,
                                            contentIdentifier: contentIdentifier,
                                            contentTitle: contentTitle,
                                            initialPosition: progress?.position ?? 0,
                                            mediaMetadata: .episode(
                                                series: series,
                                                episode: episode
                                            )
                                        ),
                                        minimumVideoDuration: 5 * 60,
                                        episodeAutoplayContext: EpisodeAutoplayContext(
                                            series: series,
                                            episode: episode
                                        )
                                    )
                                } label: {
                                    streamRow(presented)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                            } else if let external = stream.externalUrl {
                                Button { openURL(external) } label: {
                                    streamRow(presented)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                            } else {
                                streamRow(presented, systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if visibleStreamLimit < visibleStreams.count {
                            Button {
                                visibleStreamLimit = min(
                                    visibleStreamLimit + Self.streamBatchSize,
                                    visibleStreams.count
                                )
                            } label: {
                                Label(
                                    "Show more streams (\(visibleStreams.count - visibleStreamLimit) remaining)",
                                    systemImage: "arrow.down.circle"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(Color.appAccent)
                            .accessibilityIdentifier("show-more-streams")
                        }
                    }
                }
            } header: {
                Text("Streams")
            }
        }
        .accessibilityIdentifier("episode-streams-route")
        .navigationTitle("\(episodeLocation) Streams")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: episode.id) {
            isLoading = true
            streamProviders = []
            selectedProviderID = Self.allProvidersID
            visibleStreamLimit = Self.streamBatchSize
            let loaded = await model.streamProviders(for: series, videoID: episode.id)
            guard !Task.isCancelled else { return }
            streamProviders = loaded
            isLoading = false
        }
    }

    @ViewBuilder
    private var episodeThumbnail: some View {
        if let thumbnail = episode.thumbnail {
            AsyncImage(url: thumbnail, transaction: Transaction(animation: nil)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                case .empty:
                    Rectangle()
                        .fill(Color.secondary.opacity(0.12))
                        .overlay { ProgressView().controlSize(.small) }
                case .failure:
                    thumbnailPlaceholder
                @unknown default:
                    thumbnailPlaceholder
                }
            }
            .frame(width: 136, height: 76)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
            }
            .accessibilityHidden(true)
        } else {
            thumbnailPlaceholder
                .frame(width: 84, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
        }
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            Image(systemName: "photo")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var progress: PlaybackProgress? {
        model.episodeProgress(episode, in: series)
    }

    private var isCompleted: Bool {
        model.isEpisodeCompleted(episode, in: series)
    }

    private var contentIdentifier: String {
        model.episodeContentIdentifier(episode, in: series)
    }

    private var contentTitle: String {
        model.episodeContentTitle(episode, in: series)
    }

    private var episodeLocation: String {
        if let season = episode.season, let number = episode.episode {
            return "S\(season) E\(number)"
        }
        if let number = episode.episode { return "E\(number)" }
        return "Episode"
    }

    private var episodeDisplayTitle: String {
        guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return episodeLocation }
        return title
    }

    private var episodeSummary: String? {
        guard let overview = episode.overview?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !overview.isEmpty else { return nil }
        return overview
    }

    private var visibleStreams: [PresentedStream] {
        let providers = selectedProviderID == Self.allProvidersID
            ? streamProviders
            : streamProviders.filter { $0.id == selectedProviderID }
        return rankedPresentedStreams(from: providers)
    }

    private var selectedProviderName: String {
        guard selectedProviderID != Self.allProvidersID else { return "installed providers" }
        return streamProviders.first { $0.id == selectedProviderID }?.name ?? "this provider"
    }

    private func providerButton(id: String, title: String, count: Int) -> some View {
        let isSelected = selectedProviderID == id
        return Button {
            selectedProviderID = id
            visibleStreamLimit = Self.streamBatchSize
        } label: {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isSelected
                            ? Color.appOnAccent.opacity(0.18)
                            : Color.appAccent.opacity(0.12)
                    )
                    .clipShape(Capsule())
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? Color.appOnAccent : Color.appAccent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.appAccent : Color.appAccent.opacity(0.10))
            .overlay {
                Capsule().stroke(Color.appAccent.opacity(isSelected ? 0 : 0.45), lineWidth: 1)
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) streams")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func streamRow(
        _ presented: PresentedStream,
        systemImage: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(
                systemName: systemImage
                    ?? (presented.stream.isTorrent ? "arrow.down.circle" : "play.circle")
            )
            .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: 4) {
                Text(presented.stream.displayName)
                    .font(.subheadline)
                    .lineLimit(3)
                if presented.qualityBadge != nil || presented.fileSizeBadge != nil {
                    HStack(spacing: 6) {
                        if let quality = presented.qualityBadge {
                            StreamMetadataBadge(text: quality, systemImage: "tv")
                        }
                        if let fileSize = presented.fileSizeBadge {
                            StreamMetadataBadge(text: fileSize, systemImage: "externaldrive")
                        }
                    }
                    .accessibilityHidden(true)
                }
                Text(presented.providerName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.appAccent)
                if let description = presented.stream.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func formatPlaybackTime(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let total = Int(value.rounded(.down))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct TrailerDestination: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

private struct TrailerBrowser: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        controller.preferredControlTintColor = .systemOrange
        return controller
    }

    func updateUIViewController(
        _ controller: SFSafariViewController,
        context: Context
    ) {}
}

struct PresentedStream: Identifiable {
    let id: String
    let providerName: String
    let stream: Stream
    let playbackPriority: Int
    let fileSizeBadge: String?
    let qualityBadge: String?

    private static let sizeExpression = try! NSRegularExpression(
        pattern: #"(?<![A-Z0-9])(\d+(?:\.\d+)?)\s*(TB|GB|MB)(?![A-Z0-9])"#,
        options: [.caseInsensitive]
    )
    private static let qualityExpression = try! NSRegularExpression(
        pattern: #"(?:4320P|8K|2160P|4K|1080P|720P|480P)"#,
        options: [.caseInsensitive]
    )

    /// Put cached, phone-decodable releases ahead of extreme AI upscales and
    /// huge remuxes. Every provider result remains available; this only keeps
    /// an unsafe 8K entry from looking like the default choice on an iPhone.
    init(id: String, providerName: String, stream: Stream) {
        self.id = id
        self.providerName = providerName
        self.stream = stream

        let metadata = [stream.title, stream.name, stream.description]
            .compactMap { $0 }
            .joined(separator: " ")
        let uppercased = metadata.uppercased()
        let sizeMatch = Self.firstMatch(Self.sizeExpression, in: metadata)
        let sizeInGB = Self.sizeInGB(from: sizeMatch)

        fileSizeBadge = sizeMatch?
            .uppercased()
            .replacingOccurrences(of: " ", with: " ")

        if let quality = Self.firstMatch(Self.qualityExpression, in: metadata) {
            qualityBadge = switch quality.uppercased() {
            case "4320P", "8K": "8K"
            case "2160P", "4K": "4K"
            default: quality.uppercased()
            }
        } else {
            qualityBadge = nil
        }

        var score = metadata.contains("⚡") ? -1_000 : 0
        if uppercased.contains("4320P") || uppercased.contains("8K") {
            score += 1_000
        } else if uppercased.contains("1080P") {
            score -= 120
        } else if uppercased.contains("2160P") || uppercased.contains("4K") {
            score -= 100
        } else if uppercased.contains("720P") {
            score -= 70
        }
        if uppercased.contains("REMUX") { score += 12 }
        if let sizeInGB, sizeInGB > 50 {
            score += 60
        } else if let sizeInGB, sizeInGB > 25 {
            score += 25
        }
        playbackPriority = score
    }

    private static func sizeInGB(from value: String?) -> Double? {
        guard let value else { return nil }
        let scanner = Scanner(string: value)
        guard let amount = scanner.scanDouble() else { return nil }
        let unit = value.uppercased()
        if unit.contains("TB") { return amount * 1_024 }
        if unit.contains("MB") { return amount / 1_024 }
        return amount
    }

    private static func firstMatch(
        _ expression: NSRegularExpression,
        in text: String
    ) -> String? {
        let searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(
            in: text,
            options: [],
            range: searchRange
        ), let range = Range(match.range, in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func rankedPresentedStreams(
    from providers: [StreamProviderGroup]
) -> [PresentedStream] {
    providers.flatMap { provider in
        provider.streams.enumerated().map { index, stream in
            PresentedStream(
                id: "\(provider.id)#\(index)#\(stream.id)",
                providerName: provider.name,
                stream: stream
            )
        }
    }
    .sorted {
        if $0.playbackPriority != $1.playbackPriority {
            return $0.playbackPriority < $1.playbackPriority
        }
        return $0.id < $1.id
    }
}

/// Put the selected row first, then try every remaining ranked source once.
/// Wrapping to higher-ranked rows before declaring exhaustion makes choosing a
/// lower row recoverable without ever retrying the same broken link forever.
func orderedPlaybackCandidates(
    from streams: [PresentedStream],
    startingAt selectedID: String,
    contentIdentifier: String?,
    contentTitle: String?,
    initialPosition: TimeInterval,
    mediaMetadata: PlaybackMediaMetadata? = nil
) -> [StreamPlaybackCandidate] {
    let playable = streams.filter {
        $0.stream.isDirectlyPlayable || $0.stream.isTorrent
    }
    guard let selectedIndex = playable.firstIndex(where: { $0.id == selectedID }) else {
        return []
    }

    let ordered = Array(playable[selectedIndex...]) + Array(playable[..<selectedIndex])
    return ordered.map { presented in
        StreamPlaybackCandidate(
            stream: presented.stream,
            providerName: presented.providerName,
            contentIdentifier: contentIdentifier,
            contentTitle: contentTitle,
            initialPosition: initialPosition,
            mediaMetadata: mediaMetadata,
            sourceID: presented.id
        )
    }
}

private struct StreamMetadataBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.appAccent.opacity(0.12), in: Capsule())
            .overlay { Capsule().stroke(Color.appAccent.opacity(0.35), lineWidth: 1) }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.library.isEmpty {
                EmptyStateView(
                    title: "Library is empty",
                    systemImage: "bookmark",
                    message: "Save a title from its detail page."
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: grid, spacing: 20) {
                        ForEach(model.library) { item in
                            NavigationLink(value: item) {
                                PosterCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: MetaItem.self) { DetailsView(seed: $0) }
    }
}

struct AddonsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var input = ""
    @State private var status: String?

    var body: some View {
        List {
            Section("Install by manifest URL") {
                TextField("https://…/manifest.json", text: $input)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Validate and install") {
                    Task {
                        do {
                            try await model.installAddon(input)
                            status = "Installed"
                            input = ""
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                }
                .disabled(input.isEmpty)
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }

            Section("Installed") {
                ForEach(model.installedAddons, id: \.self) { url in
                    VStack(alignment: .leading) {
                        Text(url.host ?? "Add-on").font(.headline)
                        Text(url.absoluteString).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    offsets.map { model.installedAddons[$0] }.forEach(model.removeAddon)
                }
            }

            Section("Torrent streaming server") {
                TextField("http://127.0.0.1:11470", text: $model.streamingServerInput)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                HStack {
                    Label(
                        model.streamingServerOnline ? "Online" : "Offline",
                        systemImage: model.streamingServerOnline ? "checkmark.circle.fill" : "xmark.circle"
                    )
                    .foregroundStyle(model.streamingServerOnline ? .green : .secondary)
                    Spacer()
                    Button("Save and test") {
                        Task {
                            do { try await model.saveStreamingServer() }
                            catch { status = error.localizedDescription }
                        }
                    }
                }
                Text("Use localhost for an embedded/desktop service, a private LAN address, or HTTPS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Add-ons")
    }
}

struct SettingsView: View {
    @State private var selectedPlayer = StremioInternalPlayer.selected
    @AppStorage(AppearancePreferences.modeKey)
    private var appearanceModeRawValue = AppAppearanceMode.defaultMode.rawValue
    @AppStorage(AppearancePreferences.accentPresetKey)
    private var accentPresetRawValue = AppAccentPreset.defaultPreset.rawValue
    @AppStorage(AppearancePreferences.customAccentHexKey)
    private var customAccentHex = AppearancePreferences.defaultCustomAccentHex
    @AppStorage(PlayerDebugPreferences.overlayEnabledKey)
    private var playerDebugOverlayEnabled = false
    @AppStorage(PlaybackLanguagePreferences.preferredAudioLanguageKey)
    private var preferredAudioLanguage = PlaybackLanguagePreferences.defaultLanguage
    @AppStorage(PlaybackLanguagePreferences.preferredSubtitleLanguageKey)
    private var preferredSubtitleLanguage = PlaybackLanguagePreferences.defaultLanguage
    @AppStorage(PlaybackLanguagePreferences.subtitlesEnabledKey)
    private var preferredSubtitlesEnabled = true

    var body: some View {
        Form {
            Section {
                Picker("Colour mode", selection: $appearanceModeRawValue) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance-mode-picker")

                VStack(alignment: .leading, spacing: 12) {
                    Text("Accent Colour")
                        .font(.subheadline.weight(.semibold))

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 54), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(AppAccentPreset.selectablePresets) { preset in
                            Button {
                                accentPresetRawValue = preset.rawValue
                            } label: {
                                VStack(spacing: 6) {
                                    ZStack {
                                        Circle()
                                            .fill(preset.color)
                                        Circle()
                                            .stroke(
                                                presetIsSelected(preset)
                                                    ? Color.primary
                                                    : Color.secondary.opacity(0.25),
                                                lineWidth: presetIsSelected(preset) ? 3 : 1
                                            )
                                        if presetIsSelected(preset) {
                                            Image(systemName: "checkmark")
                                                .font(.caption.bold())
                                                .foregroundStyle(
                                                    preset.referenceRGB.prefersDarkForeground
                                                        ? Color.black
                                                        : Color.white
                                                )
                                        }
                                    }
                                    .frame(width: 34, height: 34)
                                    Text(preset.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(preset.title) accent")
                            .accessibilityValue(
                                presetIsSelected(preset) ? "Selected" : "Not selected"
                            )
                            .accessibilityIdentifier("appearance-accent-\(preset.rawValue)")
                        }
                    }
                }
                .padding(.vertical, 4)

                ColorPicker(
                    "Custom Colour",
                    selection: customAccentBinding,
                    supportsOpacity: false
                )
                .accessibilityValue(customAccentHex)
                .accessibilityIdentifier("appearance-custom-color")

                HStack(spacing: 12) {
                    Image(systemName: "hare.fill")
                        .font(.title2)
                        .foregroundStyle(Color.appAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Theme preview")
                            .font(.subheadline.weight(.semibold))
                        Text(selectedAppearanceSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(Color.appOnAccent)
                        .frame(width: 30, height: 30)
                        .background(Color.appAccent, in: Circle())
                }
                .padding(12)
                .background(Color.appCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.appHairline, lineWidth: 0.5)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("appearance-preview")

                Button {
                    AppearancePreferences.reset()
                    appearanceModeRawValue = AppAppearanceMode.defaultMode.rawValue
                    accentPresetRawValue = AppAccentPreset.defaultPreset.rawValue
                    customAccentHex = AppearancePreferences.defaultCustomAccentHex
                } label: {
                    Label("Reset Appearance", systemImage: "arrow.counterclockwise")
                }
                .foregroundStyle(Color.appAccent)
                .accessibilityIdentifier("appearance-reset")
            } header: {
                Text("Appearance")
            } footer: {
                Text("System follows your iPhone. Your colour and mode are saved for future launches.")
            }

            Section {
                ForEach(StremioInternalPlayer.allCases) { player in
                    Button {
                        selectedPlayer = player
                        StremioInternalPlayer.select(player)
                    } label: {
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(player.title)
                                    .foregroundStyle(.primary)
                                Text(player.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedPlayer == player {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.appAccent)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("player-option-\(player.rawValue)")
                    .accessibilityValue(selectedPlayer == player ? "Selected" : "Not selected")
                }
            } header: {
                Text("Player")
            } footer: {
                Text("Bunny keeps playback inside its Apple and custom FFmpeg engines. Other choices may use a compatibility player only after their own path is exhausted.")
            }

            Section("Preferred player") {
                LabeledContent("Player", value: selectedPlayer.title)
                LabeledContent("Controls", value: selectedPlayer.controlsSummary)
                LabeledContent("Playback", value: "MP4 / MKV / HLS / torrent")
            }

            Section("Subtitles") {
                NavigationLink {
                    SubtitleStyleSettingsView()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Subtitle Style")
                            Text("Size, color, weight, background, and shadow")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "captions.bubble.fill")
                            .foregroundStyle(Color.appAccent)
                    }
                }
                .accessibilityIdentifier("subtitle-style-link")
            }

            Section {
                LabeledContent(
                    "Preferred Audio",
                    value: languageName(preferredAudioLanguage)
                )
                .accessibilityIdentifier("preferred-audio-language")

                Toggle("Use Preferred Subtitles", isOn: $preferredSubtitlesEnabled)
                    .tint(Color.appAccent)
                    .accessibilityIdentifier("preferred-subtitles-toggle")

                if preferredSubtitlesEnabled {
                    LabeledContent(
                        "Preferred Subtitles",
                        value: languageName(preferredSubtitleLanguage)
                    )
                    .accessibilityIdentifier("preferred-subtitle-language")
                }

                Button {
                    preferredAudioLanguage = PlaybackLanguagePreferences.defaultLanguage
                    preferredSubtitleLanguage = PlaybackLanguagePreferences.defaultLanguage
                    preferredSubtitlesEnabled = true
                } label: {
                    Label("Prefer English for Both", systemImage: "character.book.closed.fill")
                }
                .foregroundStyle(Color.appAccent)
                .accessibilityIdentifier("prefer-english-tracks")
            } header: {
                Text("Playback Languages")
            } footer: {
                Text("English is the default. Audio and subtitle choices made in a player are remembered and restored after a stream switch.")
            }

            Section {
                Toggle(isOn: $playerDebugOverlayEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Player Debug")
                        Text("Show live playback diagnostics over the video")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Color.appAccent)
                .accessibilityIdentifier("player-debug-toggle")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Shows the active decoder, display FPS, dropped frames, stalls, and buffered time. Leave it off for normal viewing.")
            }
        }
        .navigationTitle("Settings")
        .onAppear { selectedPlayer = StremioInternalPlayer.selected }
    }

    private var customAccentBinding: Binding<Color> {
        Binding(
            get: {
                let rgb = AppearancePreferences.customAccent()
                return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
            },
            set: { newColor in
                let resolved = UIColor(newColor)
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                    return
                }
                customAccentHex = AppThemeRGB(
                    red: Double(red),
                    green: Double(green),
                    blue: Double(blue)
                ).hexString
                accentPresetRawValue = AppAccentPreset.custom.rawValue
            }
        )
    }

    private var selectedAppearanceSummary: String {
        let mode = AppAppearanceMode(rawValue: appearanceModeRawValue) ?? .defaultMode
        let preset = AppAccentPreset(rawValue: accentPresetRawValue) ?? .defaultPreset
        let colour = preset == .custom ? "Custom \(customAccentHex)" : preset.title
        return "\(mode.title) mode · \(colour)"
    }

    private func presetIsSelected(_ preset: AppAccentPreset) -> Bool {
        accentPresetRawValue == preset.rawValue
    }

    private func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forLanguageCode: identifier)?.capitalized
            ?? identifier.uppercased()
    }
}

struct SubtitleStyleSettingsView: View {
    @AppStorage(SubtitleStylePreferences.sizeKey)
    private var sizeRawValue = SubtitleStyle.default.size.rawValue
    @AppStorage(SubtitleStylePreferences.colorKey)
    private var colorRawValue = SubtitleStyle.default.color.rawValue
    @AppStorage(SubtitleStylePreferences.weightKey)
    private var weightRawValue = SubtitleStyle.default.weight.rawValue
    @AppStorage(SubtitleStylePreferences.backgroundOpacityKey)
    private var backgroundOpacity = SubtitleStyle.default.backgroundOpacity
    @AppStorage(SubtitleStylePreferences.shadowEnabledKey)
    private var shadowEnabled = SubtitleStyle.default.shadowEnabled

    var body: some View {
        Form {
            Section("Preview") {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.11, blue: 0.18),
                            Color(red: 0.17, green: 0.10, blue: 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "film.stack.fill")
                        .font(.system(size: 58, weight: .light))
                        .foregroundStyle(.white.opacity(0.10))
                        .accessibilityHidden(true)

                    StyledSubtitleText(
                        "This is how your subtitles will look.",
                        style: visualStyle
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Subtitle style preview")
                .accessibilityIdentifier("subtitle-style-preview")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Text") {
                Picker("Size", selection: $sizeRawValue) {
                    ForEach(SubtitleSizePreset.allCases, id: \.self) { size in
                        Text(size.compactTitle)
                            .tag(size.rawValue)
                            .accessibilityLabel(size.title)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("subtitle-style-size")

                LabeledContent("Color") {
                    HStack(spacing: 11) {
                        ForEach(SubtitleColorPreset.allCases, id: \.self) { color in
                            Button {
                                colorRawValue = color.rawValue
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(SubtitleVisualStyle(
                                            SubtitleStyle(color: color)
                                        ).color)
                                    Circle()
                                        .stroke(
                                            colorRawValue == color.rawValue
                                                ? Color.appAccent : Color.secondary.opacity(0.35),
                                            lineWidth: colorRawValue == color.rawValue ? 3 : 1
                                        )
                                    if colorRawValue == color.rawValue {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.black.opacity(0.72))
                                    }
                                }
                                .frame(width: 30, height: 30)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.title)
                            .accessibilityValue(
                                colorRawValue == color.rawValue ? "Selected" : "Not selected"
                            )
                            .accessibilityIdentifier("subtitle-color-\(color.rawValue)")
                        }
                    }
                }
                .accessibilityIdentifier("subtitle-style-color")

                Picker("Weight", selection: $weightRawValue) {
                    ForEach(SubtitleWeightPreset.allCases, id: \.self) { weight in
                        Text(weight == .semibold ? "Semi" : weight.title)
                            .tag(weight.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("subtitle-style-weight")
            }

            Section {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("Background")
                        Spacer()
                        Text("\(Int((backgroundOpacity * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $backgroundOpacity, in: 0...0.9, step: 0.05)
                        .tint(Color.appAccent)
                        .accessibilityLabel("Subtitle background opacity")
                }
                .accessibilityIdentifier("subtitle-style-background-opacity")

                Toggle("Text Shadow", isOn: $shadowEnabled)
                    .tint(Color.appAccent)
                    .accessibilityIdentifier("subtitle-style-shadow")
            } header: {
                Text("Readability")
            } footer: {
                Text("These settings are used by Bunny, KSPlayer, VLC, and AVPlayer.")
            }

            Section {
                Button {
                    resetToDefaults()
                } label: {
                    Label("Reset to Default", systemImage: "arrow.counterclockwise")
                }
                .foregroundStyle(Color.appAccent)
                .accessibilityIdentifier("subtitle-style-reset")
            }
        }
        .navigationTitle("Subtitle Style")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("subtitle-style-settings")
    }

    private var visualStyle: SubtitleVisualStyle {
        SubtitleVisualStyle(
            SubtitleStyle(
                sizeRawValue: sizeRawValue,
                colorRawValue: colorRawValue,
                weightRawValue: weightRawValue,
                backgroundOpacity: backgroundOpacity,
                shadowEnabled: shadowEnabled
            )
        )
    }

    private func resetToDefaults() {
        let fallback = SubtitleStyle.default
        sizeRawValue = fallback.size.rawValue
        colorRawValue = fallback.color.rawValue
        weightRawValue = fallback.weight.rawValue
        backgroundOpacity = fallback.backgroundOpacity
        shadowEnabled = fallback.shadowEnabled
    }
}

struct AccountView: View {
    @EnvironmentObject private var model: AppModel
    @State private var email = ""
    @State private var password = ""
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        Form {
            if let accountEmail = model.accountEmail {
                Section("Stremio account") {
                    LabeledContent("Signed in", value: accountEmail)
                    LabeledContent("Sync", value: model.accountSyncStatus)
                    Button("Sync now") {
                        Task {
                            busy = true
                            defer { busy = false }
                            do { try await model.syncAccount() }
                            catch { status = error.localizedDescription }
                        }
                    }
                    .disabled(busy)
                    Button("Sign out", role: .destructive) {
                        Task { await model.signOut() }
                    }
                }
            } else {
                Section("Sign in to Stremio") {
                    TextField("Email", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                    SecureField("Password", text: $password)
                    Button("Sign in and sync") {
                        Task {
                            busy = true
                            defer { busy = false }
                            do {
                                try await model.signIn(email: email, password: password)
                                password = ""
                            } catch {
                                status = error.localizedDescription
                            }
                        }
                    }
                    .disabled(email.isEmpty || password.isEmpty || busy)
                }
            }

            Section("Synchronized data") {
                Label("Library and removals", systemImage: "bookmark")
                Label("Installed add-ons", systemImage: "shippingbox")
                Label(SessionStore.storageDescription, systemImage: "key")
            }
            if let status { Text(status).foregroundStyle(.secondary) }
        }
        .navigationTitle("Account")
    }
}

struct E2EStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: model.e2eResult == nil ? "waveform" : "checkmark.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(model.e2eResult == nil ? Color.appAccent : .green)
            if let result = model.e2eResult {
                Text("E2E PASS").font(.largeTitle.bold()).foregroundStyle(.green)
                resultRow("Manifest", result.manifest)
                resultRow("Catalog", "\(result.catalogCount) item")
                resultRow("Letterboxd + pages", "\(result.letterboxdCatalogCount) items")
                resultRow("Source switch", result.sourceSwitchAndPaging ? "dropdown + page 2" : "failed")
                resultRow("Global search", result.globalSearch ? "all searchable catalogs" : "failed")
                resultRow("Details", result.detail)
                resultRow("Streams", "\(result.streamCount) direct + torrent")
                resultRow("Providers", result.providerGrouping ? "grouped by add-on" : "failed")
                resultRow("KSPlayer MP4", String(format: "%.1f ms", result.ksDirectStartupMilliseconds))
                resultRow("KSPlayer HLS", String(format: "%.1f ms", result.ksHLSStartupMilliseconds))
                resultRow("KSPlayer MKV/AV1", String(format: "%.1f ms", result.ksContainerStartupMilliseconds))
                resultRow("KSPlayer torrent", String(format: "%.1f ms", result.ksTorrentStartupMilliseconds))
                resultRow("Library", result.libraryRoundTrip ? "add + persist + remove" : "failed")
                resultRow("Account", result.accountSync ? "login + pull + push" : "failed")
                resultRow(
                    "Session storage",
                    result.sessionPersistenceRoundTrip ? "save + load + delete" : "failed"
                )
            } else if let error = model.e2eError {
                Text("E2E FAIL").font(.largeTitle.bold()).foregroundStyle(.red)
                Text(error).multilineTextAlignment(.center)
            } else {
                ProgressView("Running full workflow…")
            }
        }
        .padding(28)
        .accessibilityIdentifier("e2e-status")
    }

    private func resultRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(.secondary)
            Spacer()
            Text(value).bold().multilineTextAlignment(.trailing)
        }
    }
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
