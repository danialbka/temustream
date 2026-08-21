import SwiftUI

private let grid = [GridItem(.adaptive(minimum: 132), spacing: 16)]

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if ProcessInfo.processInfo.environment["SKELETON_E2E"] == "1" {
            E2EStatusView()
        } else {
            TabView {
                NavigationStack { HomeView() }
                    .tabItem { Label("Home", systemImage: "rectangle.grid.2x2") }
                NavigationStack { LibraryView() }
                    .tabItem { Label("Library", systemImage: "bookmark") }
                NavigationStack { AddonsView() }
                    .tabItem { Label("Add-ons", systemImage: "shippingbox") }
                NavigationStack { AccountView() }
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
            }
            .tint(.orange)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .background(Color.white.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
            .padding(.horizontal, 16)
            .accessibilityIdentifier("catalog-search-field")

                Group {
                    if !trimmedSearch.isEmpty {
                        searchContent
                    } else if model.isLoading && model.catalog.isEmpty {
                        ProgressView("Loading catalog…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = model.errorMessage, model.catalog.isEmpty {
                        EmptyStateView(
                            title: "Catalog unavailable",
                            systemImage: "wifi.exclamationmark",
                            message: error
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
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
                            .padding(.top, 2)
                            .padding(.bottom, 96)
                        }
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
            .foregroundStyle(.orange)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("catalog-source-menu")
        .accessibilityLabel("Catalog source")
    }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        NavigationLink(value: item) {
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
                Color.white.opacity(0.06)
                Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 198)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct DetailsView: View {
    private static let allProvidersID = "all-providers"
    private static let streamBatchSize = 60

    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    let seed: MetaItem
    @State private var item: MetaItem
    @State private var streamProviders: [StreamProviderGroup] = []
    @State private var selectedProviderID = Self.allProvidersID
    @State private var visibleStreamLimit = Self.streamBatchSize
    @State private var isLoading = true
    @State private var isUpdatingLibrary = false

    init(seed: MetaItem) {
        self.seed = seed
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
                                        .tint(model.isInLibrary(item) ? .orange : .black)
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
                            .foregroundStyle(model.isInLibrary(item) ? Color.orange : Color.black)
                            .background(
                                model.isInLibrary(item)
                                    ? Color.orange.opacity(0.14)
                                    : Color.orange
                            )
                            .overlay {
                                if model.isInLibrary(item) {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.orange.opacity(0.55), lineWidth: 1)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isUpdatingLibrary)
                        .accessibilityIdentifier("library-toggle")
                    }
                }
                if let description = item.description { Text(description) }
            }

            Section("Streams") {
                if isLoading {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                            .tint(.orange)
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
                                        candidate: StreamPlaybackCandidate(
                                            stream: stream,
                                            providerName: presented.providerName
                                        ),
                                        minimumVideoDuration: item.type == "movie"
                                            ? 20 * 60
                                            : 5 * 60
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
                            .tint(.orange)
                            .accessibilityIdentifier("show-more-streams")
                        }
                    }
                }
            }
            .id("streams-section")
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(false)
            .task {
                item = await model.details(for: seed)
                streamProviders = await model.streamProviders(for: item)
                if !streamProviders.contains(where: { $0.id == selectedProviderID }) {
                    selectedProviderID = Self.allProvidersID
                }
                isLoading = false
                #if SKELETON_SCREENSHOT_HARNESS
                if ProcessInfo.processInfo.environment["UI_SCREENSHOT_STATE"] == "details-streams" {
                    try? await Task.sleep(for: .milliseconds(100))
                    proxy.scrollTo("streams-section", anchor: .top)
                }
                #endif
            }
        }
    }

    private var visibleStreams: [PresentedStream] {
        let providers = selectedProviderID == Self.allProvidersID
            ? streamProviders
            : streamProviders.filter { $0.id == selectedProviderID }
        return providers.flatMap { provider in
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
                    .background(isSelected ? Color.black.opacity(0.18) : Color.orange.opacity(0.12))
                    .clipShape(Capsule())
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isSelected ? Color.black : Color.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.orange : Color.orange.opacity(0.10))
            .overlay {
                Capsule().stroke(Color.orange.opacity(isSelected ? 0 : 0.45), lineWidth: 1)
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
                .foregroundStyle(.orange)
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
                    .foregroundStyle(.orange)
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

private struct PresentedStream: Identifiable {
    let id: String
    let providerName: String
    let stream: Stream

    /// Put cached, phone-decodable releases ahead of extreme AI upscales and
    /// huge remuxes. Every provider result remains available; this only keeps
    /// an unsafe 8K entry from looking like the default choice on an iPhone.
    var playbackPriority: Int {
        let uppercased = metadataText.uppercased()
        var score = metadataText.contains("⚡") ? -1_000 : 0
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
        return score
    }

    var fileSizeBadge: String? {
        metadataMatch(#"(?i)(?<![A-Z0-9])\d+(?:\.\d+)?\s*(?:TB|GB|MB)(?![A-Z0-9])"#)?
            .uppercased()
            .replacingOccurrences(of: " ", with: " ")
    }

    var qualityBadge: String? {
        guard let match = metadataMatch(#"(?i)(?:4320P|8K|2160P|4K|1080P|720P|480P)"#) else {
            return nil
        }
        switch match.uppercased() {
        case "4320P", "8K": return "8K"
        case "2160P", "4K": return "4K"
        default: return match.uppercased()
        }
    }

    private var metadataText: String {
        [stream.title, stream.name, stream.description]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private var sizeInGB: Double? {
        guard let range = metadataText.range(
            of: #"(?i)(?<![A-Z0-9])(\d+(?:\.\d+)?)\s*(TB|GB|MB)(?![A-Z0-9])"#,
            options: .regularExpression
        ) else { return nil }
        let value = String(metadataText[range])
        let scanner = Scanner(string: value)
        guard let amount = scanner.scanDouble() else { return nil }
        let unit = value.uppercased()
        if unit.contains("TB") { return amount * 1_024 }
        if unit.contains("MB") { return amount / 1_024 }
        return amount
    }

    private func metadataMatch(_ pattern: String) -> String? {
        guard let range = metadataText.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(metadataText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct StreamMetadataBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .overlay { Capsule().stroke(Color.orange.opacity(0.35), lineWidth: 1) }
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
                        ForEach(model.library) { PosterCard(item: $0) }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Library")
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

            Section("Stremio player") {
                LabeledContent("Engine", value: "KSPlayer + FFmpeg")
                LabeledContent("Decoder", value: "Hardware accelerated")
                LabeledContent("Playback", value: "MP4 / MKV / HLS / torrent")
                LabeledContent("Controls", value: "PiP / audio / subtitles")
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
                    Button("Sign out", role: .destructive) { model.signOut() }
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
                .foregroundStyle(model.e2eResult == nil ? .orange : .green)
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
