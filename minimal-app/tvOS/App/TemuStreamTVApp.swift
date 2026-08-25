import SwiftUI

@main
struct TemuStreamTVApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      TVRootView()
        .environmentObject(model)
        .tint(TVTheme.accent)
        .preferredColorScheme(.dark)
        .task { await model.start() }
    }
  }
}
