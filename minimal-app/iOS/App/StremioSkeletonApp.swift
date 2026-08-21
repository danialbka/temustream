import SwiftUI

@main
struct StremioSkeletonApp: App {
    @UIApplicationDelegateAdaptor(AppOrientationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if let playerStressURL {
                    PlayerStressScreen(url: playerStressURL)
                } else if let playerFixtureURL {
                    NavigationStack {
                        PlayerScreen(url: playerFixtureURL, title: "Player layout verification fixture")
                    }
                } else {
                    RootView()
                        .environmentObject(model)
                        .task { await model.start() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .preferredColorScheme(.dark)
        }
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
    private var playerFixtureURL: URL? {
        #if targetEnvironment(simulator)
        guard let value = ProcessInfo.processInfo.environment["SKELETON_PLAYER_FIXTURE_URL"] else {
            return nil
        }
        return URL(string: value)
        #else
        return nil
        #endif
    }
}
