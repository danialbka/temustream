import Combine
import Foundation

struct WatchAddon: Identifiable, Sendable {
    let manifestURL: URL
    let manifest: AddonManifest

    var id: URL { manifestURL }
}

struct WatchMediaRoute: Identifiable, Hashable, Sendable {
    let item: MetaItem
    let manifestURL: URL

    var id: String {
        "\(manifestURL.absoluteString)|\(item.type)|\(item.id)"
    }
}

struct WatchCatalogSection: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let items: [WatchMediaRoute]
    let manifestURL: URL
    let mediaType: String
    let catalogID: String
    let supportsSkip: Bool
}

struct WatchStreamGroup: Identifiable, Sendable {
    let id: String
    let providerName: String
    let streams: [Stream]
}

struct WatchPlaybackRequest: Identifiable, Sendable {
    let id: String
    let stream: Stream
    let playbackURL: URL
    let kind: WatchStreamKind
    let title: String
    let subtitle: String?
    let providerName: String?
    let contentIdentifier: String?
    let mediaMetadata: PlaybackMediaMetadata?
    let manifestURL: URL?
    let initialPosition: TimeInterval
    let fallbackSources: [WatchPlaybackSource]
    let fallbackIndex: Int
    let route: WatchMediaRoute?
    let video: Video?
    let episodes: [Video]
}

struct WatchProgressRecord: Codable, Equatable, Identifiable, Sendable {
    let contentIdentifier: String
    let contentTitle: String
    let mediaID: String
    let mediaType: String
    let mediaTitle: String
    let posterURL: URL?
    let episodeID: String?
    let episodeTitle: String?
    let season: Int?
    let episode: Int?
    let manifestURL: URL
    let providerName: String?
    let position: TimeInterval
    let duration: TimeInterval
    let updatedAt: Date

    var id: String { contentIdentifier }

    var mediaRoute: WatchMediaRoute {
        WatchMediaRoute(
            item: MetaItem(
                id: mediaID,
                type: mediaType,
                name: mediaTitle,
                poster: posterURL
            ),
            manifestURL: manifestURL
        )
    }

    var video: Video? {
        episodeID.map {
            Video(
                id: $0,
                title: episodeTitle,
                season: season,
                episode: episode
            )
        }
    }
}

private actor WatchProgressStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func items() throws -> [WatchProgressRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoded = try decoder.decode(
            [WatchProgressRecord].self,
            from: Data(contentsOf: fileURL)
        )
        let sanitized = decoded.compactMap(Self.persistenceSafe)
        if sanitized != decoded {
            try persist(sanitized)
        }
        return sanitized.sorted { $0.updatedAt > $1.updatedAt }
    }

    func record(_ entry: WatchProgressRecord) throws -> [WatchProgressRecord] {
        var current = try items()
        current.removeAll { $0.contentIdentifier == entry.contentIdentifier }
        if PlaybackProgress.shouldSave(position: entry.position, duration: entry.duration),
           let safeEntry = Self.persistenceSafe(entry) {
            current.append(safeEntry)
        }
        current.sort { $0.updatedAt > $1.updatedAt }
        try persist(current)
        return current
    }

    func remove(contentIdentifier: String) throws -> [WatchProgressRecord] {
        var current = try items()
        current.removeAll { $0.contentIdentifier == contentIdentifier }
        try persist(current)
        return current
    }

    private func persist(_ entries: [WatchProgressRecord]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(entries).write(to: fileURL, options: .atomic)
    }

    private static func persistenceSafe(
        _ entry: WatchProgressRecord
    ) -> WatchProgressRecord? {
        guard let manifestURL = WatchPlaybackPersistencePolicy
            .sanitizedReferenceURL(entry.manifestURL)
        else { return nil }
        return WatchProgressRecord(
            contentIdentifier: entry.contentIdentifier,
            contentTitle: entry.contentTitle,
            mediaID: entry.mediaID,
            mediaType: entry.mediaType,
            mediaTitle: entry.mediaTitle,
            posterURL: WatchPlaybackPersistencePolicy
                .sanitizedReferenceURL(entry.posterURL),
            episodeID: entry.episodeID,
            episodeTitle: entry.episodeTitle,
            season: entry.season,
            episode: entry.episode,
            manifestURL: manifestURL,
            providerName: entry.providerName,
            position: entry.position,
            duration: entry.duration,
            updatedAt: entry.updatedAt
        )
    }
}

@MainActor
final class WatchAppModel: ObservableObject {
    static let defaultManifestURL = URL(
        string: "https://v3-cinemeta.strem.io/manifest.json"
    )!

    @Published private(set) var addons: [WatchAddon] = []
    @Published private(set) var addonURLs: [URL] = []
    @Published private(set) var catalogSections: [WatchCatalogSection] = []
    @Published private(set) var searchResults: [WatchMediaRoute] = []
    @Published private(set) var library: [MetaItem] = []
    @Published private(set) var progress: [WatchProgressRecord] = []
    @Published private(set) var recommendations: [WatchMediaRoute] = []
    @Published private(set) var recentSearches: [String] = []
    @Published private(set) var mediaRatings: [LocalMediaIdentity: MediaReaction] = [:]
    @Published private(set) var viewingProfileSnapshot: ViewingProfileSnapshot?
    @Published private(set) var accountEmail: String?
    @Published private(set) var accountSyncStatus = "Not signed in"
    @Published private(set) var isSyncingAccount = false
    @Published private(set) var streamingServerOnline = false
    @Published var streamingServerInput: String
    @Published private(set) var isLoadingHome = false
    @Published private(set) var isSearching = false
    @Published private(set) var statusMessage: String?
    @Published var autoplayNextEpisode = true {
        didSet { persistPlaybackSettingsIfReady() }
    }
    @Published var preferredPlaybackRate = 1.0 {
        didSet { persistPlaybackSettingsIfReady() }
    }
    @Published var preferredAudioLanguage = "en" {
        didSet { persistPlaybackSettingsIfReady() }
    }
    @Published var preferredSubtitleLanguage = "en" {
        didSet { persistPlaybackSettingsIfReady() }
    }
    @Published var preferredSubtitlesEnabled = true {
        didSet { persistPlaybackSettingsIfReady() }
    }
    @Published var accentPresetRawValue = WatchAccentPreset.orange.rawValue {
        didSet { persistPlaybackSettingsIfReady() }
    }

