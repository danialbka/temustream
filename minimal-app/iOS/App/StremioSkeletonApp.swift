import SwiftUI

@main
struct StremioSkeletonApp: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            appContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(.dark)
            .overlay(alignment: .top) {
                WatchTogetherSessionBanner()
            }
            .task {
                WatchTogetherCoordinator.shared.startObservingSessions()
            }
        }
    }

    @ViewBuilder
    private var appContent: some View {
        if providerPlayerAuditRequested {
            ProviderPlayerAuditScreen()
                .environmentObject(model)
        } else {
            platformAppContent
        }
    }

    @ViewBuilder
    private var platformAppContent: some View {
        #if targetEnvironment(simulator)
        if let playerStressURL {
            PlayerStressScreen(url: playerStressURL)
        } else if let playerFixturePlan {
            NavigationStack {
                PlayerScreen(
                    plan: playerFixturePlan,
                    title: ProcessInfo.processInfo.environment[
                        "SKELETON_PLAYER_FIXTURE_TITLE"
                    ] ?? "Player layout verification fixture"
                )
            }
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

    /// Simulator-only route used to validate the production KSPlayer surface.
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
            requiresCompatibilityPlayback: compatibilityURL != nil
        )
        #else
        return nil
        #endif
    }

    private var providerPlayerAuditRequested: Bool {
        ProcessInfo.processInfo.environment["SKELETON_PROVIDER_PLAYER_AUDIT"] == "1"
    }
}
