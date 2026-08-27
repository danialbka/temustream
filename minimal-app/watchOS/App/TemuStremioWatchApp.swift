import SwiftUI

@main
struct TemuStremioWatchApp: App {
    @StateObject private var model = WatchAppModel()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
                .tint(
                    WatchAccentPreset(rawValue: model.accentPresetRawValue)?.color
                        ?? WatchTheme.accent
                )
                .preferredColorScheme(.dark)
        }
    }
}
