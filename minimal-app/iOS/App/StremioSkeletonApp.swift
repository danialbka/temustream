import SwiftUI

@main
struct StremioSkeletonApp: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var watchTogether = WatchTogetherModel()

    var body: some Scene {
        WindowGroup {
            AppThemeHost {
                appContent
                    .environmentObject(watchTogether)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var appContent: some View {
        platformAppContent
    }

    @ViewBuilder
    private var platformAppContent: some View {
        #if targetEnvironment(simulator)
        if recommendationPaginationFixtureRequested {
            NavigationStack { HomeView() }
                .environmentObject(model)
                .task { model.prepareRecommendationPaginationFixture() }
        } else if continueWatchingNavigationFixtureRequested {
            NavigationStack { HomeView() }
                .environmentObject(model)
                .task { model.prepareContinueWatchingNavigationFixture() }
        } else if let fixture = episodeAutoplayFixture {
            if episodeAutoplayFixtureManualStart {
                SimulatorEpisodeAutoplayFixtureScreen(fixture: fixture)
                    .environmentObject(model)
            } else {
                NavigationStack {
                    ResolvingPlayerScreen(
                        candidates: fixture.candidates,
                        minimumVideoDuration: 4,
                        episodeAutoplayContext: fixture.context
                    )
                }
                .environmentObject(model)
                .task { await model.start() }
            }
        } else if let playerStressURL {
            if playerStressBenchmarkRequested {
                PlayerStressScreen(url: playerStressURL)
            } else {
                NavigationStack {
                    PlayerScreen(url: playerStressURL, title: "Bunny stress fixture")
                }
            }
        } else if let fixture = mpegTransportBridgeFixture {
            SimulatorMPEGTransportBridgeFixtureScreen(fixture: fixture)
        } else if let playerFixturePlan {
            if playerFixtureManualStart {
                SimulatorPlayerFixtureScreen(
                    plan: playerFixturePlan,
                    title: playerFixtureTitle,
                    initialPosition: playerFixtureInitialPosition
                )
            } else {
                NavigationStack {
                    PlayerScreen(
                        plan: playerFixturePlan,
                        title: playerFixtureTitle,
                        initialPosition: playerFixtureInitialPosition
                    )
                }
            }
        } else if providerPlayerAuditRequested {
            ProviderPlayerAuditScreen()
                .environmentObject(model)
        } else {
            standardAppContent
        }
        #else
        standardAppContent
        #endif
    }

    private var standardAppContent: some View {
        RootView()
            .environmentObject(model)
            .task { await model.start() }
            .task { await watchTogether.start() }
    }

    private var playerStressURL: URL? {
        #if targetEnvironment(simulator)
        guard let value = ProcessInfo.processInfo.environment["SKELETON_PLAYER_STRESS_URL"] else {
            return nil
        }
        return URL(string: value)
        #else
        return nil
        #endif
    }

    private var playerStressBenchmarkRequested: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment[
            "SKELETON_PLAYER_STRESS_BENCHMARK"
        ] == "1"
        #else
        false
        #endif
    }

    #if targetEnvironment(simulator)
    private var recommendationPaginationFixtureRequested: Bool {
        ProcessInfo.processInfo.environment[
            "SKELETON_RECOMMENDATION_PAGING_FIXTURE"
        ] == "1"
    }

    private var continueWatchingNavigationFixtureRequested: Bool {
        ProcessInfo.processInfo.environment[
            "SKELETON_CONTINUE_WATCHING_NAVIGATION_FIXTURE"
        ] == "1"
    }

    private var episodeAutoplayFixture: SimulatorEpisodeAutoplayFixture? {
        guard let value = ProcessInfo.processInfo.environment[
            "SKELETON_EPISODE_AUTOPLAY_FIXTURE_URL"
        ], let url = URL(string: value) else {
            return nil
        }
        return SimulatorEpisodeAutoplayFixture(url: url)
    }

    private var mpegTransportBridgeFixture: SimulatorMPEGTransportBridgeFixture? {
        guard let rawURL = ProcessInfo.processInfo.environment[
            "SKELETON_MPEGTS_BRIDGE_FIXTURE_URL"
        ], let upstreamURL = URL(string: rawURL),
              let rawLength = ProcessInfo.processInfo.environment[
                "SKELETON_MPEGTS_BRIDGE_FIXTURE_LENGTH"
              ], let contentLength = Int64(rawLength), contentLength > 0
        else { return nil }
        return SimulatorMPEGTransportBridgeFixture(
            upstreamURL: upstreamURL,
            contentLength: contentLength,
            initialPosition: max(
                TimeInterval(
                    ProcessInfo.processInfo.environment[
                        "SKELETON_MPEGTS_BRIDGE_FIXTURE_INITIAL_POSITION"
                    ] ?? ""
                ) ?? 0,
                0
            )
        )
    }
    #endif

    private var episodeAutoplayFixtureManualStart: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment[
            "SKELETON_EPISODE_AUTOPLAY_FIXTURE_MANUAL_START"
        ] == "1"
        #else
        false
        #endif
    }

    private var playerFixtureManualStart: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.environment[
            "SKELETON_PLAYER_FIXTURE_MANUAL_START"
        ] == "1"
        #else
        false
        #endif
    }

    private var playerFixtureTitle: String {
        ProcessInfo.processInfo.environment[
            "SKELETON_PLAYER_FIXTURE_TITLE"
        ] ?? "Player layout verification fixture"
    }

    private var playerFixtureInitialPosition: TimeInterval {
        #if targetEnvironment(simulator)
        let rawValue = ProcessInfo.processInfo.environment[
            "SKELETON_PLAYER_FIXTURE_INITIAL_POSITION"
        ]
        return rawValue.flatMap(TimeInterval.init) ?? 0
        #else
        return 0
        #endif
    }

    /// Simulator-only route used to validate the production Bunny surface.
    /// It is compiled out of device builds and cannot affect shipped launches.
    private var playerFixturePlan: PlaybackPlan? {
        #if targetEnvironment(simulator)
        guard let value = ProcessInfo.processInfo.environment["SKELETON_PLAYER_FIXTURE_URL"] else {
            return nil
        }
        guard let primaryURL = URL(string: value) else { return nil }
        let compatibilityURL = ProcessInfo.processInfo.environment[
            "SKELETON_PLAYER_FIXTURE_COMPATIBILITY_URL"
        ].flatMap(URL.init(string:))
        return PlaybackPlan(
            primaryURL: primaryURL,
            fallbackURL: compatibilityURL,
            requiresCompatibilityPlayback: compatibilityURL != nil,
            detectedMIMEType: ProcessInfo.processInfo.environment[
                "SKELETON_PLAYER_FIXTURE_MIME_TYPE"
            ],
            trustedPrivateNetworkOrigin: primaryURL.isSimulatorLoopback
        )
        #else
        return nil
        #endif
    }

    private var providerPlayerAuditRequested: Bool {
        ProcessInfo.processInfo.environment["SKELETON_PROVIDER_PLAYER_AUDIT"] == "1"
    }
}

