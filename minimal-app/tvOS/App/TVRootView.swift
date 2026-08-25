import Foundation
import SwiftUI

private enum TVTab: String, Hashable {
  case home
  case search
  case library
  case addons
  case settings
}

struct TVRootView: View {
  @State private var selectedTab: TVTab

  init() {
    let requestedTab = ProcessInfo.processInfo.environment["SKELETON_SELECTED_TAB"] ?? "home"
    _selectedTab = State(initialValue: TVTab(rawValue: requestedTab) ?? .home)
  }

  var body: some View {
    TabView(selection: $selectedTab) {
      NavigationStack {
        TVHomeView()
      }
      .tabItem { Label("Home", systemImage: "house.fill") }
      .tag(TVTab.home)

      NavigationStack {
        TVSearchView()
      }
      .tabItem { Label("Search", systemImage: "magnifyingglass") }
      .tag(TVTab.search)

      NavigationStack {
        TVLibraryView()
      }
      .tabItem { Label("My List", systemImage: "bookmark.fill") }
      .tag(TVTab.library)

      NavigationStack {
        TVAddonsView()
      }
      .tabItem { Label("Add-ons", systemImage: "shippingbox.fill") }
      .tag(TVTab.addons)

      NavigationStack {
        TVSettingsView()
      }
      .tabItem { Label("Settings", systemImage: "gearshape.fill") }
      .tag(TVTab.settings)
    }
    .tabViewStyle(.sidebarAdaptable)
    .background(TVTheme.background.ignoresSafeArea())
    .accessibilityIdentifier("tvos-root")
  }
}
