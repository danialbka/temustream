#if SKELETON_SCREENSHOT_HARNESS
import Foundation
import SwiftUI

/// Deterministic, simulator-only entry point used by ui-state-screenshots.sh.
/// Production builds do not compile this declaration.
@main
struct UIStateScreenshotApp: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var watchTogether = WatchTogetherModel()
    private let state = ProcessInfo.processInfo.environment["UI_SCREENSHOT_STATE"] ?? "home-cinemeta"

    init() {
        let environment = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        if let mode = environment["SKELETON_APPEARANCE_MODE"] {
            defaults.set(mode, forKey: AppearancePreferences.modeKey)
        }
        if let preset = environment["SKELETON_ACCENT_PRESET"] {
            defaults.set(preset, forKey: AppearancePreferences.accentPresetKey)
        }
        if let customHex = environment["SKELETON_CUSTOM_ACCENT_HEX"] {
            defaults.set(customHex, forKey: AppearancePreferences.customAccentHexKey)
        }
    }

    var body: some Scene {
        WindowGroup {
            AppThemeHost {
                UIStateScreenshotRoot(state: state)
                    .environmentObject(model)
                    .environmentObject(watchTogether)
            }
        }
    }
}

private struct UIStateScreenshotRoot: View {
    @EnvironmentObject private var model: AppModel
    let state: String
    @State private var prepared = false

    var body: some View {
        Group {
            if needsPreparation && !prepared {
                loadingCatalog
            } else {
                content
            }
        }
        .task { await prepare() }
    }

