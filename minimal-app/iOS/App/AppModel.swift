import AVFoundation
import Combine
import Foundation
#if canImport(KSPlayer)
@preconcurrency import KSPlayer
#endif

struct E2EResult: Sendable {
    let manifest: String
    let catalogCount: Int
    let letterboxdCatalogCount: Int
    let sourceSwitchAndPaging: Bool
    let globalSearch: Bool
    let detail: String
    let streamCount: Int
    let providerGrouping: Bool
    let ksDirectStartupMilliseconds: Double
    let ksHLSStartupMilliseconds: Double
    let ksContainerStartupMilliseconds: Double
    let ksTorrentStartupMilliseconds: Double
    let libraryRoundTrip: Bool
    let accountSync: Bool
    let sessionPersistenceRoundTrip: Bool
}

struct CatalogSource: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let manifestURL: URL
    let preferredCatalogID: String
}

struct StreamProviderGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let streams: [Stream]
}

struct SearchCatalogGroup: Identifiable, Equatable, Sendable {
    let id: String
    let providerName: String
    let catalogName: String
    let items: [MetaItem]
}

struct PlaybackPlan: Sendable {
    let primaryURL: URL
    let fallbackURL: URL?
    let requiresCompatibilityPlayback: Bool
    let detectedMIMEType: String?

    init(
        primaryURL: URL,
        fallbackURL: URL? = nil,
        requiresCompatibilityPlayback: Bool = false,
        detectedMIMEType: String? = nil
    ) {
        self.primaryURL = primaryURL
        self.fallbackURL = fallbackURL
        self.requiresCompatibilityPlayback = requiresCompatibilityPlayback
        self.detectedMIMEType = detectedMIMEType
    }
}

private enum StreamProviderLoadError: Error, Sendable {
    case timedOut
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var manifest: AddonManifest?
    @Published private(set) var catalog: [MetaItem] = []
    @Published private(set) var catalogSources: [CatalogSource]
    @Published private(set) var selectedCatalogSourceID: String
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var searchCatalogs: [SearchCatalogGroup] = []
    @Published private(set) var isSearching = false
    @Published private(set) var activeSearchQuery: String?
    @Published private(set) var library: [MetaItem] = []
    @Published private(set) var playbackProgress: [String: PlaybackProgress] = [:]
    @Published private(set) var installedAddons: [URL] = []
    @Published private(set) var accountEmail: String?
    @Published private(set) var accountSyncStatus = "Not signed in"
    @Published private(set) var streamingServerOnline = false
    @Published var streamingServerInput: String
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var e2eResult: E2EResult?
    @Published var e2eError: String?
    @Published var isRunningE2E = false

    private let primaryEndpoint: AddonEndpoint
    private let libraryStore: LibraryStore
    private let playbackProgressStore: PlaybackProgressStore
    private let accountClient: StremioAccountClient
    private let sessionStore = SessionStore()
    private var session: StremioSession?
    private var syncedAddonDescriptors: [SyncedAddon] = []
    private var addonManifestCache: [URL: AddonManifest] = [:]
    private var activeCatalogEndpoint: AddonEndpoint?
    private var activeCatalogDescriptor: AddonCatalog?
    private var catalogPaging = CatalogPageAccumulator()
    private var currentSearch: String?
    private var catalogLoadRevision = 0
    private var searchRevision = 0
    private var playbackProgressUpdateDates: [String: Date] = [:]
    private var started = false

    var selectedCatalogSource: CatalogSource? {
        catalogSources.first { $0.id == selectedCatalogSourceID }
    }

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let defaultManifest = "https://v3-cinemeta.strem.io/manifest.json"
        let input = environment["SKELETON_ADDON_URL"] ?? defaultManifest
        primaryEndpoint = (try? AddonEndpoint(manifestInput: input))
            ?? (try! AddonEndpoint(manifestInput: defaultManifest))
        let letterboxdInput = environment["SKELETON_LETTERBOXD_ADDON_URL"]
            ?? "https://api.stremboxd.com/manifest.json"
        let letterboxdEndpoint = (try? AddonEndpoint(manifestInput: letterboxdInput))
            ?? (try! AddonEndpoint(manifestInput: "https://api.stremboxd.com/manifest.json"))
        let configuredCatalogSources = [
            CatalogSource(
                id: "cinemeta",
                title: "Cinemeta",
                subtitle: "Popular movies",
                manifestURL: primaryEndpoint.manifestURL,
                preferredCatalogID: environment["SKELETON_CINEMETA_CATALOG_ID"] ?? "top"
            ),
            CatalogSource(
                id: "letterboxd",
                title: "Letterboxd Recommendations",
                subtitle: "Popular this week via Stremboxd",
                manifestURL: letterboxdEndpoint.manifestURL,
                preferredCatalogID: environment["SKELETON_LETTERBOXD_CATALOG_ID"]
                    ?? "letterboxd-popular"
            ),
        ]
        catalogSources = configuredCatalogSources
        let restoredSource = UserDefaults.standard.string(forKey: "selectedCatalogSource")
        selectedCatalogSourceID = restoredSource.flatMap { restored in
            configuredCatalogSources.contains { $0.id == restored } ? restored : nil
        } ?? "cinemeta"