#if targetEnvironment(simulator)
private struct SimulatorMPEGTransportBridgeFixture: Sendable {
    let upstreamURL: URL
    let contentLength: Int64
    let initialPosition: TimeInterval
}

private struct SimulatorMPEGTransportBridgeFixtureScreen: View {
    let fixture: SimulatorMPEGTransportBridgeFixture
    @State private var playbackPlan: PlaybackPlan?
    @State private var failureMessage: String?

    var body: some View {
        NavigationStack {
            if let playbackPlan {
                PlayerScreen(
                    plan: playbackPlan,
                    title: "Captured provider MPEG-TS bridge",
                    initialPosition: fixture.initialPosition
                )
            } else if let failureMessage {
                VStack(spacing: 12) {
                    Label("Bridge fixture failed", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(failureMessage)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ProgressView("Preparing provider stream…")
            }
        }
        .task {
            do {
                let localURL = try await StreamTransportBridge.shared.localURL(
                    upstream: fixture.upstreamURL,
                    contentLength: fixture.contentLength,
                    mimeType: "video/mp2t"
                )
                playbackPlan = PlaybackPlan(
                    primaryURL: localURL,
                    fallbackURL: nil,
                    detectedMIMEType: "application/vnd.apple.mpegurl",
                    trustedPrivateNetworkOrigin: localURL
                )
                NSLog("MPEGTS_BRIDGE_FIXTURE ready url=%@", localURL.absoluteString)
            } catch {
                failureMessage = error.localizedDescription
                NSLog("MPEGTS_BRIDGE_FIXTURE failed error=%@", error.localizedDescription)
            }
        }
    }
}
#endif

#if targetEnvironment(simulator)
private extension URL {
    var isSimulatorLoopback: URL? {
        guard ["127.0.0.1", "localhost", "::1"].contains(host?.lowercased() ?? "") else {
            return nil
        }
        return self
    }
}

/// A deterministic launch route for the iOS UI test. It still exercises the
/// production ResolvingPlayerScreen autoplay flow; only its initial episode
/// and local stream are supplied by the test process.
private struct SimulatorEpisodeAutoplayFixture {
    let url: URL

    private var firstEpisode: Video {
        Video(
            id: "tt-fixture-series:1:1",
            title: "First Light",
            season: 1,
            episode: 1
        )
    }

    private var secondEpisode: Video {
        Video(
            id: "tt-fixture-series:1:2",
            title: "The Crossing",
            season: 1,
            episode: 2,
            overview: "The crew crosses hostile terrain while an old alliance begins to fracture."
        )
    }

    private var series: MetaItem {
        MetaItem(
            id: "tt-fixture-series",
            type: "series",
            name: "Fixture Show",
            videos: [firstEpisode, secondEpisode]
        )
    }

    var context: EpisodeAutoplayContext {
        EpisodeAutoplayContext(series: series, episode: firstEpisode)
    }

    var candidates: [StreamPlaybackCandidate] {
        [
            StreamPlaybackCandidate(
                stream: Stream(
                    url: url,
                    externalUrl: nil,
                    name: "Local autoplay fixture",
                    title: "H.264 direct",
                    description: nil,
                    infoHash: nil,
                    fileIdx: nil,
                    sources: nil,
                    skipSegments: [
                        PlaybackSkipSegment(
                            start: 0,
                            end: 12,
                            type: "intro",
                            title: "Skip Intro",
                            confidence: 0.99,
                            sampleSize: 12
                        ),
                    ]
                ),
                providerName: "Cinemeta Fixture",
                contentIdentifier: EpisodePlaybackIdentity.contentIdentifier(
                    seriesID: series.id,
                    videoID: firstEpisode.id
                ),
                contentTitle: EpisodePlaybackIdentity.contentTitle(
                    seriesTitle: series.name,
                    video: firstEpisode
                ),
                sourceID: "autoplay-orientation-fixture"
            ),
        ]
    }
}

/// Keeps deterministic simulator media paused until XCTest is attached. The
/// production autoplay path remains unchanged once the test starts playback.
private struct SimulatorEpisodeAutoplayFixtureScreen: View {
    let fixture: SimulatorEpisodeAutoplayFixture

    @EnvironmentObject private var model: AppModel
    @State private var modelIsReady = false
    @State private var playbackStarted = false

    var body: some View {
        Group {
            if playbackStarted {
                NavigationStack {
                    ResolvingPlayerScreen(
                        candidates: fixture.candidates,
                        minimumVideoDuration: 4,
                        episodeAutoplayContext: fixture.context
                    )
                }
            } else {
                fixtureStartSurface(isReady: modelIsReady) {
                    playbackStarted = true
                }
            }
        }
        .task {
            await model.start()
            modelIsReady = true
        }
    }
}

/// Equivalent start gate for direct-player gesture tests. It is available only
/// in simulator builds and must be explicitly requested through the test env.
private struct SimulatorPlayerFixtureScreen: View {
    let plan: PlaybackPlan
    let title: String
    let initialPosition: TimeInterval

    @State private var playbackStarted = false

    var body: some View {
        Group {
            if playbackStarted {
                NavigationStack {
                    PlayerScreen(
                        plan: plan,
                        title: title,
                        initialPosition: initialPosition
                    )
                }
            } else {
                fixtureStartSurface(isReady: true) {
                    playbackStarted = true
                }
            }
        }
    }
}

@MainActor
private func fixtureStartSurface(
    isReady: Bool,
    start: @escaping @MainActor () -> Void
) -> some View {
    ZStack {
        Color.black.ignoresSafeArea()
        Button(isReady ? "Start player fixture" : "Preparing player fixture…") {
            start()
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.appAccent)
        .foregroundStyle(.black)
        .disabled(!isReady)
        .accessibilityIdentifier("start-player-fixture")
    }
}
#endif
