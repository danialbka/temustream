#if SKELETON_SCREENSHOT_HARNESS
import SwiftUI

/// Deterministic, simulator-only entry point used by ui-state-screenshots.sh.
/// Production builds do not compile this declaration.
@main
struct UIStateScreenshotApp: App {
    @StateObject private var model = AppModel()
    private let state = ProcessInfo.processInfo.environment["UI_SCREENSHOT_STATE"] ?? "home-cinemeta"

    var body: some Scene {
        WindowGroup {
            UIStateScreenshotRoot(state: state)
                .environmentObject(model)
                .preferredColorScheme(.dark)
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
        .tint(.orange)
        .task { await prepare() }
    }

    private var needsPreparation: Bool {
        [
            "home-cinemeta", "home-letterboxd", "catalog-error", "details-streams",
            "library-synced", "account-signed-in",
        ].contains(state)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case "catalog-loading":
            loadingCatalog
        case "catalog-error", "home-cinemeta", "home-letterboxd":
            screenTab(label: "Home", systemImage: "rectangle.grid.2x2") {
                NavigationStack { HomeView() }
            }
        case "details-streams":
            NavigationStack {
                DetailsView(seed: fixtureItem)
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
        case "home-cinemeta", "home-letterboxd", "catalog-error", "details-streams":
            await model.start()
            prepared = true
        default:
            prepared = true
        }

        // Let AsyncImage, navigation chrome, and detail resolution settle before capture.
        try? await Task.sleep(for: .milliseconds(state == "details-streams" ? 1_100 : 650))
        let runID = ProcessInfo.processInfo.environment["UI_SCREENSHOT_RUN_ID"] ?? "manual"
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