    private var needsPreparation: Bool {
        [
            "home-cinemeta", "home-letterboxd", "home-series",
            "home-light-custom-theme", "catalog-error",
            "details-streams", "details-resume", "details-series-episodes", "episode-streams",
            "episode-up-next",
            "details-trailer-active", "library-synced", "account-signed-in",
            "settings-player-legacy-av",
        ].contains(state)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case "catalog-loading":
            loadingCatalog
        case "catalog-error", "home-cinemeta", "home-letterboxd", "home-series",
             "home-light-custom-theme":
            screenTab(label: "Home", systemImage: "rectangle.grid.2x2") {
                NavigationStack { HomeView() }
            }
        case "details-streams":
            NavigationStack {
                DetailsView(seed: fixtureItem)
            }
        case "details-resume":
            NavigationStack {
                DetailsView(seed: fixtureItem)
            }
        case "details-trailer-active":
            NavigationStack {
                DetailsView(seed: fixtureItem)
            }
        case "details-series-episodes":
            NavigationStack {
                DetailsView(seed: fixtureSeriesItem)
            }
        case "episode-streams":
            NavigationStack {
                EpisodeStreamsView(series: fixtureSeriesItem, episode: fixtureEpisodeTwo)
            }
        case "episode-up-next":
            NavigationStack {
                ResolvingPlayerScreen(
                    candidates: episodePlaybackCandidates,
                    episodeAutoplayContext: EpisodeAutoplayContext(
                        series: fixtureSeriesItem,
                        episode: fixtureEpisodeOne
                    )
                )
            }
        case "library-empty":
            screenTab(label: "Library", systemImage: "bookmark") {
                NavigationStack { LibraryView() }
            }
        case "library-synced":
            screenTab(label: "Library", systemImage: "bookmark") {
                NavigationStack { SyncedLibrarySnapshotView(item: fixtureItem) }
            }
        case "addons-offline":
            screenTab(label: "Add-ons", systemImage: "shippingbox") {
                NavigationStack { AddonsView() }
            }
        case "settings-player", "settings-player-legacy-av", "settings-appearance-light":
            screenTab(label: "Settings", systemImage: "gearshape") {
                NavigationStack { SettingsView() }
            }
        case "settings-subtitles":
            NavigationStack { SubtitleStyleSettingsView() }
        case "account-signed-out":
            screenTab(label: "Account", systemImage: "person.crop.circle") {
                NavigationStack { AccountView() }
            }
        case "account-signed-in":
            screenTab(label: "Account", systemImage: "person.crop.circle") {
                NavigationStack { SignedInAccountSnapshotView() }
            }
        case "torrent-starting":
            NavigationStack {
                ProgressView("Starting torrent…")
                    .navigationTitle("Fixture torrent")
                    .navigationBarTitleDisplayMode(.inline)
            }
        case "playback-unavailable":
            NavigationStack {
                ResolvingPlayerScreen(stream: invalidStream)
                    .navigationTitle("Broken stream")
                    .navigationBarTitleDisplayMode(.inline)
            }
        case "stream-failover-countdown":
            NavigationStack {
                ResolvingPlayerScreen(candidates: failoverCandidates)
                    .navigationTitle("Automatic recovery")
                    .navigationBarTitleDisplayMode(.inline)
            }
        case "player-active":
            NavigationStack {
                PlayerScreen(url: fixtureVideoURL, title: "Big Buck Bunny")
            }
        default:
            Text("Unknown UI state: \(state)")
        }
    }

    private var loadingCatalog: some View {
        screenTab(label: "Home", systemImage: "rectangle.grid.2x2") {
            NavigationStack {
                ProgressView("Loading catalog…")
                    .navigationTitle("Discover")
                    .navigationBarTitleDisplayMode(.inline)
                    .searchable(text: .constant(""), prompt: "Search catalog")
            }
        }
    }

    private func screenTab<Content: View>(
        label: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        TabView(selection: .constant(label)) {
            content()
                .tabItem { Label(label, systemImage: systemImage) }
                .tag(label)
        }
    }

    private func prepare() async {
        switch state {
        case "home-cinemeta", "home-letterboxd", "home-series",
             "home-light-custom-theme", "catalog-error",
             "details-streams", "details-trailer-active":
            await model.start()
            if state == "home-series" {
                model.recordPlaybackProgress(
                    contentIdentifier: EpisodePlaybackIdentity.contentIdentifier(
                        seriesID: fixtureSeriesItem.id,
                        videoID: fixtureEpisodeTwo.id
                    ),
                    contentTitle: EpisodePlaybackIdentity.contentTitle(
                        seriesTitle: fixtureSeriesItem.name,
                        video: fixtureEpisodeTwo
                    ),
                    stream: fixtureStream,
                    providerName: "Cinemeta Fixture",
                    position: 1_200,
                    duration: 3_600,
                    mediaMetadata: .episode(
                        series: fixtureSeriesItem,
                        episode: fixtureEpisodeTwo
                    )
                )
            }
            prepared = true
        case "details-resume":
            await model.start()
            model.recordPlaybackProgress(
                contentIdentifier: "movie:\(fixtureItem.id)",
                contentTitle: fixtureItem.name,
                stream: fixtureStream,
                providerName: "Cinemeta Fixture",
                position: 1_572,
                duration: 3_600
            )
            prepared = true
        case "details-series-episodes", "episode-streams", "episode-up-next":
            await model.start()
            model.recordPlaybackProgress(
                contentIdentifier: EpisodePlaybackIdentity.contentIdentifier(
                    seriesID: fixtureSeriesItem.id,
                    videoID: fixtureEpisodeOne.id
                ),
                contentTitle: EpisodePlaybackIdentity.contentTitle(
                    seriesTitle: fixtureSeriesItem.name,
                    video: fixtureEpisodeOne
                ),
                stream: fixtureStream,
                providerName: "Cinemeta Fixture",
                position: 3_590,
                duration: 3_600,
                mediaMetadata: .episode(
                    series: fixtureSeriesItem,
                    episode: fixtureEpisodeOne
                )
            )
            model.recordPlaybackProgress(
                contentIdentifier: EpisodePlaybackIdentity.contentIdentifier(
                    seriesID: fixtureSeriesItem.id,
                    videoID: fixtureEpisodeTwo.id
                ),
                contentTitle: EpisodePlaybackIdentity.contentTitle(
                    seriesTitle: fixtureSeriesItem.name,
                    video: fixtureEpisodeTwo
                ),
                stream: fixtureStream,
                providerName: "Cinemeta Fixture",
                position: 1_200,
                duration: 3_600,
                mediaMetadata: .episode(
                    series: fixtureSeriesItem,
                    episode: fixtureEpisodeTwo
                )
            )
            prepared = true
        case "settings-player-legacy-av":
            let defaults = UserDefaults.standard
            defaults.set("avplayer", forKey: "preferredInternalPlayer")
            defaults.set(true, forKey: "useAVPlayer")
            guard StremioInternalPlayer.selected == .bunny,
                  defaults.string(forKey: "preferredInternalPlayer") == "bunny",
                  !defaults.bool(forKey: "useAVPlayer")
            else {
                fatalError("Deprecated AVPlayer preference did not migrate to Bunny")
            }
            prepared = true
        default:
            prepared = true
        }

        // Let AsyncImage, navigation chrome, and detail resolution settle before capture.
        // The Up Next card is presented by a child task after the player first appears,
        // so its fixture needs an additional render turn before declaring itself ready.
        let readinessDelayMilliseconds: Int
        if state == "episode-up-next" {
            readinessDelayMilliseconds = 3_000
        } else if state == "details-streams" || state == "details-resume"
                    || state == "details-series-episodes" || state == "episode-streams"
                    || state == "details-trailer-active" {
            readinessDelayMilliseconds = 1_500
        } else {
            readinessDelayMilliseconds = 650
        }
        try? await Task.sleep(for: .milliseconds(readinessDelayMilliseconds))
        let runID = ProcessInfo.processInfo.environment["UI_SCREENSHOT_RUN_ID"] ?? "manual"
        let readyMarker = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-state-\(runID).ready")
        try? Data("READY".utf8).write(to: readyMarker, options: .atomic)
        NSLog("[UIState:%@:%@] READY", runID, state)
    }

    private var fixtureItem: MetaItem {
        MetaItem(
            id: "tt1254207",
            type: "movie",
            name: "Big Buck Bunny",
            poster: URL(string: "http://127.0.0.1:18766/ui-states/poster-portrait.png"),
            description: "A cheerful open movie used to verify the complete playback workflow.",
            releaseInfo: "2008",
            genres: ["Animation", "Comedy"]
        )
    }

    private var fixtureVideoURL: URL {
        URL(string: "http://127.0.0.1:18766/sample.mp4")!
    }

    private var fixtureSeriesItem: MetaItem {
        MetaItem(
            id: "tt-fixture-series",
            type: "series",
            name: "Fixture Show",
            poster: URL(string: "http://127.0.0.1:18766/ui-states/poster-portrait.png"),
            description: "A deterministic series used to verify episode playback state.",
            releaseInfo: "2024–",
            genres: ["Drama", "Adventure"],
            videos: [fixtureEpisodeOne, fixtureEpisodeTwo],
            trailerStreams: [
                TrailerStream(title: "Official trailer", youtubeID: "yUQM7H4Swgw")
            ]
        )
    }

    private var fixtureEpisodeOne: Video {
        Video(
            id: "tt-fixture-series:1:1",
            title: "First Light",
            season: 1,
            episode: 1,
            overview: "A missing signal draws the crew toward a dangerous first encounter.",
            released: "2024-01-05T00:00:00.000Z"
        )
    }

    private var fixtureEpisodeTwo: Video {
        Video(
            id: "tt-fixture-series:1:2",
            title: "The Crossing",
            season: 1,
            episode: 2,
            thumbnail: URL(string: "http://127.0.0.1:18766/ui-states/episode-2.png"),
            overview: "The team crosses hostile terrain while an old alliance begins to fracture.",
            released: "2024-01-12T00:00:00.000Z"
        )
    }

    private var fixtureStream: Stream {
        Stream(
            url: fixtureVideoURL,
            externalUrl: nil,
            name: "Local H.264 stream",
            title: "1080p · Direct",
            description: nil,
            infoHash: nil,
            fileIdx: nil,
            sources: nil
        )
    }

    private var invalidStream: Stream {
        Stream(
            url: nil,
            externalUrl: nil,
            name: "Unavailable fixture",
            title: "Broken stream",
            description: nil,
            infoHash: nil,
            fileIdx: nil,
            sources: nil
        )
    }

    private var failoverCandidates: [StreamPlaybackCandidate] {
        [
            StreamPlaybackCandidate(
                stream: fixtureStream,
                providerName: "Fixture Provider",
                contentIdentifier: "movie:tt1254207",
                contentTitle: "Big Buck Bunny",
                sourceID: "fixture-broken"
            ),
            StreamPlaybackCandidate(
                stream: Stream(
                    url: fixtureVideoURL,
                    externalUrl: nil,
                    name: "English 1080p backup",
                    title: "1080p · Backup stream",
                    description: nil,
                    infoHash: nil,
                    fileIdx: nil,
                    sources: nil
                ),
                providerName: "Backup Provider",
                contentIdentifier: "movie:tt1254207",
                contentTitle: "Big Buck Bunny",
                sourceID: "fixture-backup"
            ),
        ]
    }

    private var episodePlaybackCandidates: [StreamPlaybackCandidate] {
        [
            StreamPlaybackCandidate(
                stream: fixtureStream,
                providerName: "Cinemeta Fixture",
                contentIdentifier: EpisodePlaybackIdentity.contentIdentifier(
                    seriesID: fixtureSeriesItem.id,
                    videoID: fixtureEpisodeOne.id
                ),
                contentTitle: EpisodePlaybackIdentity.contentTitle(
                    seriesTitle: fixtureSeriesItem.name,
                    video: fixtureEpisodeOne
                ),
                sourceID: "fixture-episode-one"
            )
        ]
    }
}

private struct SyncedLibrarySnapshotView: View {
    let item: MetaItem

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 16)], spacing: 20) {
                PosterCard(item: item)
            }
            .padding()
        }
        .navigationTitle("Library")
    }
}

private struct SignedInAccountSnapshotView: View {
    var body: some View {
        Form {
            Section("Stremio account") {
                LabeledContent("Signed in", value: "e2e@example.test")
                LabeledContent("Sync", value: "Synced now")
                Button("Sync now") {}
                Button("Sign out", role: .destructive) {}
            }
            Section("Synchronized data") {
                Label("Library and removals", systemImage: "bookmark")
                Label("Installed add-ons", systemImage: "shippingbox")
                Label(SessionStore.storageDescription, systemImage: "key")
            }
        }
        .navigationTitle("Account")
    }
}
#endif