    private static let legacyAnonymousAddonDefaultsKey = "watch.addonManifestURLs.v1"
    private static let streamingServerDefaultsKey = "watch.streamingServerURL.v1"
    private static let autoplayDefaultsKey = "watch.autoplayNextEpisode.v1"
    private static let playbackRateDefaultsKey = "watch.preferredPlaybackRate.v1"
    private static let audioLanguageDefaultsKey = "watch.preferredAudioLanguage.v1"
    private static let subtitleLanguageDefaultsKey = "watch.preferredSubtitleLanguage.v1"
    private static let subtitlesEnabledDefaultsKey = "watch.preferredSubtitlesEnabled.v1"
    private static let accentDefaultsKey = "watch.accentPreset.v1"
    private let defaults: UserDefaults
    private let storageRoot: URL
    private let viewingProfileStore: ViewingProfileStore
    private var libraryStore: LibraryStore
    private var progressStore: WatchProgressStore
    private var completionStore: PlaybackCompletionStore
    private var ratingStore: MediaRatingStore
    private var recommendationHistoryStore: RecommendationHistoryStore
    private let recentSearchStore: RecentSearchStore
    private let accountClient: StremioAccountClient
    private let sessionStore: WatchSessionStore
    private let addonURLStore: WatchAddonURLStore
    private var session: StremioSession?
    private var syncedAddonDescriptors: [SyncedAddon] = []
    private var recommendationImpressions: [RecommendationImpression] = []
    private var rankedRecommendations: [LocalRecommendation] = []
    private var completedPlaybackIdentifiers = Set<String>()
    private var started = false
    private var isApplyingProfileSettings = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let sessionStore = WatchSessionStore()
        self.sessionStore = sessionStore
        addonURLStore = WatchAddonURLStore()
        session = nil
        accountEmail = nil
        accountSyncStatus = "Loading profile…"
        streamingServerInput = ""
        accountClient = try! StremioAccountClient()
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        storageRoot = support
        viewingProfileStore = ViewingProfileStore(rootDirectory: support)
        recentSearchStore = RecentSearchStore(
            defaults: defaults,
            namespace: "watch.recent-searches"
        )
        let bootstrap = support.appendingPathComponent("watch-bootstrap", isDirectory: true)
        libraryStore = LibraryStore(fileURL: bootstrap.appendingPathComponent("library.json"))
        progressStore = WatchProgressStore(
            fileURL: bootstrap.appendingPathComponent("playback-progress.json")
        )
        completionStore = PlaybackCompletionStore(
            fileURL: bootstrap.appendingPathComponent("playback-completions.json")
        )
        ratingStore = MediaRatingStore(
            fileURL: bootstrap.appendingPathComponent("media-ratings.json")
        )
        recommendationHistoryStore = RecommendationHistoryStore(
            fileURL: bootstrap.appendingPathComponent("recommendation-history.json")
        )
    }

    var isSignedIn: Bool { session != nil }

    var activeViewingProfile: ViewingProfile? {
        viewingProfileSnapshot?.activeProfile
    }

    var hasConfiguredStreamingServer: Bool {
        (try? StreamingServerEndpoint(streamingServerInput)) != nil
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            let snapshot = try await bootstrapViewingProfiles()
            try await activateProfile(snapshot)
        } catch {
            statusMessage = "Viewing profiles could not be loaded."
            return
        }
        await reloadAddons()
        await loadHome()
        if session != nil {
            do {
                try await syncAccount()
            } catch {
                // Offline startup keeps the last account-isolated snapshot usable.
            }
        }
    }

    private func bootstrapViewingProfiles() async throws -> ViewingProfileSnapshot {
        let legacySession = sessionStore.loadLegacy()
        let legacyScope = legacySession.map(WatchAccountScope.identifier(for:))
            ?? WatchAccountScope.anonymous
        let legacyLibraryName = legacyScope == WatchAccountScope.anonymous
            ? "watch-library.json"
            : "watch-library-account-\(legacyScope).json"
        let legacyProgressName = legacyScope == WatchAccountScope.anonymous
            ? "watch-playback-progress.json"
            : "watch-playback-progress-account-\(legacyScope).json"
        let legacyFiles = [
            ViewingProfileLegacyFile(
                fileName: ViewingProfileDataFile.anonymousLibrary,
                sourceURL: storageRoot.appendingPathComponent(legacyLibraryName)
            ),
            ViewingProfileLegacyFile(
                fileName: ViewingProfileDataFile.playbackProgress,
                sourceURL: storageRoot.appendingPathComponent(legacyProgressName)
            ),
        ]
        let snapshot = try await viewingProfileStore.bootstrap(
            defaultName: "My Watch",
            defaultAvatar: .lopBunny,
            migrating: legacyFiles
        )

        if sessionStore.load(profileID: snapshot.primaryProfileID) == nil,
           let legacySession {
            try sessionStore.save(legacySession, profileID: snapshot.primaryProfileID)
            sessionStore.clearLegacy()
        }
        let profileScope = Self.profileStorageScope(snapshot.primaryProfileID)
        if addonURLStore.load(scope: profileScope) == nil,
           let legacyAddons = addonURLStore.load(scope: legacyScope) {
            try? addonURLStore.save(legacyAddons, scope: profileScope)
        }
        return snapshot
    }

    private func activateProfile(_ snapshot: ViewingProfileSnapshot) async throws {
        let profileID = snapshot.activeProfileID
        let directory = try await viewingProfileStore.dataDirectoryURL(for: profileID)
        let nextLibraryStore = LibraryStore(
            fileURL: directory.appendingPathComponent(
                ViewingProfileDataFile.anonymousLibrary
            )
        )
        let nextProgressStore = WatchProgressStore(
            fileURL: directory.appendingPathComponent(
                ViewingProfileDataFile.playbackProgress
            )
        )
        let nextCompletionStore = PlaybackCompletionStore(
            fileURL: directory.appendingPathComponent(
                ViewingProfileDataFile.playbackCompletions
            )
        )
        let nextRatingStore = MediaRatingStore(
            fileURL: directory.appendingPathComponent(
                ViewingProfileDataFile.mediaRatings
            )
        )
        let nextRecommendationStore = RecommendationHistoryStore(
            fileURL: directory.appendingPathComponent(
                ViewingProfileDataFile.recommendationHistory
            )
        )

        libraryStore = nextLibraryStore
        progressStore = nextProgressStore
        completionStore = nextCompletionStore
        ratingStore = nextRatingStore
        recommendationHistoryStore = nextRecommendationStore
        viewingProfileSnapshot = snapshot
        session = sessionStore.load(profileID: profileID)
        accountEmail = session?.user.email
        accountSyncStatus = session == nil ? "Not signed in" : "Ready to sync"
        syncedAddonDescriptors = []
        loadProfileSettings(profileID: profileID)
        await loadLocalState()
    }

    func createViewingProfile(
        name: String,
        avatar: ViewingProfileAvatar
    ) async throws {
        let previousIDs = Set(viewingProfileSnapshot?.profiles.map(\.id) ?? [])
        let created = try await viewingProfileStore.create(name: name, avatar: avatar)
        guard let newID = created.profiles.first(where: {
            !previousIDs.contains($0.id)
        })?.id else {
            viewingProfileSnapshot = created
            return
        }
        try await selectViewingProfile(id: newID)
    }

    func updateViewingProfile(
        id: UUID,
        name: String,
        avatar: ViewingProfileAvatar
    ) async throws {
        viewingProfileSnapshot = try await viewingProfileStore.update(
            id: id,
            name: name,
            avatar: avatar
        )
    }

    func selectViewingProfile(id: UUID) async throws {
        guard id != viewingProfileSnapshot?.activeProfileID else { return }
        let snapshot = try await viewingProfileStore.activate(id: id)
        try await activateProfile(snapshot)
        searchResults = []
        await reloadAddons()
        await loadHome()
        if session != nil { try? await syncAccount() }
    }

    func archiveViewingProfile(id: UUID) async throws {
        let previousID = viewingProfileSnapshot?.activeProfileID
        let snapshot = try await viewingProfileStore.archive(id: id)
        if snapshot.activeProfileID != previousID {
            try await activateProfile(snapshot)
            await reloadAddons()
            await loadHome()
            if session != nil { try? await syncAccount() }
        } else {
            viewingProfileSnapshot = snapshot
        }
    }

    func restoreViewingProfile(id: UUID) async throws {
        viewingProfileSnapshot = try await viewingProfileStore.restore(id: id)
    }

    func loadHome() async {
        guard !addons.isEmpty else { return }
        isLoadingHome = true
        statusMessage = nil
        defer { isLoadingHome = false }

        let requests = addons.flatMap { addon in
            addon.manifest.catalogs.compactMap { descriptor -> (
                WatchAddon,
                AddonCatalog
            )? in
                guard addon.manifest.supports(
                    resource: "catalog",
                    type: descriptor.type
                ), Self.canLoadWithoutRequiredExtra(descriptor) else {
                    return nil
                }
                return (addon, descriptor)
            }
        }
        .prefix(8)

        let loaded = await withTaskGroup(
            of: (Int, WatchCatalogSection?).self
        ) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    let (addon, descriptor) = request
                    let client = try? AddonClient(
                        endpoint: AddonEndpoint(manifestURL: addon.manifestURL)
                    )
                    guard let client,
                          let items = try? await client.catalog(
                            type: descriptor.type,
                            id: descriptor.id
                          ), !items.isEmpty else {
                        return (index, nil)
                    }
                    let routes = items.prefix(20).map {
                        WatchMediaRoute(item: $0, manifestURL: addon.manifestURL)
                    }
                    let section = WatchCatalogSection(
                        id: "\(addon.manifestURL.absoluteString)|\(descriptor.type)|\(descriptor.id)",
                        title: descriptor.name ?? addon.manifest.name,
                        subtitle: descriptor.name == nil ? descriptor.type.capitalized : addon.manifest.name,
                        items: routes,
                        manifestURL: addon.manifestURL,
                        mediaType: descriptor.type,
                        catalogID: descriptor.id,
                        supportsSkip: descriptor.extra?.contains { $0.name == "skip" } == true
                    )
                    return (index, section)
                }
            }

            var results: [(Int, WatchCatalogSection)] = []
            for await (index, section) in group {
                if let section { results.append((index, section)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        catalogSections = loaded
        await refreshRecommendations()
        if loaded.isEmpty {
            statusMessage = "No catalogs were available. Check your connection or add-ons."
        }
    }

    func catalogPage(
        for section: WatchCatalogSection,
        skip: Int
    ) async throws -> [WatchMediaRoute] {
        guard section.supportsSkip,
              let endpoint = try? AddonEndpoint(manifestURL: section.manifestURL)
        else { return [] }
        return try await AddonClient(endpoint: endpoint).catalog(
            type: section.mediaType,
            id: section.catalogID,
            skip: skip
        ).map {
            WatchMediaRoute(item: $0, manifestURL: section.manifestURL)
        }
    }

    func search(_ rawQuery: String, mediaType: String? = nil) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        if let profileID = viewingProfileSnapshot?.activeProfileID {
            recentSearchStore.record(query, profileID: profileID.uuidString)
            recentSearches = recentSearchStore.queries(profileID: profileID.uuidString)
        }
        isSearching = true
        statusMessage = nil
        defer { isSearching = false }

        let requests = addons.flatMap { addon in
            addon.manifest.catalogs.compactMap { descriptor -> (
                WatchAddon,
                AddonCatalog
            )? in
                let supportsSearch = descriptor.extra?.contains {
                    $0.name == "search"
                } == true
                guard supportsSearch,
                      mediaType == nil || descriptor.type == mediaType,
                      addon.manifest.supports(resource: "catalog", type: descriptor.type)
                else { return nil }
                return (addon, descriptor)
            }
        }
        .prefix(24)

        let groups = await withTaskGroup(
            of: (Int, [WatchMediaRoute]).self
        ) { group in
            for (index, request) in requests.enumerated() {
                group.addTask {
                    let (addon, descriptor) = request
                    guard let endpoint = try? AddonEndpoint(
                        manifestURL: addon.manifestURL
                    ), let items = try? await AddonClient(endpoint: endpoint).catalog(
                        type: descriptor.type,
                        id: descriptor.id,
                        search: query
                    ) else { return (index, []) }
                    return (
                        index,
                        items.prefix(15).map {
                            WatchMediaRoute(item: $0, manifestURL: addon.manifestURL)
                        }
                    )
                }
            }

            var results: [(Int, [WatchMediaRoute])] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }

        let knownRoutes = catalogSections.flatMap(\.items) + library.map {
            WatchMediaRoute(item: $0, manifestURL: Self.defaultManifestURL)
        }
        let routeByIdentity = Dictionary(
            knownRoutes.map { (MediaIdentity($0.item), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let local = DiscoveryShelfBuilder.matchingItems(
            knownRoutes.map(\.item),
            query: query,
            mediaType: mediaType,
            limit: 20
        ).compactMap { routeByIdentity[MediaIdentity($0)] }
        var seen = Set<String>()
        searchResults = (local + groups).filter {
            seen.insert("\($0.item.type)|\($0.item.id)").inserted
        }
    }

    func relatedRoutes(to item: MetaItem) -> [WatchMediaRoute] {
        let candidates = catalogSections.flatMap(\.items)
        let routeByIdentity = Dictionary(
            candidates.map { (MediaIdentity($0.item), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return DiscoveryShelfBuilder.relatedItems(
            to: item,
            candidates: candidates.map(\.item),
            limit: 6
        ).compactMap { routeByIdentity[MediaIdentity($0)] }
    }

    func clearRecentSearches() {
        guard let profileID = viewingProfileSnapshot?.activeProfileID else { return }
        recentSearchStore.clear(profileID: profileID.uuidString)
        recentSearches = []
    }

    func reaction(for item: MetaItem) -> MediaReaction? {
        mediaRatings[LocalMediaIdentity(item: item)]
    }

    func setReaction(_ reaction: MediaReaction?, for item: MetaItem) async {
        do {
            let activeStore = ratingStore
            let ratings = try await activeStore.set(reaction, for: item)
            guard activeStore === ratingStore else { return }
            mediaRatings = Dictionary(uniqueKeysWithValues: ratings.map {
                ($0.id, $0.reaction)
            })
            await refreshRecommendations()
        } catch {
            statusMessage = "That rating could not be saved."
        }
    }

    func resetPersonalization() async {
        let activeRatingStore = ratingStore
        let activeHistoryStore = recommendationHistoryStore
        do {
            async let ratings = activeRatingStore.reset()
            async let history = activeHistoryStore.reset()
            _ = try await (ratings, history)
            guard activeRatingStore === ratingStore,
                  activeHistoryStore === recommendationHistoryStore
            else { return }
            mediaRatings = [:]
            recommendationImpressions = []
            rankedRecommendations = []
            await refreshRecommendations()
        } catch {
            statusMessage = "Personalization could not be reset."
        }
    }

    func resumeRecord(for series: MetaItem) -> WatchProgressRecord? {
        progress.first { $0.mediaID == series.id && $0.episodeID != nil }
    }

    func progressRecord(for video: Video, in series: MetaItem) -> WatchProgressRecord? {
        let identifier = EpisodePlaybackIdentity.contentIdentifier(
            seriesID: series.id,
            videoID: video.id
        )
        return progress.first { $0.contentIdentifier == identifier }
    }

    func selectedSeason(for series: MetaItem, availableSeasons: [Int]) -> Int? {
        guard let profileID = viewingProfileSnapshot?.activeProfileID else {
            return EpisodeSeasonSelector.initialSeason(
                availableSeasons: availableSeasons,
                persistedSeason: nil
            )
        }
        let persisted = defaults.object(
            forKey: seasonPreferenceKey(seriesID: series.id, profileID: profileID)
        ) as? Int
        return EpisodeSeasonSelector.initialSeason(
            availableSeasons: availableSeasons,
            persistedSeason: persisted
        )
    }

    func setSelectedSeason(_ season: Int, for series: MetaItem) {
        guard let profileID = viewingProfileSnapshot?.activeProfileID else { return }
        defaults.set(
            season,
            forKey: seasonPreferenceKey(seriesID: series.id, profileID: profileID)
        )
    }

    func details(for route: WatchMediaRoute) async -> WatchMediaRoute {
        var candidates = [route.manifestURL]
        if route.manifestURL != Self.defaultManifestURL {
            candidates.append(Self.defaultManifestURL)
        }
        for url in candidates {
            guard let endpoint = try? AddonEndpoint(manifestURL: url),
                  let detail = try? await AddonClient(endpoint: endpoint).meta(
                    type: route.item.type,
                    id: route.item.id
                  ) else { continue }
            return WatchMediaRoute(
                item: detail.fillingTrailerMetadata(from: route.item),
                manifestURL: route.manifestURL
            )
        }
        return route
    }

    func streams(
        for route: WatchMediaRoute,
        video: Video? = nil
    ) async -> [WatchStreamGroup] {
        let requestID = video?.id ?? route.item.id
        let providers = addons.filter {
            $0.manifest.supports(resource: "stream", type: route.item.type)
        }
        .prefix(12)
        let loaded = await withTaskGroup(
            of: (Int, WatchStreamGroup?).self
        ) { group in
            for (index, addon) in providers.enumerated() {
                group.addTask {
                    guard let endpoint = try? AddonEndpoint(
                        manifestURL: addon.manifestURL
                    ), let streams = try? await AddonClient(endpoint: endpoint).streams(
                        type: route.item.type,
                        id: requestID
                    ), !streams.isEmpty else { return (index, nil) }
                    var seen = Set<String>()
                    let uniqueStreams = streams.filter {
                        seen.insert($0.id).inserted
                    }
                    return (
                        index,
                        WatchStreamGroup(
                            id: addon.manifestURL.absoluteString,
                            providerName: addon.manifest.name,
                            streams: Array(uniqueStreams.prefix(40))
                        )
                    )
                }
            }

            var results: [(Int, WatchStreamGroup)] = []
            for await (index, provider) in group {
                if let provider { results.append((index, provider)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return prioritizedStreamGroups(loaded, route: route, video: video)
    }

    func recordSuccessfulPlayback(_ request: WatchPlaybackRequest) {
        guard let route = request.route,
              let identity = playbackIdentity(route: route, video: request.video),
              let key = PlaybackStreamPreferenceKey(
                providerName: request.providerName,
                streamName: request.stream.name,
                streamTitle: request.stream.title,
                torrentInfoHash: request.stream.infoHash,
                fileIndex: request.stream.fileIdx
              ),
              let profileID = viewingProfileSnapshot?.activeProfileID
        else { return }
        LastSuccessfulPlaybackPreferenceStore(
            defaults: defaults,
            storageKey: profilePreferenceKey(
                "watch.last-successful-playback.v1",
                profileID: profileID
            )
        ).recordSuccess(identity: identity, key: key)
    }

    private func prioritizedStreamGroups(
        _ groups: [WatchStreamGroup],
        route: WatchMediaRoute,
        video: Video?
    ) -> [WatchStreamGroup] {
        guard let profileID = viewingProfileSnapshot?.activeProfileID,
              let identity = playbackIdentity(route: route, video: video),
              let preference = LastSuccessfulPlaybackPreferenceStore(
                defaults: defaults,
                storageKey: profilePreferenceKey(
                    "watch.last-successful-playback.v1",
                    profileID: profileID
                )
              ).preference(for: identity)
        else { return groups }

        var rankedGroups: [(index: Int, score: Int, group: WatchStreamGroup)] = []
        for (groupIndex, group) in groups.enumerated() {
            var streams = group.streams
            streams.sort { lhs, rhs in
                let lhsScore = preferenceScore(
                    stream: lhs,
                    providerName: group.providerName,
                    preference: preference
                )
                let rhsScore = preferenceScore(
                    stream: rhs,
                    providerName: group.providerName,
                    preference: preference
                )
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                return lhs.id < rhs.id
            }
            var groupScore = 2
            for stream in streams {
                let score = preferenceScore(
                    stream: stream,
                    providerName: group.providerName,
                    preference: preference
                )
                groupScore = min(groupScore, score)
            }
            rankedGroups.append(
                (
                    index: groupIndex,
                    score: groupScore,
                    group: WatchStreamGroup(
                        id: group.id,
                        providerName: group.providerName,
                        streams: streams
                    )
                )
            )
        }
        rankedGroups.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score < rhs.score }
            return lhs.index < rhs.index
        }
        return rankedGroups.map(\.group)
    }

    private func preferenceScore(
        stream: Stream,
        providerName: String,
        preference: LastSuccessfulPlaybackPreference
    ) -> Int {
        guard let key = PlaybackStreamPreferenceKey(
            providerName: providerName,
            streamName: stream.name,
            streamTitle: stream.title,
            torrentInfoHash: stream.infoHash,
            fileIndex: stream.fileIdx
        ) else { return 2 }
        if key.providerKey == preference.providerKey,
           key.streamKey != nil,
           key.streamKey == preference.streamKey {
            return 0
        }
        return key.providerKey == preference.providerKey ? 1 : 2
    }

    private func playbackIdentity(
        route: WatchMediaRoute,
        video: Video?
    ) -> PlaybackContentIdentity? {
        if let video {
            return .episode(seriesID: route.item.id, videoID: video.id)
        }
        return .movie(catalogID: route.item.id)
    }

    func resolvePlaybackRequest(
        stream: Stream,
        providerName: String,
        route: WatchMediaRoute,
        video: Video? = nil,
        fallbackSources: [WatchPlaybackSource] = []
    ) async throws -> WatchPlaybackRequest {
        let selected = WatchPlaybackSource(providerName: providerName, stream: stream)
        let ordered = WatchPlaybackFallbackPolicy.ordered(
            sources: fallbackSources.isEmpty ? [selected] : fallbackSources,
            selectedSourceID: selected.id
        )
        var lastError: Error?
        for (index, source) in ordered.enumerated() {
            do {
                return try await resolvePlaybackSource(
                    source,
                    sourceIndex: index,
                    allSources: ordered,
                    route: route,
                    video: video
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? WatchPlaybackResolutionError.noPlayableSources
    }

    func resolveNextFallback(
        after request: WatchPlaybackRequest
    ) async throws -> WatchPlaybackRequest {
        guard let route = request.route else {
            throw WatchPlaybackResolutionError.noMoreSources
        }
        var index = request.fallbackIndex
        var lastError: Error?
        while let next = WatchPlaybackFallbackPolicy.nextIndex(
            after: index,
            sourceCount: request.fallbackSources.count
        ) {
            do {
                return try await resolvePlaybackSource(
                    request.fallbackSources[next],
                    sourceIndex: next,
                    allSources: request.fallbackSources,
                    route: route,
                    video: request.video
                )
            } catch {
                lastError = error
                index = next
            }
        }
        throw lastError ?? WatchPlaybackResolutionError.noMoreSources
    }

    func resolveAdjacentEpisode(
        from request: WatchPlaybackRequest,
        forward: Bool
    ) async throws -> WatchPlaybackRequest {
        guard let route = request.route, let current = request.video else {
            throw WatchPlaybackResolutionError.noAdjacentEpisode
        }
        let adjacent = forward
            ? EpisodeAutoplaySelector.nextEpisode(after: current, episodes: request.episodes)
            : EpisodeAutoplaySelector.previousEpisode(before: current, episodes: request.episodes)
        guard let adjacent else {
            throw WatchPlaybackResolutionError.noAdjacentEpisode
        }
        let groups = await streams(for: route, video: adjacent)
        let sources = groups.flatMap { group in
            group.streams.map {
                WatchPlaybackSource(providerName: group.providerName, stream: $0)
            }
        }
        guard !sources.isEmpty else {
            throw WatchPlaybackResolutionError.noPlayableSources
        }
        let preferred = sources.first {
            $0.providerName == request.providerName
        } ?? sources[0]
        return try await resolvePlaybackRequest(
            stream: preferred.stream,
            providerName: preferred.providerName,
            route: route,
            video: adjacent,
            fallbackSources: sources
        )
    }

    private func resolvePlaybackSource(
        _ source: WatchPlaybackSource,
        sourceIndex: Int,
        allSources: [WatchPlaybackSource],
        route: WatchMediaRoute,
        video: Video?
    ) async throws -> WatchPlaybackRequest {
        let stream = source.stream
        var streamForAssessment = stream
        if let directURL = stream.url,
           TorBoxPlaybackResolver.shouldResolve(
            stream: stream,
            url: directURL,
            providerName: source.providerName
           ) {
            let resolved = try await TorBoxPlaybackResolver.resolve(
                directURL,
                stream: stream
            )
            let compatibilityHint: String?
            switch resolved.detectedMIMEType {
            case "video/x-matroska": compatibilityHint = "watch-resolved.mkv"
            case "video/webm": compatibilityHint = "watch-resolved.webm"
            default: compatibilityHint = stream.description
            }
            streamForAssessment = Stream(
                url: resolved.url,
                externalUrl: nil,
                name: stream.name,
                title: stream.title,
                description: compatibilityHint,
                infoHash: nil,
                fileIdx: stream.fileIdx,
                sources: stream.sources,
                skipSegments: stream.skipSegments,
                behaviorHints: stream.behaviorHints
            )
        }
        let assessment = WatchStreamCompatibility.assess(streamForAssessment)
        if let playbackURL = assessment.playbackURL,
           let kind = assessment.kind,
           assessment.isPlayable {
            return makePlaybackRequest(
                stream: stream,
                playbackURL: playbackURL,
                kind: kind,
                providerName: source.providerName,
                route: route,
                video: video,
                fallbackSources: allSources,
                fallbackIndex: sourceIndex
            )
        }

        guard let endpoint = try? StreamingServerEndpoint(streamingServerInput)
        else {
            throw WatchPlaybackResolutionError.incompatible(
                assessment.incompatibility?.message
                    ?? "This source is not compatible with Apple Watch."
            )
        }

        let client = TorrentStreamingClient(endpoint: endpoint)
        let online = await client.isOnline()
        streamingServerOnline = online
        guard online else { throw StreamingServerError.unavailable }

        let sourceURL: URL
        if stream.isTorrent {
            sourceURL = try await client.playbackURL(for: stream)
        } else if let url = streamForAssessment.url,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  url.user == nil,
                  url.password == nil {
            sourceURL = url
        } else {
            throw WatchPlaybackResolutionError.incompatible(
                assessment.incompatibility?.message
                    ?? "The configured server cannot convert this source."
            )
        }

        let convertedURL = try await client.compatibilityPlaybackURL(
            for: sourceURL
        )
        let converted = WatchStreamCompatibility.assessStreamingServerURL(
            convertedURL,
            endpoint: endpoint
        )
        guard let playbackURL = converted.playbackURL,
              let kind = converted.kind,
              converted.isPlayable
        else {
            throw WatchPlaybackResolutionError.incompatible(
                converted.incompatibility?.message
                    ?? "The streaming server did not return compatible HLS."
            )
        }

        return makePlaybackRequest(
            stream: stream,
            playbackURL: playbackURL,
            kind: kind,
            providerName: source.providerName,
            route: route,
            video: video,
            fallbackSources: allSources,
            fallbackIndex: sourceIndex
        )
    }

    func canResolveWithStreamingServer(_ stream: Stream) -> Bool {
        guard hasConfiguredStreamingServer else { return false }
        if stream.isTorrent { return true }
        guard let url = stream.url,
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.user == nil,
              url.password == nil
        else { return false }
        return !WatchStreamCompatibility.assess(stream).isPlayable
    }

    private func makePlaybackRequest(
        stream: Stream,
        playbackURL: URL,
        kind: WatchStreamKind,
        providerName: String,
        route: WatchMediaRoute,
        video: Video?,
        fallbackSources: [WatchPlaybackSource],
        fallbackIndex: Int
    ) -> WatchPlaybackRequest {

        let contentIdentifier: String
        let contentTitle: String
        let metadata: PlaybackMediaMetadata
        if let video {
            contentIdentifier = EpisodePlaybackIdentity.contentIdentifier(
                seriesID: route.item.id,
                videoID: video.id
            )
            contentTitle = EpisodePlaybackIdentity.contentTitle(
                seriesTitle: route.item.name,
                video: video
            )
            metadata = .episode(series: route.item, episode: video)
        } else {
            contentIdentifier = "\(route.item.type):\(route.item.id)"
            contentTitle = route.item.name
            metadata = .movie(route.item)
        }

        return WatchPlaybackRequest(
            id: "\(contentIdentifier)|\(stream.id)",
            stream: stream,
            playbackURL: playbackURL,
            kind: kind,
            title: contentTitle,
            subtitle: video?.title ?? providerName,
            providerName: providerName,
            contentIdentifier: contentIdentifier,
            mediaMetadata: metadata,
            manifestURL: route.manifestURL,
            initialPosition: progress.first {
                $0.contentIdentifier == contentIdentifier
            }?.position ?? 0,
            fallbackSources: fallbackSources,
            fallbackIndex: fallbackIndex,
            route: route,
            video: video,
            episodes: route.item.videos ?? []
        )
    }

    func resolveManualPlaybackRequest(
        urlInput: String
    ) async throws -> WatchPlaybackRequest {
        let trimmed = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            throw WatchManualStreamError.invalidURL
        }
        let assessment = WatchStreamCompatibility.assess(url: url)
        if let playbackURL = assessment.playbackURL,
           let kind = assessment.kind,
           assessment.isPlayable {
            return makeManualPlaybackRequest(
                sourceURL: url,
                playbackURL: playbackURL,
                kind: kind
            )
        }

        guard let endpoint = try? StreamingServerEndpoint(streamingServerInput),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.user == nil,
              url.password == nil
        else {
            throw WatchManualStreamError.incompatible(
                assessment.incompatibility?.message
                    ?? "This stream cannot be played on Apple Watch."
            )
        }
        let client = TorrentStreamingClient(endpoint: endpoint)
        let online = await client.isOnline()
        streamingServerOnline = online
        guard online else { throw StreamingServerError.unavailable }
        let convertedURL = try await client.compatibilityPlaybackURL(for: url)
        let converted = WatchStreamCompatibility.assessStreamingServerURL(
            convertedURL,
            endpoint: endpoint
        )
        guard let playbackURL = converted.playbackURL,
              let kind = converted.kind,
              converted.isPlayable
        else {
            throw WatchManualStreamError.incompatible(
                converted.incompatibility?.message
                    ?? "The streaming server did not return compatible HLS."
            )
        }
        return makeManualPlaybackRequest(
            sourceURL: url,
            playbackURL: playbackURL,
            kind: kind
        )
    }

    private func makeManualPlaybackRequest(
        sourceURL: URL,
        playbackURL: URL,
        kind: WatchStreamKind,
        title: String = "Direct Stream",
        subtitle: String? = nil
    ) -> WatchPlaybackRequest {
        let stream = Stream(
            url: sourceURL,
            externalUrl: nil,
            name: sourceURL.host,
            title: nil,
            description: nil,
            infoHash: nil,
            fileIdx: nil,
            sources: nil
        )
        return WatchPlaybackRequest(
            id: UUID().uuidString,
            stream: stream,
            playbackURL: playbackURL,
            kind: kind,
            title: title,
            subtitle: subtitle ?? sourceURL.host,
            providerName: nil,
            contentIdentifier: nil,
            mediaMetadata: nil,
            manifestURL: nil,
            initialPosition: 0,
            fallbackSources: [],
            fallbackIndex: 0,
            route: nil,
            video: nil,
            episodes: []
        )
    }

    func resolveTrailerPlaybackRequest(
        url: URL,
        title: String
    ) throws -> WatchPlaybackRequest {
        let assessment = WatchStreamCompatibility.assess(url: url)
        guard let playbackURL = assessment.playbackURL,
              let kind = assessment.kind,
              assessment.isPlayable
        else {
            throw WatchPlaybackResolutionError.incompatible(
                assessment.incompatibility?.message
                    ?? "This trailer link is not an Apple Watch video stream."
            )
        }
        return makeManualPlaybackRequest(
            sourceURL: url,
            playbackURL: playbackURL,
            kind: kind,
            title: "\(title) Trailer",
            subtitle: "Trailer"
        )
    }

#if DEBUG
    /// Simulator capture hook. It is compiled out of release builds and reads
    /// the injected URL only from the current process environment.
    func debugDemoPlaybackRequest(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> WatchPlaybackRequest? {
        guard environment["TEMUSTREMIO_WATCH_DEMO"] == "1",
              let rawURL = environment["TEMUSTREMIO_WATCH_DEMO_STREAM_URL"],
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil
        else { return nil }
        let assessment = WatchStreamCompatibility.assess(url: url)
        guard assessment.kind == .hls,
              assessment.isPlayable,
              let playbackURL = assessment.playbackURL
        else { return nil }
        let rawTitle = environment["TEMUSTREMIO_WATCH_DEMO_TITLE"]
            ?? "Bunny Demo"
        let title = String(
            rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)
        )
        return makeManualPlaybackRequest(
            sourceURL: url,
            playbackURL: playbackURL,
            kind: .hls,
            title: title.isEmpty ? "Bunny Demo" : title,
            subtitle: "Injected HLS · Debug only"
        )
    }
#endif

    func toggleLibrary(_ item: MetaItem) async {
        do {
            let activeStore = libraryStore
            let updated = try await activeStore.toggle(item)
            guard activeStore === libraryStore else { return }
            library = updated

            if let activeSession = session,
               viewingProfileSnapshot?.activeProfileAllowsAccountLibrarySync == true {
                let isRemoved = !updated.contains {
                    $0.id == item.id && $0.type == item.type
                }
                do {
                    try await accountClient.pushLibrary(
                        authKey: activeSession.authKey,
                        changes: [RemoteLibraryItem(item: item, removed: isRemoved)]
                    )
                    if session?.authKey == activeSession.authKey {
                        accountSyncStatus = "Library synced"
                    }
                } catch {
                    if session?.authKey == activeSession.authKey {
                        accountSyncStatus = "Library saved locally · Sync failed"
                    }
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func isInLibrary(_ item: MetaItem) -> Bool {
        library.contains { $0.type == item.type && $0.id == item.id }
    }

    func recordPlayback(
        _ request: WatchPlaybackRequest,
        position: TimeInterval,
        duration: TimeInterval
    ) async {
        guard let contentIdentifier = request.contentIdentifier,
              let metadata = request.mediaMetadata,
              let manifestURL = WatchPlaybackPersistencePolicy
                .sanitizedReferenceURL(request.manifestURL),
              position.isFinite,
              duration.isFinite,
              position >= PlaybackProgress.minimumResumePosition else { return }
        let record = WatchProgressRecord(
            contentIdentifier: contentIdentifier,
            contentTitle: request.title,
            mediaID: metadata.mediaID,
            mediaType: metadata.mediaType,
            mediaTitle: metadata.mediaTitle,
            posterURL: WatchPlaybackPersistencePolicy
                .sanitizedReferenceURL(metadata.posterURL),
            episodeID: metadata.episodeID,
            episodeTitle: metadata.episodeTitle,
            season: metadata.season,
            episode: metadata.episode,
            manifestURL: manifestURL,
            providerName: request.providerName,
            position: position,
            duration: duration,
            updatedAt: Date()
        )
        do {
            let activeProgressStore = progressStore
            let activeCompletionStore = completionStore
            let updatedProgress = try await activeProgressStore.record(record)
            if PlaybackProgress.isCompleted(position: position, duration: duration) {
                let completions = try await activeCompletionStore.markCompleted(
                    contentIdentifier: contentIdentifier
                )
                guard activeProgressStore === progressStore,
                      activeCompletionStore === completionStore
                else { return }
                completedPlaybackIdentifiers = Set(completions.map(\.contentIdentifier))
            } else if completedPlaybackIdentifiers.contains(contentIdentifier) {
                let completions = try await activeCompletionStore.markIncomplete(
                    contentIdentifier: contentIdentifier
                )
                guard activeProgressStore === progressStore,
                      activeCompletionStore === completionStore
                else { return }
                completedPlaybackIdentifiers = Set(completions.map(\.contentIdentifier))
            }
            guard activeProgressStore === progressStore else { return }
            progress = updatedProgress
            await refreshRecommendations()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func isEpisodeCompleted(_ video: Video, in series: MetaItem) -> Bool {
        completedPlaybackIdentifiers.contains(
            EpisodePlaybackIdentity.contentIdentifier(
                seriesID: series.id,
                videoID: video.id
            )
        )
    }

    func removeProgress(_ record: WatchProgressRecord) async {
        do {
            progress = try await progressStore.remove(
                contentIdentifier: record.contentIdentifier
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func signIn(email: String, password: String) async throws {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty, !password.isEmpty else {
            throw WatchAccountError.missingCredentials
        }

        let responseSession = try await accountClient.login(
            email: cleanEmail,
            password: password
        )
        let signedIn = responseSession.user.email == nil
            ? StremioSession(
                authKey: responseSession.authKey,
                user: StremioUser(
                    id: responseSession.user.id,
                    email: cleanEmail
                )
            )
            : responseSession
        guard let profileID = viewingProfileSnapshot?.activeProfileID else {
            throw WatchAccountError.profileUnavailable
        }
        try sessionStore.save(signedIn, profileID: profileID)
        session = signedIn
        accountEmail = signedIn.user.email ?? cleanEmail
        accountSyncStatus = "Ready to sync"
        syncedAddonDescriptors = []

        do {
            try await syncAccount()
        } catch {
            // The secure session remains valid and the account-specific local
            // snapshot stays available when the network is temporarily down.
        }
    }

    func signOut() async {
        if let profileID = viewingProfileSnapshot?.activeProfileID {
            sessionStore.clear(profileID: profileID)
        }
        session = nil
        accountEmail = nil
        syncedAddonDescriptors = []
        accountSyncStatus = "Not signed in"
    }

    func syncAccount() async throws {
        guard let activeSession = session else {
            throw WatchAccountError.notSignedIn
        }
        let activeStore = libraryStore
        isSyncingAccount = true
        accountSyncStatus = "Syncing…"
        defer { isSyncingAccount = false }

        do {
            let allowsLibrarySync = viewingProfileSnapshot?
                .activeProfileAllowsAccountLibrarySync == true
            let addonSnapshot: [SyncedAddon]
            if allowsLibrarySync {
                async let remoteLibrary = accountClient.pullLibrary(
                    authKey: activeSession.authKey
                )
                async let remoteAddons = accountClient.pullAddons(
                    authKey: activeSession.authKey
                )
                let snapshots = try await (remoteLibrary, remoteAddons)
                guard session?.authKey == activeSession.authKey,
                      activeStore === libraryStore
                else { return }
                library = try await activeStore.replaceWithRemoteSnapshot(snapshots.0)
                addonSnapshot = snapshots.1
            } else {
                addonSnapshot = try await accountClient.pullAddons(
                    authKey: activeSession.authKey
                )
            }
            guard session?.authKey == activeSession.authKey,
                  activeStore === libraryStore
            else { return }

            await applySyncedAddonSnapshot(addonSnapshot)
            accountSyncStatus = allowsLibrarySync
                ? "Library & add-ons synced"
                : "Add-ons synced · Library stays local"
            await loadHome()
        } catch {
            if session?.authKey == activeSession.authKey {
                accountSyncStatus = "Sync failed"
            }
            throw error
        }
    }

    func saveStreamingServer() async throws {
        let endpoint = try StreamingServerEndpoint(streamingServerInput)
        streamingServerInput = endpoint.baseURL.absoluteString
        if let profileID = viewingProfileSnapshot?.activeProfileID {
            defaults.set(
                endpoint.baseURL.absoluteString,
                forKey: profilePreferenceKey(
                    Self.streamingServerDefaultsKey,
                    profileID: profileID
                )
            )
        }
        await refreshStreamingServerStatus()
    }

    func clearStreamingServer() {
        if let profileID = viewingProfileSnapshot?.activeProfileID {
            defaults.removeObject(
                forKey: profilePreferenceKey(
                    Self.streamingServerDefaultsKey,
                    profileID: profileID
                )
            )
        }
        streamingServerInput = ""
        streamingServerOnline = false
    }

    func refreshStreamingServerStatus() async {
        guard let endpoint = try? StreamingServerEndpoint(streamingServerInput)
        else {
            streamingServerOnline = false
            return
        }
        streamingServerOnline = await TorrentStreamingClient(
            endpoint: endpoint
        ).isOnline()
    }

    func installAddon(_ input: String) async throws {
        let endpoint = try AddonEndpoint(manifestInput: input)
        let manifest = try await AddonClient(endpoint: endpoint).manifest()
        var urls = storedAddonURLs()
        if !urls.contains(endpoint.manifestURL) {
            guard urls.count < 13 else {
                throw WatchAddonInstallError.limitReached
            }
            urls.append(endpoint.manifestURL)
            persistAddonURLs(urls)
        }
        if !addons.contains(where: { $0.manifestURL == endpoint.manifestURL }) {
            addons.append(WatchAddon(manifestURL: endpoint.manifestURL, manifest: manifest))
        }
        addonURLs = urls
        if let activeSession = session {
            do {
                var remote = try await accountClient.pullAddons(
                    authKey: activeSession.authKey
                )
                remote.removeAll { $0.transportUrl == endpoint.manifestURL }
                remote.append(
                    SyncedAddon(
                        manifest: manifest,
                        transportUrl: endpoint.manifestURL
                    )
                )
                try await accountClient.pushAddons(
                    authKey: activeSession.authKey,
                    addons: remote
                )
                if session?.authKey == activeSession.authKey {
                    syncedAddonDescriptors = remote
                    accountSyncStatus = "Add-ons synced"
                }
            } catch {
                if session?.authKey == activeSession.authKey {
                    accountSyncStatus = "Add-on installed locally · Sync failed"
                }
                await loadHome()
                throw error
            }
        }
        await loadHome()
    }

    func removeAddon(_ url: URL) async {
        guard url != Self.defaultManifestURL else { return }
        let urls = storedAddonURLs().filter { $0 != url }
        persistAddonURLs(urls)
        addonURLs = urls
        addons.removeAll { $0.manifestURL == url }
        if let activeSession = session {
            do {
                var remote = try await accountClient.pullAddons(
                    authKey: activeSession.authKey
                )
                remote.removeAll { $0.transportUrl == url }
                try await accountClient.pushAddons(
                    authKey: activeSession.authKey,
                    addons: remote
                )
                if session?.authKey == activeSession.authKey {
                    syncedAddonDescriptors = remote
                    accountSyncStatus = "Add-ons synced"
                }
            } catch {
                if session?.authKey == activeSession.authKey {
                    accountSyncStatus = "Add-on removed locally · Sync failed"
                }
            }
        }
        await loadHome()
    }

    private func loadLocalState() async {
        library = []
        progress = []
        mediaRatings = [:]
        recommendationImpressions = []
        completedPlaybackIdentifiers = []
        do {
            library = try await libraryStore.items()
        } catch {
            statusMessage = "Library could not be loaded."
        }
        do {
            progress = try await progressStore.items()
        } catch {
            statusMessage = "Playback progress could not be loaded."
        }
        if let completions = try? await completionStore.items() {
            completedPlaybackIdentifiers = Set(completions.map(\.contentIdentifier))
        }
        if let ratings = try? await ratingStore.items() {
            mediaRatings = Dictionary(uniqueKeysWithValues: ratings.map {
                ($0.id, $0.reaction)
            })
        }
        recommendationImpressions = (try? await recommendationHistoryStore.items()) ?? []
        if let profileID = viewingProfileSnapshot?.activeProfileID {
            recentSearches = recentSearchStore.queries(profileID: profileID.uuidString)
        }
    }

    private func refreshRecommendations() async {
        let candidates = catalogSections.flatMap(\.items)
        var seen = Set<LocalMediaIdentity>()
        let uniqueRoutes = candidates.filter {
            seen.insert(LocalMediaIdentity(item: $0.item)).inserted
        }
        let activities = library.map {
            RecommendationActivity(item: $0, kind: .addedToLibrary)
        } + progress.map {
            RecommendationActivity(item: $0.mediaRoute.item, kind: .watched)
        }
        let ratings = mediaRatings.map { identity, reaction in
            let known = library.first {
                $0.id == identity.id && $0.type == identity.type
            } ?? uniqueRoutes.first {
                $0.item.id == identity.id && $0.item.type == identity.type
            }?.item ?? MetaItem(
                id: identity.id,
                type: identity.type,
                name: identity.id
            )
            return MediaRating(media: LocalMediaSnapshot(item: known), reaction: reaction)
        }
        let ranked = LocalRecommendationEngine.recommend(
            candidates: uniqueRoutes.map(\.item),
            activity: activities,
            ratings: ratings,
            impressions: recommendationImpressions,
            limit: 8
        )
        rankedRecommendations = ranked
        let routeByIdentity = Dictionary(
            uniqueKeysWithValues: uniqueRoutes.map {
                (LocalMediaIdentity(item: $0.item), $0)
            }
        )
        recommendations = ranked.compactMap { routeByIdentity[$0.id] }
    }

    func recordRecommendationImpression(for route: WatchMediaRoute) async {
        let identity = LocalMediaIdentity(item: route.item)
        guard let recommendation = rankedRecommendations.first(where: {
            $0.id == identity
        }) else { return }
        let activeStore = recommendationHistoryStore
        guard let updated = try? await activeStore.record([recommendation]),
              activeStore === recommendationHistoryStore
        else { return }
        recommendationImpressions = updated
    }

    private func reloadAddons() async {
        let urls = storedAddonURLs()
        addonURLs = urls
        let loaded = await withTaskGroup(of: (Int, WatchAddon?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    guard let endpoint = try? AddonEndpoint(manifestURL: url),
                          let manifest = try? await AddonClient(endpoint: endpoint).manifest()
                    else { return (index, nil) }
                    return (
                        index,
                        WatchAddon(manifestURL: url, manifest: manifest)
                    )
                }
            }
            var results: [(Int, WatchAddon)] = []
            for await (index, addon) in group {
                if let addon { results.append((index, addon)) }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        addons = loaded
        if loaded.isEmpty {
            statusMessage = "Add-ons are unavailable. Check your watch connection."
        }
    }

    private func applySyncedAddonSnapshot(
        _ snapshot: [SyncedAddon]
    ) async {
        var seen = Set<URL>()
        let valid = snapshot.filter { descriptor in
            guard (try? AddonEndpoint(
                manifestURL: descriptor.transportUrl
            )) != nil else { return false }
            return seen.insert(descriptor.transportUrl).inserted
        }
        syncedAddonDescriptors = valid

        let defaultDescriptor = valid.first {
            $0.transportUrl == Self.defaultManifestURL
        }
        let customDescriptors = valid.filter {
            $0.transportUrl != Self.defaultManifestURL
        }
        let visibleDescriptors = Array(customDescriptors.prefix(12))
        let visibleURLs = [Self.defaultManifestURL]
            + visibleDescriptors.map(\.transportUrl)

        var nextAddons: [WatchAddon] = []
        if let defaultDescriptor {
            nextAddons.append(
                WatchAddon(
                    manifestURL: Self.defaultManifestURL,
                    manifest: defaultDescriptor.manifest
                )
            )
        } else if let existing = addons.first(where: {
            $0.manifestURL == Self.defaultManifestURL
        }) {
            nextAddons.append(existing)
        } else if let endpoint = try? AddonEndpoint(
            manifestURL: Self.defaultManifestURL
        ), let manifest = try? await AddonClient(endpoint: endpoint).manifest() {
            nextAddons.append(
                WatchAddon(
                    manifestURL: Self.defaultManifestURL,
                    manifest: manifest
                )
            )
        }
        nextAddons.append(contentsOf: visibleDescriptors.map {
            WatchAddon(manifestURL: $0.transportUrl, manifest: $0.manifest)
        })

        addonURLs = visibleURLs
        addons = nextAddons
        persistAddonURLs(visibleURLs)
    }

    private func storedAddonURLs() -> [URL] {
        var stored = addonURLStore.load(scope: activeStorageScope) ?? []
        if session == nil,
           stored.isEmpty,
           let legacy = defaults.stringArray(
            forKey: Self.legacyAnonymousAddonDefaultsKey
           ) {
            stored = legacy.compactMap(URL.init(string:))
            try? addonURLStore.save(stored, scope: activeStorageScope)
            defaults.removeObject(forKey: Self.legacyAnonymousAddonDefaultsKey)
        }
        var seen = Set<URL>()
        let urls = ([Self.defaultManifestURL] + stored)
            .filter { seen.insert($0).inserted }
        return Array(urls.prefix(13))
    }

    private func persistAddonURLs(_ urls: [URL]) {
        do {
            try addonURLStore.save(
                urls.filter { $0 != Self.defaultManifestURL },
                scope: activeStorageScope
            )
        } catch {
            statusMessage = "Add-on settings could not be saved securely."
        }
    }

    private var activeStorageScope: String {
        guard let profileID = viewingProfileSnapshot?.activeProfileID else {
            return "profile-unavailable"
        }
        return Self.profileStorageScope(profileID)
    }

    private static func profileStorageScope(_ profileID: UUID) -> String {
        "profile-\(profileID.uuidString.lowercased())"
    }

    private func loadProfileSettings(profileID: UUID) {
        isApplyingProfileSettings = true
        defer { isApplyingProfileSettings = false }

        let serverKey = profilePreferenceKey(
            Self.streamingServerDefaultsKey,
            profileID: profileID
        )
        if defaults.object(forKey: serverKey) == nil,
           profileID == viewingProfileSnapshot?.primaryProfileID,
           let legacy = defaults.string(forKey: Self.streamingServerDefaultsKey) {
            defaults.set(legacy, forKey: serverKey)
        }
        streamingServerInput = defaults.string(forKey: serverKey) ?? ""

        let autoplayKey = profilePreferenceKey(Self.autoplayDefaultsKey, profileID: profileID)
        autoplayNextEpisode = defaults.object(forKey: autoplayKey) == nil
            ? true
            : defaults.bool(forKey: autoplayKey)

        let rate = defaults.double(
            forKey: profilePreferenceKey(Self.playbackRateDefaultsKey, profileID: profileID)
        )
        preferredPlaybackRate = [0.75, 1.0, 1.25, 1.5].contains(rate) ? rate : 1.0
        preferredAudioLanguage = defaults.string(
            forKey: profilePreferenceKey(Self.audioLanguageDefaultsKey, profileID: profileID)
        ) ?? "en"
        preferredSubtitleLanguage = defaults.string(
            forKey: profilePreferenceKey(Self.subtitleLanguageDefaultsKey, profileID: profileID)
        ) ?? "en"
        let subtitlesKey = profilePreferenceKey(
            Self.subtitlesEnabledDefaultsKey,
            profileID: profileID
        )
        preferredSubtitlesEnabled = defaults.object(forKey: subtitlesKey) == nil
            ? true
            : defaults.bool(forKey: subtitlesKey)
        let storedAccent = defaults.string(
            forKey: profilePreferenceKey(Self.accentDefaultsKey, profileID: profileID)
        )
        accentPresetRawValue = WatchAccentPreset(rawValue: storedAccent ?? "")?.rawValue
            ?? WatchAccentPreset.orange.rawValue
    }

    private func persistPlaybackSettingsIfReady() {
        guard !isApplyingProfileSettings,
              let profileID = viewingProfileSnapshot?.activeProfileID
        else { return }
        defaults.set(
            autoplayNextEpisode,
            forKey: profilePreferenceKey(Self.autoplayDefaultsKey, profileID: profileID)
        )
        defaults.set(
            preferredPlaybackRate,
            forKey: profilePreferenceKey(Self.playbackRateDefaultsKey, profileID: profileID)
        )
        defaults.set(
            preferredAudioLanguage,
            forKey: profilePreferenceKey(Self.audioLanguageDefaultsKey, profileID: profileID)
        )
        defaults.set(
            preferredSubtitleLanguage,
            forKey: profilePreferenceKey(Self.subtitleLanguageDefaultsKey, profileID: profileID)
        )
        defaults.set(
            preferredSubtitlesEnabled,
            forKey: profilePreferenceKey(Self.subtitlesEnabledDefaultsKey, profileID: profileID)
        )
        defaults.set(
            accentPresetRawValue,
            forKey: profilePreferenceKey(Self.accentDefaultsKey, profileID: profileID)
        )
    }

    private func profilePreferenceKey(_ base: String, profileID: UUID) -> String {
        "\(base).\(profileID.uuidString.lowercased())"
    }

    private func seasonPreferenceKey(seriesID: String, profileID: UUID) -> String {
        let encoded = Data(seriesID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return profilePreferenceKey(
            "watch.selected-season.\(encoded)",
            profileID: profileID
        )
    }

    private static func canLoadWithoutRequiredExtra(_ catalog: AddonCatalog) -> Bool {
        !(catalog.extra ?? []).contains {
            $0.isRequired == true && $0.name != "skip"
        }
    }
}

enum WatchManualStreamError: LocalizedError {
    case invalidURL
    case incompatible(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a complete HTTP or HTTPS stream URL."
        case let .incompatible(message):
            message
        }
    }
}

enum WatchAddonInstallError: LocalizedError {
    case limitReached

    var errorDescription: String? {
        "Apple Watch supports up to 12 custom add-ons. Remove one before adding another."
    }
}

enum WatchAccountError: LocalizedError {
    case missingCredentials
    case notSignedIn
    case profileUnavailable

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Enter both your Stremio email and password."
        case .notSignedIn:
            "Sign in to a Stremio account before syncing."
        case .profileUnavailable:
            "Select a viewing profile before signing in."
        }
    }
}

enum WatchPlaybackResolutionError: LocalizedError {
    case incompatible(String)
    case noPlayableSources
    case noMoreSources
    case noAdjacentEpisode

    var errorDescription: String? {
        switch self {
        case let .incompatible(message): message
        case .noPlayableSources:
            "None of the available sources could be prepared for Apple Watch."
        case .noMoreSources:
            "There are no more compatible sources to try."
        case .noAdjacentEpisode:
            "There is no episode in that direction."
        }
    }
}
