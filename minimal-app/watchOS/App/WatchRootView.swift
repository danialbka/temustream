import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject private var model: WatchAppModel
    @State private var debugDemoPlayback: WatchPlaybackRequest?

    var body: some View {
        NavigationStack {
            List {
                quickActions
                recommendations
                continueWatching
                catalogs

                if let statusMessage = model.statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("TemuStremio")
            .refreshable { await model.loadHome() }
            .overlay {
                if model.isLoadingHome && model.catalogSections.isEmpty {
                    ProgressView("Loading")
                }
            }
        }
        .fullScreenCover(item: $debugDemoPlayback) { request in
            WatchPlaybackSessionView(request: request)
                .environmentObject(model)
        }
        .task {
            await model.start()
#if DEBUG
            if debugDemoPlayback == nil {
                debugDemoPlayback = model.debugDemoPlaybackRequest()
            }
#endif
        }
    }

    @ViewBuilder
    private var recommendations: some View {
        if !model.recommendations.isEmpty {
            Section("For You") {
                ForEach(model.recommendations.prefix(4)) { route in
                    NavigationLink {
                        WatchDetailsView(route: route)
                    } label: {
                        WatchMediaRow(item: route.item)
                    }
                    .task(id: route.id) {
                        await model.recordRecommendationImpression(for: route)
                    }
                }
            }
        }
    }

    private var quickActions: some View {
        Section {
            NavigationLink {
                WatchProfilesView()
            } label: {
                if let profile = model.activeViewingProfile {
                    HStack {
                        WatchProfileAvatar(profile: profile)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name)
                            Text("Switch profile")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Label("Profiles", systemImage: "person.2.fill")
                }
            }

            NavigationLink {
                WatchSearchView()
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }

            NavigationLink {
                WatchLibraryView()
            } label: {
                Label("My Library", systemImage: "bookmark.fill")
            }

            NavigationLink {
                WatchManualStreamView()
            } label: {
                Label("Open Stream URL", systemImage: "play.rectangle.fill")
            }

            NavigationLink {
                WatchSettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
    }

    @ViewBuilder
    private var continueWatching: some View {
        if !model.progress.isEmpty {
            Section("Continue Watching") {
                ForEach(model.progress.prefix(4)) { entry in
                    NavigationLink {
                        WatchStreamSelectionView(
                            route: entry.mediaRoute,
                            video: entry.video
                        )
                    } label: {
                        WatchProgressRow(entry: entry)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            Task { await model.removeProgress(entry) }
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var catalogs: some View {
        ForEach(model.catalogSections) { section in
            Section {
                ForEach(section.items.prefix(8)) { route in
                    NavigationLink {
                        WatchDetailsView(route: route)
                    } label: {
                        WatchMediaRow(item: route.item)
                    }
                }
                if section.items.count > 8 || section.supportsSkip {
                    NavigationLink {
                        WatchCatalogBrowseView(section: section)
                    } label: {
                        Label("Browse All", systemImage: "square.grid.2x2")
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title)
                    if let subtitle = section.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct WatchMediaRow: View {
    let item: MetaItem

    var body: some View {
        HStack(spacing: 9) {
            WatchArtwork(url: item.poster)
                .frame(width: 38, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                    .lineLimit(2)
                Text([item.type.capitalized, item.releaseInfo]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct WatchProgressRow: View {
    let entry: WatchProgressRecord

    var body: some View {
        HStack(spacing: 9) {
            WatchArtwork(url: entry.posterURL)
                .frame(width: 38, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.contentTitle)
                    .font(.headline)
                    .lineLimit(2)
                ProgressView(
                    value: entry.duration > 0 ? entry.position / entry.duration : 0
                )
                Text(WatchTimeFormatter.compact(entry.position) + " watched")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct WatchArtwork: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

enum WatchTimeFormatter {
    static func compact(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remaining = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%d:%02d", minutes, remaining)
    }
}