        let apiURL = URL(string: environment["SKELETON_API_URL"] ?? "https://api.strem.io")!
        accountClient = try! StremioAccountClient(endpoint: apiURL)
        streamingServerInput = environment["SKELETON_STREAMING_SERVER_URL"]
            ?? UserDefaults.standard.string(forKey: "streamingServerURL")
            ?? "http://127.0.0.1:11470"

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        libraryStore = LibraryStore(fileURL: support.appendingPathComponent("library.json"))
        playbackProgressStore = PlaybackProgressStore(
            fileURL: support.appendingPathComponent("playback-progress.json")
        )
        session = SessionStore().load()
        accountEmail = session?.user.email
    }

    func start() async {
        guard !started else { return }
        started = true
        installedAddons = restoredAddonURLs()
        if !installedAddons.contains(primaryEndpoint.manifestURL) {
            installedAddons.insert(primaryEndpoint.manifestURL, at: 0)
        }

        do {
            library = try await libraryStore.items()
            do {
                for progress in try await playbackProgressStore.items() {
                    playbackProgress[progress.contentIdentifier] = progress
                    playbackProgressUpdateDates[progress.contentIdentifier] = progress.updatedAt
                }
            } catch {
                NSLog("PLAYBACK_PROGRESS load_failed=%@", error.localizedDescription)
            }
            if ProcessInfo.processInfo.environment["SKELETON_E2E"] == "1" {
                await runE2E()
            } else {
                try await loadHome()
                #if canImport(KSPlayer)
                if ProcessInfo.processInfo.environment[
                    "SKELETON_SINGLE_MOVIE_PLAYBACK_AUDIT"
                ] == "1" {
                    await runSingleMoviePlaybackAudit()
                    return
                }
                #endif
                await refreshStreamingServerStatus()
                if session != nil { try await syncAccount() }
                #if canImport(KSPlayer)
                if ProcessInfo.processInfo.environment["SKELETON_OBSESSION_STREAM_STRESS"] == "1" {
                    let stressEnvironment = ProcessInfo.processInfo.environment
                    await runObsessionStreamStressBenchmark(
                        requestedStreams: Int(stressEnvironment["SKELETON_OBSESSION_STREAM_COUNT"] ?? "") ?? 20,
                        startIndex: Int(stressEnvironment["SKELETON_OBSESSION_STREAM_START"] ?? "") ?? 0
                    )
                } else if ProcessInfo.processInfo.environment["SKELETON_REAL_PLAYER_STRESS"] == "1" {
                    await runRealPlayerStressBenchmark()
                }
                #endif
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectCatalogSource(_ source: CatalogSource) async throws {
        guard source.id != selectedCatalogSourceID else { return }
        selectedCatalogSourceID = source.id
        UserDefaults.standard.set(source.id, forKey: "selectedCatalogSource")
        try await loadHome()
    }

    func loadHome(search: String? = nil) async throws {
        catalogLoadRevision += 1
        let revision = catalogLoadRevision
        isLoading = true
        isLoadingNextPage = false
        errorMessage = nil
        currentSearch = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentSearch?.isEmpty == true { currentSearch = nil }
        defer {
            if revision == catalogLoadRevision { isLoading = false }
        }

        guard let source = selectedCatalogSource else {
            throw E2EFailure("No selected catalog source")
        }
        let endpoint = try AddonEndpoint(manifestURL: source.manifestURL)
        let client = AddonClient(endpoint: endpoint)
        let loadedManifest = try await client.manifest()
        addonManifestCache[source.manifestURL] = loadedManifest
        guard let descriptor = catalogDescriptor(
            in: loadedManifest,
            source: source,
            search: currentSearch
        ) else {
            guard revision == catalogLoadRevision else { return }
            manifest = loadedManifest
            catalog = []
            return
        }
        let items = try await client.catalog(
            type: descriptor.type,
            id: descriptor.id,
            search: currentSearch
        )
        guard revision == catalogLoadRevision, !Task.isCancelled else { return }

        catalogPaging.reset()
        catalogPaging.append(items, supportsSkip: descriptor.supportsSkip)
        activeCatalogEndpoint = endpoint
        activeCatalogDescriptor = descriptor
        manifest = loadedManifest
        catalog = catalogPaging.items
    }

    func searchAllCatalogs(_ input: String) async {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            clearSearch()
            return
        }

        searchRevision += 1
        let revision = searchRevision
        activeSearchQuery = query
        searchCatalogs = []
        isSearching = true
        errorMessage = nil

        var urls: [URL] = []
        var seenURLs = Set<URL>()
        for url in catalogSources.map(\.manifestURL) + installedAddons {
            if seenURLs.insert(url).inserted { urls.append(url) }
        }
        var knownManifests = addonManifestCache
        for descriptor in syncedAddonDescriptors {
            knownManifests[descriptor.transportUrl] = descriptor.manifest
        }

        let loaded = await withTaskGroup(of: (Int, [SearchCatalogGroup]).self) { group in
            for (providerIndex, url) in urls.enumerated() {
                let knownManifest = knownManifests[url]
                group.addTask {
                    guard let endpoint = try? AddonEndpoint(manifestURL: url) else {
                        return (providerIndex, [])
                    }
                    let client = AddonClient(endpoint: endpoint)
                    let manifest: AddonManifest
                    if let knownManifest {
                        manifest = knownManifest
                    } else {
                        guard let loadedManifest = try? await Self.withAddonTimeout({
                            try await client.manifest()
                        }) else { return (providerIndex, []) }
                        manifest = loadedManifest
                    }

                    let searchable = manifest.catalogs.filter { descriptor in
                        descriptor.supportsExtra("search")
                            && (descriptor.type == "movie" || descriptor.type == "series")
                    }
                    let results = await withTaskGroup(
                        of: (Int, SearchCatalogGroup?).self
                    ) { catalogGroup in
                        for (catalogIndex, descriptor) in searchable.enumerated() {
                            catalogGroup.addTask {
                                guard let items = try? await Self.withAddonTimeout({
                                    try await client.catalog(
                                        type: descriptor.type,
                                        id: descriptor.id,
                                        search: query
                                    )
                                }), !items.isEmpty else { return (catalogIndex, nil) }

                                var seenItems = Set<String>()
                                let uniqueItems = items.filter {
                                    seenItems.insert("\($0.type)|\($0.id)").inserted
                                }
                                return (
                                    catalogIndex,
                                    SearchCatalogGroup(
                                        id: "\(url.absoluteString)#\(descriptor.type)#\(descriptor.id)",
                                        providerName: manifest.name,
                                        catalogName: descriptor.name ?? descriptor.id,
                                        items: uniqueItems
                                    )
                                )
                            }
                        }
                        var catalogs: [(Int, SearchCatalogGroup)] = []
                        for await (catalogIndex, result) in catalogGroup {
                            if let result { catalogs.append((catalogIndex, result)) }
                        }
                        return catalogs.sorted { $0.0 < $1.0 }.map(\.1)
                    }
                    return (providerIndex, results)
                }
            }

            var providers: [(Int, [SearchCatalogGroup])] = []
            for await result in group { providers.append(result) }
            return providers.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }

        guard revision == searchRevision, activeSearchQuery == query, !Task.isCancelled else {
            return
        }
        searchCatalogs = loaded
        isSearching = false
    }

    func clearSearch() {
        guard activeSearchQuery != nil || isSearching || !searchCatalogs.isEmpty else { return }
        searchRevision += 1
        activeSearchQuery = nil
        searchCatalogs = []
        isSearching = false
    }

    func loadNextPageIfNeeded(currentItem: MetaItem) async {
        guard let index = catalog.firstIndex(where: {
            $0.id == currentItem.id && $0.type == currentItem.type
        }), index >= max(0, catalog.count - 8) else { return }

        do {
            try await loadNextPage()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadNextPage() async throws {
        guard !isLoading, !isLoadingNextPage, catalogPaging.canLoadMore,
              let endpoint = activeCatalogEndpoint,
              let descriptor = activeCatalogDescriptor
        else { return }

        let revision = catalogLoadRevision
        let skip = catalogPaging.nextSkip
        isLoadingNextPage = true
        defer {
            if revision == catalogLoadRevision { isLoadingNextPage = false }
        }

        let page = try await AddonClient(endpoint: endpoint).catalog(
            type: descriptor.type,
            id: descriptor.id,
            search: currentSearch,
            skip: skip
        )
        guard revision == catalogLoadRevision, !Task.isCancelled else { return }
        catalogPaging.append(page, supportsSkip: descriptor.supportsSkip)
        catalog = catalogPaging.items
    }

    func details(for item: MetaItem) async -> MetaItem {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var endpoints = [activeCatalogEndpoint, primaryEndpoint].compactMap { $0 }
        var seen = Set<URL>()
        endpoints = endpoints.filter { seen.insert($0.manifestURL).inserted }
        var resolvedDetail: MetaItem?
        for endpoint in endpoints {
            if let detail = try? await AddonClient(endpoint: endpoint)
                .meta(type: item.type, id: item.id) {
                resolvedDetail = resolvedDetail?.fillingTrailerMetadata(from: detail)
                    ?? detail
                if item.type != "movie" || resolvedDetail?.preferredTrailerURL != nil {
                    break
                }
            }
        }
        if let resolvedDetail {
            NSLog(
                "DETAIL_BENCHMARK elapsed_ms=%.1f endpoints=%ld result=remote",
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                endpoints.count
            )
            return resolvedDetail
        }
        NSLog(
            "DETAIL_BENCHMARK elapsed_ms=%.1f endpoints=%ld result=seed",
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
            endpoints.count
        )
        return item
    }

    func streamProviders(for item: MetaItem, videoID: String? = nil) async -> [StreamProviderGroup] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let requestID = videoID ?? item.id
        let configuredStreamingServer = try? StreamingServerEndpoint(streamingServerInput).baseURL
        let isE2E = ProcessInfo.processInfo.environment["SKELETON_E2E"] == "1"
        let addonURLs = installedAddons.filter { addonURL in
            // The E2E fixture intentionally serves its add-on and streaming
            // endpoints from one origin. Keep that add-on in the matrix while
            // still avoiding the dead local streaming-server probe in normal
            // launches.
            guard !isE2E, !streamingServerOnline, let configuredStreamingServer else {
                return true
            }
            return addonURL.host?.lowercased() != configuredStreamingServer.host?.lowercased()
                || addonURL.port != configuredStreamingServer.port
        }
        let knownManifests = syncedAddonDescriptors.reduce(into: addonManifestCache) {
            $0[$1.transportUrl] = $1.manifest
        }

        let loadedProviders = await withTaskGroup(of: (Int, StreamProviderGroup?).self) { group in
            for (index, url) in addonURLs.enumerated() {
                let knownManifest = knownManifests[url]
                group.addTask {
                    let providerStartedAt = ProcessInfo.processInfo.systemUptime
                    defer {
                        NSLog(
                            "STREAM_PROVIDER_BENCHMARK index=%ld elapsed_ms=%.1f",
                            index,
                            (ProcessInfo.processInfo.systemUptime - providerStartedAt) * 1_000
                        )
                    }
                    guard let endpoint = try? AddonEndpoint(manifestURL: url) else {
                        return (index, nil)
                    }
                    let client = AddonClient(endpoint: endpoint)
                    let manifest: AddonManifest
                    if let knownManifest {
                        manifest = knownManifest
                    } else {
                        guard let loaded = try? await client.manifest() else {
                            return (index, nil)
                        }
                        manifest = loaded
                    }
                    guard manifest.supports(resource: "stream", type: item.type) else {
                        return (index, nil)
                    }
                    guard let loadedStreams = try? await client.streams(
                        type: item.type,
                        id: requestID
                    ) else { return (index, nil) }

                    var seen = Set<String>()
                    let streams = loadedStreams.filter { seen.insert($0.id).inserted }
                    return (
                        index,
                        StreamProviderGroup(
                            id: url.absoluteString,
                            name: manifest.name,
                            streams: streams
                        )
                    )
                }
            }

            var results: [(Int, StreamProviderGroup)] = []
            for await (index, provider) in group {
                if let provider { results.append((index, provider)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        NSLog(
            "STREAM_PROVIDERS_BENCHMARK elapsed_ms=%.1f requested=%ld loaded=%ld streams=%ld",
            (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
            addonURLs.count,
            loadedProviders.count,
            loadedProviders.reduce(0) { $0 + $1.streams.count }
        )
        return loadedProviders
    }

    func streams(for item: MetaItem, videoID: String? = nil) async -> [Stream] {
        await streamProviders(for: item, videoID: videoID).flatMap(\.streams)
    }

    private nonisolated static func withAddonTimeout<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .seconds(8))
                throw StreamProviderLoadError.timedOut
            }
            guard let first = try await group.next() else {
                throw StreamProviderLoadError.timedOut
            }
            group.cancelAll()
            return first
        }
    }

    func toggleLibrary(_ item: MetaItem) async {
        do {
            let removing = isInLibrary(item)
            library = try await libraryStore.toggle(item)
            if let session {
                try await accountClient.pushLibrary(
                    authKey: session.authKey,
                    changes: [RemoteLibraryItem(item: item, removed: removing)]
                )
                accountSyncStatus = "Library synced"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isInLibrary(_ item: MetaItem) -> Bool {
        library.contains { $0.id == item.id && $0.type == item.type }
    }

    func resumeProgress(for item: MetaItem) -> PlaybackProgress? {
        playbackProgress["\(item.type):\(item.id)"]
    }

    func recordPlaybackProgress(
        contentIdentifier: String?,
        contentTitle: String?,
        stream: Stream,
        providerName: String?,
        position: TimeInterval,
        duration: TimeInterval
    ) {
        guard let contentIdentifier, !contentIdentifier.isEmpty,
              let contentTitle, !contentTitle.isEmpty,
              position.isFinite, duration.isFinite,
              position >= PlaybackProgress.minimumResumePosition
        else { return }

        let progress = PlaybackProgress(
            contentIdentifier: contentIdentifier,
            contentTitle: contentTitle,
            stream: stream,
            providerName: providerName,
            position: position,
            duration: duration
        )
        playbackProgressUpdateDates[contentIdentifier] = progress.updatedAt
        if PlaybackProgress.shouldSave(position: position, duration: duration) {
            playbackProgress[contentIdentifier] = progress
        } else if PlaybackProgress.isCompleted(position: position, duration: duration) {
            playbackProgress.removeValue(forKey: contentIdentifier)
        } else {
            return
        }

        Task {
            do {
                let persisted = try await playbackProgressStore.record(progress)
                guard playbackProgressUpdateDates[contentIdentifier] == progress.updatedAt else {
                    return
                }
                if let saved = persisted.first(where: {
                    $0.contentIdentifier == contentIdentifier
                }) {
                    playbackProgress[contentIdentifier] = saved
                } else {
                    playbackProgress.removeValue(forKey: contentIdentifier)
                }
            } catch {
                NSLog("PLAYBACK_PROGRESS save_failed=%@", error.localizedDescription)
            }
        }
    }

    func installAddon(_ input: String) async throws {
        let endpoint = try AddonEndpoint(manifestInput: input)
        let manifest = try await AddonClient(endpoint: endpoint).manifest()
        addonManifestCache[endpoint.manifestURL] = manifest
        if !installedAddons.contains(endpoint.manifestURL) {
            installedAddons.append(endpoint.manifestURL)
            persistAddonURLs()
            if let session {
                syncedAddonDescriptors.removeAll { $0.transportUrl == endpoint.manifestURL }
                syncedAddonDescriptors.append(
                    SyncedAddon(manifest: manifest, transportUrl: endpoint.manifestURL)
                )
                try await accountClient.pushAddons(
                    authKey: session.authKey,
                    addons: syncedAddonDescriptors
                )
                accountSyncStatus = "Add-ons synced"
            }
        }
    }

    func removeAddon(_ url: URL) {
        guard url != primaryEndpoint.manifestURL else { return }
        installedAddons.removeAll { $0 == url }
        persistAddonURLs()
        syncedAddonDescriptors.removeAll { $0.transportUrl == url }
        if let session {
            Task {
                do {
                    try await accountClient.pushAddons(
                        authKey: session.authKey,
                        addons: syncedAddonDescriptors
                    )
                    accountSyncStatus = "Add-ons synced"
                } catch {
                    accountSyncStatus = error.localizedDescription
                }
            }
        }
    }

    func signIn(email: String, password: String) async throws {
        let signedIn = try await accountClient.login(email: email, password: password)
        try sessionStore.save(signedIn)
        session = signedIn
        accountEmail = signedIn.user.email ?? email
        try await syncAccount()
    }

    func signOut() {
        sessionStore.clear()
        session = nil
        accountEmail = nil
        syncedAddonDescriptors = []
        accountSyncStatus = "Not signed in"
    }

    func syncAccount() async throws {
        guard let session else { return }
        accountSyncStatus = "Syncing…"
        do {
            async let remoteLibrary = accountClient.pullLibrary(authKey: session.authKey)
            async let remoteAddons = accountClient.pullAddons(authKey: session.authKey)
            let (libraryItems, addonDescriptors) = try await (remoteLibrary, remoteAddons)

            library = try await libraryStore.applyRemote(libraryItems)
            syncedAddonDescriptors = addonDescriptors
            for descriptor in addonDescriptors {
                addonManifestCache[descriptor.transportUrl] = descriptor.manifest
            }
            installedAddons = addonDescriptors.compactMap { descriptor in
                (try? AddonEndpoint(manifestURL: descriptor.transportUrl)) == nil
                    ? nil
                    : descriptor.transportUrl
            }
            if !installedAddons.contains(primaryEndpoint.manifestURL) {
                installedAddons.insert(primaryEndpoint.manifestURL, at: 0)
            }
            persistAddonURLs()
            accountSyncStatus = "Synced now"
        } catch {
            accountSyncStatus = "Sync failed"
            NSLog("[AccountSync] %@", error.localizedDescription)
            throw error
        }
    }

    func saveStreamingServer() async throws {
        _ = try StreamingServerEndpoint(streamingServerInput)
        UserDefaults.standard.set(streamingServerInput, forKey: "streamingServerURL")
        await refreshStreamingServerStatus()
    }

    func refreshStreamingServerStatus() async {
        guard let endpoint = try? StreamingServerEndpoint(streamingServerInput) else {
            streamingServerOnline = false
            return
        }
        streamingServerOnline = await TorrentStreamingClient(endpoint: endpoint).isOnline()
    }

    func playbackPlan(for stream: Stream, providerName: String? = nil) async throws -> PlaybackPlan {
        let endpoint = try? StreamingServerEndpoint(streamingServerInput)
        let client = endpoint.map { TorrentStreamingClient(endpoint: $0) }
        var sourceURL: URL
        var compatibilitySourceURL: URL
        let detectedMIMEType: String?
        if let url = stream.url {
            if TorBoxPlaybackResolver.shouldResolve(
                stream: stream,
                url: url,
                providerName: providerName
            ) {
                let startedAt = ProcessInfo.processInfo.systemUptime
                let resolved = try await TorBoxPlaybackResolver.resolve(url, stream: stream)
                sourceURL = resolved.url
                compatibilitySourceURL = resolved.url
                detectedMIMEType = resolved.detectedMIMEType
                NSLog(
                    "TORBOX_STREAM_BENCHMARK resolve_ms=%.1f host=%@",
                    (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                    sourceURL.host ?? "unknown"
                )
                if detectedMIMEType == "video/mp2t",
                   resolved.supportsByteRanges,
                   let contentLength = resolved.contentLength {
                    sourceURL = try await StreamTransportBridge.shared.localURL(
                        upstream: resolved.url,
                        contentLength: contentLength,
                        mimeType: "video/mp2t"
                    )
                }
            } else {
                sourceURL = url
                compatibilitySourceURL = url
                detectedMIMEType = nil
            }
        } else {
            guard let client else { throw StreamingServerError.invalidServerURL }
            sourceURL = try await client.playbackURL(for: stream)
            compatibilitySourceURL = sourceURL
            detectedMIMEType = nil
        }

        let nativeExtensions = ["m3u8", "mp4", "m4v", "mov", "mp3", "m4a", "aac", "ts"]
        let sourceExtension = sourceURL.pathExtension.lowercased()
        let hasAmbiguousContainer = sourceExtension.isEmpty
            || !nativeExtensions.contains(sourceExtension)
        let requiresCompatibilityPlayback = stream.prefersCompatibilityPlayback
            || (StremioInternalPlayer.selected == .avPlayer
                && (hasAmbiguousContainer || detectedMIMEType == "video/mp2t"))
        var compatibilityURL: URL?
        if requiresCompatibilityPlayback, let client {
            // Torrent resolution already proves that the configured server is
            // reachable. Direct files get one short heartbeat in case playback
            // was opened before the background status refresh completed.
            let serverIsAvailable: Bool
            if stream.isTorrent || streamingServerOnline {
                serverIsAvailable = true
            } else {
                serverIsAvailable = await client.isOnline()
                streamingServerOnline = serverIsAvailable
            }

            if serverIsAvailable {
                compatibilityURL = try? await client.compatibilityPlaybackURL(
                    for: compatibilitySourceURL,
                    sessionID: UUID().uuidString
                )
                if compatibilityURL != nil {
                    NSLog("PLAYER_STREAM_BRIDGE prepared=server-hls")
                }
            }
        }

        return PlaybackPlan(
            primaryURL: sourceURL,
            fallbackURL: compatibilityURL,
            requiresCompatibilityPlayback: requiresCompatibilityPlayback,
            detectedMIMEType: detectedMIMEType
        )
    }

    func playbackURL(for stream: Stream) async throws -> URL {
        try await playbackPlan(for: stream).primaryURL
    }

    private func runE2E() async {
        let runID = ProcessInfo.processInfo.environment["SKELETON_E2E_RUN_ID"] ?? "manual"
        isRunningE2E = true
        defer { isRunningE2E = false }
        do {
            selectedCatalogSourceID = "cinemeta"
            try await loadHome()
            let initialCatalogCount = catalog.count
            guard let letterboxd = catalogSources.first(where: { $0.id == "letterboxd" }) else {
                throw E2EFailure("Missing Letterboxd source")
            }
            try await selectCatalogSource(letterboxd)
            let letterboxdFirstPageCount = catalog.count
            try await loadNextPage()
            let letterboxdPagedCount = catalog.count
            let sourceSwitchAndPaging = selectedCatalogSourceID == "letterboxd"
                && letterboxdFirstPageCount > 0
                && letterboxdPagedCount > letterboxdFirstPageCount
            guard sourceSwitchAndPaging else {
                throw E2EFailure("Catalog source switch or pagination failed")
            }

            await searchAllCatalogs("Big Buck Bunny")
            let globalSearch = searchCatalogs
                .flatMap(\.items)
                .contains { $0.id == "tt1254207" && $0.name == "Big Buck Bunny" }
            guard globalSearch else { throw E2EFailure("Global add-on search failed") }

            let client = AddonClient(endpoint: primaryEndpoint)
            let loadedManifest = try await client.manifest()
            guard let descriptor = loadedManifest.catalogs.first else {
                throw E2EFailure("No catalog")
            }
            let items = try await client.catalog(type: descriptor.type, id: descriptor.id)
            guard let first = items.first else { throw E2EFailure("Empty catalog") }
            let detail = try await client.meta(type: first.type, id: first.id)
            let loadedStreams = try await client.streams(type: detail.type, id: detail.id)
            let groupedStreams = await streamProviders(for: detail)
            let providerGrouping = groupedStreams.contains {
                $0.name == loadedManifest.name && !$0.streams.isEmpty
            }
            guard providerGrouping else { throw E2EFailure("Stream provider grouping failed") }
            guard let playable = loadedStreams.first(where: { $0.url != nil }),
                  let url = playable.url else {
                throw E2EFailure("No direct stream")
            }

            let e2eLibraryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("skeleton-e2e-library.json")
            try? FileManager.default.removeItem(at: e2eLibraryURL)
            let e2eLibrary = LibraryStore(fileURL: e2eLibraryURL)
            _ = try await e2eLibrary.toggle(detail)
            let added = try await e2eLibrary.contains(detail)
            _ = try await e2eLibrary.toggle(detail)
            let removed = !(try await e2eLibrary.contains(detail))
            let directStartup = try await StremioPlayerStartupBenchmark.measure(url: url)
            let hlsURL = url.deletingLastPathComponent().appendingPathComponent("sample.m3u8")
            let hlsStartup = try await StremioPlayerStartupBenchmark.measure(url: hlsURL)
            guard let compatibilityStream = loadedStreams.first(where: {
                $0.url != nil && $0.prefersCompatibilityPlayback
            }), let compatibilitySourceURL = compatibilityStream.url else {
                throw E2EFailure("No incompatible direct stream")
            }
            let containerStartup = try await StremioPlayerStartupBenchmark.measure(
                url: compatibilitySourceURL,
                timeoutSeconds: 20
            )
            guard let torrent = loadedStreams.first(where: \.isTorrent) else {
                throw E2EFailure("No torrent stream")
            }
            let torrentPlan = try await playbackPlan(for: torrent)
            let torrentStartup = try await StremioPlayerStartupBenchmark.measure(
                url: torrentPlan.primaryURL
            )

            guard let e2eEmail = ProcessInfo.processInfo.environment["SKELETON_E2E_EMAIL"],
                  let e2ePassword = ProcessInfo.processInfo.environment["SKELETON_E2E_PASSWORD"]
            else { throw E2EFailure("Missing E2E account credentials") }
            let e2eSession = try await accountClient.login(email: e2eEmail, password: e2ePassword)
            try sessionStore.save(e2eSession)
            let sessionPersistenceRoundTrip = sessionStore.load() == e2eSession
            sessionStore.clear()
            guard sessionPersistenceRoundTrip else {
                throw E2EFailure("Session persistence round trip failed")
            }
            let remoteLibrary = try await accountClient.pullLibrary(authKey: e2eSession.authKey)
            let remoteAddons = try await accountClient.pullAddons(authKey: e2eSession.authKey)
            try await accountClient.pushLibrary(
                authKey: e2eSession.authKey,
                changes: [RemoteLibraryItem(item: detail, removed: false)]
            )
            try await accountClient.pushAddons(authKey: e2eSession.authKey, addons: remoteAddons)
            let accountSynced = !remoteLibrary.isEmpty && !remoteAddons.isEmpty

            e2eResult = E2EResult(
                manifest: loadedManifest.name,
                catalogCount: initialCatalogCount,
                letterboxdCatalogCount: letterboxdPagedCount,
                sourceSwitchAndPaging: sourceSwitchAndPaging,
                globalSearch: globalSearch,
                detail: detail.name,
                streamCount: loadedStreams.count,
                providerGrouping: providerGrouping,
                ksDirectStartupMilliseconds: directStartup,
                ksHLSStartupMilliseconds: hlsStartup,
                ksContainerStartupMilliseconds: containerStartup,
                ksTorrentStartupMilliseconds: torrentStartup,
                libraryRoundTrip: added && removed,
                accountSync: accountSynced,
                sessionPersistenceRoundTrip: sessionPersistenceRoundTrip
            )
            NSLog(
                "[SkeletonE2E:%@] PASS manifest=%@ catalog=%ld letterboxd=%ld paging=%d search=%d streams=%ld providers=%d ks_direct_ms=%.1f ks_hls_ms=%.1f ks_mkv_av1_ms=%.1f ks_torrent_ms=%.1f library=%d account=%d session=%d",
                runID,
                loadedManifest.name,
                initialCatalogCount,
                letterboxdPagedCount,
                sourceSwitchAndPaging,
                globalSearch,
                loadedStreams.count,
                providerGrouping,
                directStartup,
                hlsStartup,
                containerStartup,
                torrentStartup,
                added && removed,
                accountSynced,
                sessionPersistenceRoundTrip
            )
        } catch {
            e2eError = error.localizedDescription
            NSLog("[SkeletonE2E:%@] FAIL %@", runID, error.localizedDescription)
        }
    }

    private func catalogDescriptor(
        in manifest: AddonManifest,
        source: CatalogSource,
        search: String?
    ) -> AddonCatalog? {
        let movieCatalogs = manifest.catalogs.filter { $0.type == "movie" }
        if search != nil,
           let searchable = movieCatalogs.first(where: { $0.supportsExtra("search") }) {
            return searchable
        }
        return movieCatalogs.first(where: { $0.id == source.preferredCatalogID })
            ?? movieCatalogs.first
            ?? manifest.catalogs.first
    }

    private func restoredAddonURLs() -> [URL] {
        UserDefaults.standard.stringArray(forKey: "installedAddonURLs")?
            .compactMap(URL.init(string:)) ?? []
    }

    private func persistAddonURLs() {
        UserDefaults.standard.set(
            installedAddons.map(\.absoluteString),
            forKey: "installedAddonURLs"
        )
    }
}

private extension AddonCatalog {
    func supportsExtra(_ name: String) -> Bool {
        extra?.contains { $0.name == name } == true
    }

    var supportsSkip: Bool { supportsExtra("skip") }
}

private struct E2EFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
enum PlayerStartupBenchmark {
    static func measure(url: URL, timeoutSeconds: Double = 10) async throws -> Double {
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        let started = CFAbsoluteTimeGetCurrent()
        player.play()

        let attempts = Int(timeoutSeconds / 0.05)
        for _ in 0..<attempts {
            if item.status == .failed {
                throw item.error ?? E2EFailure("Player failed")
            }
            if item.status == .readyToPlay &&
                (player.timeControlStatus == .playing || player.rate > 0) {
                player.pause()
                return (CFAbsoluteTimeGetCurrent() - started) * 1_000
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        player.pause()
        throw E2EFailure("Player startup timed out")
    }
}

@MainActor
enum StremioPlayerStartupBenchmark {
    static func measure(url: URL, timeoutSeconds: Double = 10) async throws -> Double {
        #if canImport(KSPlayer)
        let options = KSOptions()
        options.preferredForwardBufferDuration = 0.5
        let player = KSMEPlayer(url: url, options: options)
        let started = CFAbsoluteTimeGetCurrent()
        player.prepareToPlay()
        player.play()

        let attempts = Int(timeoutSeconds / 0.05)
        for _ in 0..<attempts {
            if player.isReadyToPlay && player.loadState == .playable {
                player.pause()
                player.shutdown()
                return (CFAbsoluteTimeGetCurrent() - started) * 1_000
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        player.pause()
        player.shutdown()
        throw E2EFailure("Stremio KSPlayer startup timed out")
        #else
        return try await PlayerStartupBenchmark.measure(
            url: url,
            timeoutSeconds: timeoutSeconds
        )
        #endif
    }
}
