import AVFoundation
import Combine
import Foundation
import UIKit

struct E2EResult: Sendable {
    let manifest: String
    let catalogCount: Int
    let letterboxdCatalogCount: Int
    let sourceSwitchAndPaging: Bool
    let globalSearch: Bool
    let detail: String
    let streamCount: Int
    let providerGrouping: Bool
    let bunnyDirectStartupMilliseconds: Double
    let bunnyHLSStartupMilliseconds: Double
    let bunnyContainerStartupMilliseconds: Double
    let bunnyTorrentStartupMilliseconds: Double
    let libraryRoundTrip: Bool
    let accountSync: Bool
    let sessionPersistenceRoundTrip: Bool
}

struct CatalogSource: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let manifestURL: URL
    let preferredType: String
    let preferredCatalogID: String

    var discoveryShelfTitle: String {
        switch id {
        case "cinemeta": "Popular Movies"
        case "cinemeta-series": "Popular Series"
        default: title
        }
    }
}

private struct CatalogLoadResult: Sendable {
    let source: CatalogSource
    let endpoint: AddonEndpoint
    let manifest: AddonManifest
    let descriptor: AddonCatalog
    let items: [MetaItem]
    let cacheHit: Bool
}

private struct DetailRequestKey: Hashable, Sendable {
    let identity: MediaIdentity
    let endpointURLs: [URL]
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
    let manifestURL: URL
    let items: [MetaItem]
}

private struct SearchCatalogAttempt: Sendable {
    let index: Int
    let group: SearchCatalogGroup?
    let succeeded: Bool
}

private struct SearchProviderOutcome: Sendable {
    let index: Int
    let groups: [SearchCatalogGroup]
    let attemptedRequestCount: Int
    let successfulRequestCount: Int
}

struct PlaybackPlan: Sendable {
    let primaryURL: URL
    let fallbackURL: URL?
    let requiresCompatibilityPlayback: Bool
    let detectedMIMEType: String?
    let trustedPrivateNetworkOrigin: URL?
    let requiresFreshProviderResolutionOnFailure: Bool

    init(
        primaryURL: URL,
        fallbackURL: URL? = nil,
        requiresCompatibilityPlayback: Bool = false,
        detectedMIMEType: String? = nil,
        trustedPrivateNetworkOrigin: URL? = nil,
        requiresFreshProviderResolutionOnFailure: Bool = false
    ) {
        self.primaryURL = primaryURL
        self.fallbackURL = fallbackURL
        self.requiresCompatibilityPlayback = requiresCompatibilityPlayback
        self.detectedMIMEType = detectedMIMEType
        self.trustedPrivateNetworkOrigin = trustedPrivateNetworkOrigin
        self.requiresFreshProviderResolutionOnFailure =
            requiresFreshProviderResolutionOnFailure
    }
}

private enum StreamProviderLoadError: Error, Sendable {
    case timedOut
}

private enum AppModelPersistenceError: LocalizedError {
    case addonStoreUnavailable

    var errorDescription: String? {
        switch self {
        case .addonStoreUnavailable:
            "Saved add-ons are unavailable, so Bunny did not overwrite them."
        }
    }
}

enum PlaybackProgressUpdateKind: Sendable, Equatable {
    case checkpoint
    case final
}

struct ContinueWatchingEntry: Identifiable, Equatable, Sendable {
    let progress: PlaybackProgress
    let item: MetaItem
    let episode: Video?

    var id: String { progress.contentIdentifier }

    var mediaMetadata: PlaybackMediaMetadata {
        if let episode {
            return .episode(series: item, episode: episode)
        }
        return .movie(item)
    }
}

private struct PreparedProfileActivation {
    let revision: Int
    let snapshot: ViewingProfileSnapshot
    let libraryStore: LibraryStore
    let playbackStateStore: PlaybackStateStore
    let mediaRatingStore: MediaRatingStore
    let recommendationHistoryStore: RecommendationHistoryStore
    let library: [MetaItem]
    let playbackState: PlaybackStateSnapshot
    let mediaRatings: [MediaRating]
    let recommendationImpressions: [RecommendationImpression]
    let installedAddons: [URL]
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var manifest: AddonManifest?
    @Published private(set) var catalog: [MetaItem] = []
    @Published private(set) var homeShelves: [DiscoveryShelf] = []
    @Published private(set) var catalogSources: [CatalogSource]
    @Published private(set) var selectedCatalogSourceID: String
    @Published private(set) var isLoadingNextPage = false
    @Published private(set) var searchCatalogs: [SearchCatalogGroup] = []
    @Published private(set) var isSearching = false
    @Published private(set) var activeSearchQuery: String?
    @Published private(set) var searchFailureMessage: String?
    @Published private(set) var library: [MetaItem] = []
    @Published private(set) var playbackProgress: [String: PlaybackProgress] = [:]
    @Published private(set) var completedPlaybackIdentifiers: Set<String> = []
    @Published private(set) var viewingProfileSnapshot: ViewingProfileSnapshot?
    @Published private(set) var mediaRatings: [LocalMediaIdentity: MediaReaction] = [:]
    @Published private(set) var localRecommendations: [LocalRecommendation] = []
    @Published private(set) var isLoadingMoreRecommendations = false
    @Published private(set) var canLoadMoreRecommendations = false
    @Published private(set) var recentSearches: [String] = []
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
    private let libraryDirectory: URL
    private var libraryStore: LibraryStore
    private var playbackStateStore: PlaybackStateStore
    private let viewingProfileStore: ViewingProfileStore
    private var mediaRatingStore: MediaRatingStore
    private var recommendationHistoryStore: RecommendationHistoryStore
    private let libraryStoreRegistry = FileBackedStoreRegistry<LibraryStore>()
    private let playbackStateStoreRegistry = FileBackedStoreRegistry<PlaybackStateStore>()
    private let mediaRatingStoreRegistry = FileBackedStoreRegistry<MediaRatingStore>()
    private let recommendationHistoryStoreRegistry =
        FileBackedStoreRegistry<RecommendationHistoryStore>()
    private let recentSearchStore = RecentSearchStore()
    private var recommendationImpressions: [RecommendationImpression] = []
    private var recommendationPager = LocalRecommendationPager()
    private var recommendationCandidates: [MetaItem] = []
    private var profileActivationRevision = 0
    private var latestPublishedProfileCommitGeneration = 0
    private let profileMutationGate = AsyncSerialGate()
    private let accountClient: StremioAccountClient
    private let addonSyncCoordinator: StremioAddonSyncCoordinator
    private let sessionStore = SessionStore()
    private let addonURLStore = AddonURLStore()
    private var addonURLStoreReady = false
    private var sessionStorageWarning: String?
    private var addonStorageWarning: String?
    private var profileStorageWarning: String?
    private var session: StremioSession?
    private var syncedAddonDescriptors: [SyncedAddon] = []
    private var addonMutationRevision = 0
    private let addonMutationGate = AsyncSerialGate()
    private var addonManifestCache: [URL: AddonManifest] = [:]
    private var activeCatalogEndpoint: AddonEndpoint?
    private var activeCatalogDescriptor: AddonCatalog?
    private let libraryMutationCoordinator = LibraryMutationCoordinator()
    private let accountSyncGate = AsyncSerialGate()
    private var catalogPaging = CatalogPageAccumulator()
    private var catalogResponseCache = BoundedCache<String, [MetaItem]>(
        capacity: 16,
        timeToLive: 5 * 60
    )
    private var detailResponseCache = BoundedCache<DetailRequestKey, MetaItem>(
        capacity: 96,
        timeToLive: 15 * 60
    )
    private let catalogRequestGate = InFlightRequestGate<String, [MetaItem]>()
    private let detailRequestGate = InFlightRequestGate<DetailRequestKey, MetaItem>()
    private var currentSearch: String?
    private var catalogLoadRevision = 0
    private var searchRevision = 0
    // Checkpoints are persisted while video is playing, but they deliberately
    // stay outside the published SwiftUI graph. Publishing every checkpoint
    // used to rebuild and re-sort the hidden details screen during playback.
    private var currentPlaybackProgress: [String: PlaybackProgress] = [:]
    private var currentCompletedPlaybackIdentifiers = Set<String>()
    private var playbackProgressUpdateDates: [String: Date] = [:]
    private var started = false

    var selectedCatalogSource: CatalogSource? {
        catalogSources.first { $0.id == selectedCatalogSourceID }
    }

    var activeViewingProfileID: UUID? {
        viewingProfileSnapshot?.activeProfileID
    }

    var activeViewingProfile: ViewingProfile? {
        viewingProfileSnapshot?.activeProfile
    }

    var continueWatching: [ContinueWatchingEntry] {
        var knownItemsByIdentifier: [String: MetaItem] = [:]
        let knownItems = homeShelves.flatMap(\.items)
            + catalog
            + library
            + searchCatalogs.flatMap(\.items)
        for item in knownItems {
            knownItemsByIdentifier["\(item.type):\(item.id)"] = item
        }

        return ContinueWatchingSelector.latest(
            from: Array(playbackProgress.values)
        ).map { progress in
            continueWatchingEntry(
                for: progress,
                knownItemsByIdentifier: knownItemsByIdentifier
            )
        }
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
                preferredType: "movie",
                preferredCatalogID: environment["SKELETON_CINEMETA_CATALOG_ID"] ?? "top"
            ),
            CatalogSource(
                id: "letterboxd",
                title: "Letterboxd Recommendations",
                subtitle: "Popular this week via Stremboxd",
                manifestURL: letterboxdEndpoint.manifestURL,
                preferredType: "movie",
                preferredCatalogID: environment["SKELETON_LETTERBOXD_CATALOG_ID"]
                    ?? "letterboxd-popular"
            ),
            CatalogSource(
                id: "cinemeta-series",
                title: "TV Series",
                subtitle: "Popular series",
                manifestURL: primaryEndpoint.manifestURL,
                preferredType: "series",
                preferredCatalogID: environment["SKELETON_CINEMETA_SERIES_CATALOG_ID"] ?? "top"
            ),
        ]
        catalogSources = configuredCatalogSources
        let restoredSource = UserDefaults.standard.string(forKey: "selectedCatalogSource")
        selectedCatalogSourceID = restoredSource.flatMap { restored in
            configuredCatalogSources.contains { $0.id == restored } ? restored : nil
        } ?? "cinemeta"

        let apiURL = URL(string: environment["SKELETON_API_URL"] ?? "https://api.strem.io")!
        let configuredAccountClient = try! StremioAccountClient(endpoint: apiURL)
        accountClient = configuredAccountClient
        addonSyncCoordinator = StremioAddonSyncCoordinator(client: configuredAccountClient)
        streamingServerInput = environment["SKELETON_STREAMING_SERVER_URL"]
            ?? UserDefaults.standard.string(forKey: "streamingServerURL")
            ?? "http://127.0.0.1:11470"

        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let restoredSession: StremioSession?
        var sessionRestoreError: Error?
        do {
            restoredSession = try SessionStore().load()
        } catch {
            restoredSession = nil
            sessionRestoreError = error
        }
        libraryDirectory = support
        viewingProfileStore = ViewingProfileStore(rootDirectory: support)
        libraryStore = LibraryStore(
            fileURL: support.appendingPathComponent(
                ViewingProfileDataFile.anonymousLibrary
            )
        )
        playbackStateStore = PlaybackStateStore(
            fileURL: support.appendingPathComponent(ViewingProfileDataFile.playbackState),
            legacyProgressFileURL: support.appendingPathComponent(
                ViewingProfileDataFile.playbackProgress
            ),
            legacyCompletionFileURL: support.appendingPathComponent(
                ViewingProfileDataFile.playbackCompletions
            )
        )
        mediaRatingStore = MediaRatingStore(
            fileURL: support.appendingPathComponent(ViewingProfileDataFile.mediaRatings)
        )
        recommendationHistoryStore = RecommendationHistoryStore(
            fileURL: support.appendingPathComponent(
                ViewingProfileDataFile.recommendationHistory
            )
        )
        session = restoredSession
        accountEmail = session?.user.email
        if let sessionRestoreError {
            accountSyncStatus = "Session storage unavailable"
            sessionStorageWarning =
                "Bunny could not read the saved session. Its existing data was left unchanged."
            errorMessage = sessionStorageWarning
            NSLog(
                "SESSION_STORE load_failed code=%ld",
                (sessionRestoreError as NSError).code
            )
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        defer {
            // Catalog loading clears transient errors. Restore storage warnings
            // after startup so an operational read failure cannot disappear
            // before SwiftUI has had a chance to present it.
            if errorMessage == nil {
                errorMessage = storageWarningMessage
            }
        }
        do {
            try await withSerializedProfileMutation {
                #if targetEnvironment(simulator)
                try await activateEphemeralSimulatorAccountIfRequested()
                #endif
                let profileSnapshot = try await bootstrapViewingProfiles()
                try await activateProfileSnapshot(profileSnapshot)
            }
            if ProcessInfo.processInfo.environment["SKELETON_E2E"] == "1" {
                await runE2E()
            } else {
                try await loadHome()
                #if os(iOS)
                if ProcessInfo.processInfo.environment[
                    "SKELETON_SINGLE_MOVIE_PLAYBACK_AUDIT"
                ] == "1" {
                    await runSingleMoviePlaybackAudit()
                    return
                }
                await refreshStreamingServerStatus()
                if session != nil {
                    // The local app remains usable when Stremio account sync is
                    // temporarily unavailable. `syncAccount` publishes its own
                    // failure state without turning startup into a fatal error.
                    try? await syncAccount()
                }
                if ProcessInfo.processInfo.environment["SKELETON_OBSESSION_STREAM_STRESS"] == "1" {
                    let stressEnvironment = ProcessInfo.processInfo.environment
                    await runObsessionStreamStressBenchmark(
                        requestedStreams: Int(stressEnvironment["SKELETON_OBSESSION_STREAM_COUNT"] ?? "") ?? 20,
                        startIndex: Int(stressEnvironment["SKELETON_OBSESSION_STREAM_START"] ?? "") ?? 0
                    )
                } else if ProcessInfo.processInfo.environment["SKELETON_REAL_PLAYER_STRESS"] == "1" {
                    await runRealPlayerStressBenchmark()
                }
                #else
                await refreshStreamingServerStatus()
                if session != nil {
                    try? await syncAccount()
                }
                #endif
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func bootstrapViewingProfiles() async throws -> ViewingProfileSnapshot {
        try FileManager.default.createDirectory(
            at: libraryDirectory,
            withIntermediateDirectories: true
        )
        let directoryContents = try FileManager.default.contentsOfDirectory(
            at: libraryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let legacyNames = Set([
            ViewingProfileDataFile.anonymousLibrary,
            ViewingProfileDataFile.playbackProgress,
            ViewingProfileDataFile.playbackCompletions,
            ViewingProfileDataFile.mediaRatings,
            ViewingProfileDataFile.recommendationHistory,
        ])
        let restoredAccountLibraryName = session.map {
            Self.legacyAccountLibraryFileName(for: $0)
        }
        let legacyFiles = directoryContents
            .filter { url in
                let name = url.lastPathComponent
                return legacyNames.contains(name)
                    || name == restoredAccountLibraryName
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map {
                ViewingProfileLegacyFile(
                    fileName: $0.lastPathComponent,
                    sourceURL: $0
                )
            }
        let snapshot = try await viewingProfileStore.bootstrap(
            migrating: legacyFiles
        )
        if let session {
            try await migrateLegacyAccountLibraryIfNeeded(
                for: session,
                in: snapshot
            )
        }
        try migrateLegacyAddonURLsIfNeeded(
            profileID: snapshot.activeProfileID,
            session: session
        )
        migrateLegacyRecentSearchesIfNeeded(to: snapshot.primaryProfileID)
        return snapshot
    }

    /// Copies only the exact signed-in account's legacy file into the primary
    /// profile. This is intentionally idempotent and also runs on sign-in, so
    /// launching signed out cannot permanently skip a later account import.
    /// The source stays untouched as a recoverable backup.
    private func migrateLegacyAccountLibraryIfNeeded(
        for session: StremioSession,
        in snapshot: ViewingProfileSnapshot
    ) async throws {
        let accountFileName = Self.legacyAccountLibraryFileName(for: session)
        let directory = try await viewingProfileStore.dataDirectoryURL(
            for: snapshot.primaryProfileID
        )
        let sourceURL = libraryDirectory.appendingPathComponent(accountFileName)
        let profileLegacyURL = directory.appendingPathComponent(accountFileName)
        let destinationURL = directory.appendingPathComponent(
            AccountStorageScope.libraryFileName(for: session)
        )
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            return
        }
        let migrationSource: URL
        if FileManager.default.fileExists(atPath: profileLegacyURL.path) {
            migrationSource = profileLegacyURL
        } else if FileManager.default.fileExists(atPath: sourceURL.path) {
            migrationSource = sourceURL
        } else {
            return
        }

        let temporaryURL = directory.appendingPathComponent(
            ".\(accountFileName).\(UUID().uuidString).migrating"
        )
        do {
            try FileManager.default.copyItem(at: migrationSource, to: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func legacyAccountLibraryFileName(
        for session: StremioSession
    ) -> String {
        let identity = session.user.id ?? session.user.email ?? "signed-in"
        let encoded = Data(identity.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "library-account-\(encoded).json"
    }

    /// Loads every profile-owned store before publishing any of it. SwiftUI
    /// therefore observes one coherent profile rather than a mixture of the
    /// old library and the new profile's progress or ratings.
    private func prepareProfileActivation(
        _ snapshot: ViewingProfileSnapshot,
        profileDirectory suppliedProfileDirectory: URL? = nil,
        session profileSession: StremioSession?
    ) async throws -> PreparedProfileActivation? {
        profileActivationRevision += 1
        let revision = profileActivationRevision
        let profileID = snapshot.activeProfileID
        let profileDirectory: URL
        if let suppliedProfileDirectory {
            profileDirectory = suppliedProfileDirectory
        } else {
            profileDirectory = try await viewingProfileStore.dataDirectoryURL(
                for: profileID
            )
        }
        let libraryFileName: String
        if snapshot.activeProfileAllowsAccountLibrarySync, let profileSession {
            libraryFileName = AccountStorageScope.libraryFileName(
                for: profileSession
            )
        } else {
            libraryFileName = ViewingProfileDataFile.anonymousLibrary
        }
        let libraryFileURL = profileDirectory.appendingPathComponent(libraryFileName)
        let playbackStateFileURL = profileDirectory.appendingPathComponent(
            ViewingProfileDataFile.playbackState
        )
        let ratingFileURL = profileDirectory.appendingPathComponent(
            ViewingProfileDataFile.mediaRatings
        )
        let recommendationHistoryFileURL = profileDirectory.appendingPathComponent(
            ViewingProfileDataFile.recommendationHistory
        )
        // A delayed write may still hold the previously active store. Reuse
        // that actor whenever activation resolves to the same file so there is
        // never a second stale cache owner capable of overwriting it.
        let nextLibraryStore = libraryStoreRegistry.store(for: libraryFileURL) {
            LibraryStore(fileURL: libraryFileURL)
        }
        let nextPlaybackStateStore = playbackStateStoreRegistry.store(
            for: playbackStateFileURL
        ) {
            PlaybackStateStore(
                fileURL: playbackStateFileURL,
                legacyProgressFileURL: profileDirectory.appendingPathComponent(
                    ViewingProfileDataFile.playbackProgress
                ),
                legacyCompletionFileURL: profileDirectory.appendingPathComponent(
                    ViewingProfileDataFile.playbackCompletions
                )
            )
        }
        let nextRatingStore = mediaRatingStoreRegistry.store(for: ratingFileURL) {
            MediaRatingStore(fileURL: ratingFileURL)
        }
        let nextRecommendationStore = recommendationHistoryStoreRegistry.store(
            for: recommendationHistoryFileURL
        ) {
            RecommendationHistoryStore(fileURL: recommendationHistoryFileURL)
        }

        let loadedLibrary = try await loadProfileValue(
            label: "library"
        ) { try await nextLibraryStore.items() }
        let loadedPlaybackState = try await loadProfileValue(
            label: "playback-state"
        ) { try await nextPlaybackStateStore.snapshot() }
        let loadedRatings = try await loadProfileValue(
            label: "media-ratings"
        ) { try await nextRatingStore.items() }
        let loadedRecommendationHistory = try await loadProfileValue(
            label: "recommendation-history"
        ) { try await nextRecommendationStore.items() }
        let loadedAddonURLs = try loadAddonURLs(
            profileID: profileID,
            session: profileSession
        )
        guard revision == profileActivationRevision else { return nil }

        let previousWarning = storageWarningMessage
        profileStorageWarning = nil
        if errorMessage == previousWarning {
            errorMessage = storageWarningMessage
        }

        return PreparedProfileActivation(
            revision: revision,
            snapshot: snapshot,
            libraryStore: nextLibraryStore,
            playbackStateStore: nextPlaybackStateStore,
            mediaRatingStore: nextRatingStore,
            recommendationHistoryStore: nextRecommendationStore,
            library: loadedLibrary,
            playbackState: loadedPlaybackState,
            mediaRatings: loadedRatings,
            recommendationImpressions: loadedRecommendationHistory,
            installedAddons: loadedAddonURLs
        )
    }

    private func publishProfileActivation(
        _ prepared: PreparedProfileActivation,
        committedManifest: Bool = false
    ) {
        // A committed manifest must always get a matching in-memory snapshot.
        // A newer mutation may publish again afterward, but skipping this one
        // would leave disk and UI divergent if the newer attempt failed.
        guard committedManifest || prepared.revision == profileActivationRevision else {
            return
        }
        invalidateProfileDependentCatalogPublication()
        let snapshot = prepared.snapshot
        let profileID = snapshot.activeProfileID

        libraryStore = prepared.libraryStore
        playbackStateStore = prepared.playbackStateStore
        mediaRatingStore = prepared.mediaRatingStore
        recommendationHistoryStore = prepared.recommendationHistoryStore

        library = prepared.library
        currentPlaybackProgress = Dictionary(
            uniqueKeysWithValues: prepared.playbackState.progress.map {
                ($0.contentIdentifier, $0)
            }
        )
        playbackProgress = currentPlaybackProgress
        currentCompletedPlaybackIdentifiers = Set(
            prepared.playbackState.completions.map(\.contentIdentifier)
        )
        completedPlaybackIdentifiers = currentCompletedPlaybackIdentifiers
        playbackProgressUpdateDates = Dictionary(
            uniqueKeysWithValues: prepared.playbackState.progress.map {
                ($0.contentIdentifier, $0.updatedAt)
            }
        )
        mediaRatings = Dictionary(
            uniqueKeysWithValues: prepared.mediaRatings.map { ($0.id, $0.reaction) }
        )
        recommendationImpressions = prepared.recommendationImpressions
        installedAddons = prepared.installedAddons
        syncedAddonDescriptors = []
        let activeAddonSet = Set(prepared.installedAddons)
        addonManifestCache = addonManifestCache.filter {
            activeAddonSet.contains($0.key)
        }
        recentSearches = recentSearchStore.queries(
            profileID: profileID.uuidString
        )
        viewingProfileSnapshot = snapshot

        if session != nil, !snapshot.activeProfileAllowsAccountLibrarySync {
            accountSyncStatus = "Local profile · Add-ons still sync"
        }
    }

    /// Changes in profile, account scope, and installed add-ons invalidate
    /// every catalog publication that captured the previous profile. Clear the
    /// visible paging/search state in the same synchronous MainActor turn,
    /// before exposing the new profile snapshot, so an overtaken request can
    /// neither republish old shelves nor leave them visible when replacement
    /// loading fails.
    private func invalidateProfileDependentCatalogPublication() {
        catalogLoadRevision += 1
        isLoading = false
        isLoadingNextPage = false
        currentSearch = nil
        catalogPaging.reset()
        catalogPaging.append([], supportsSkip: false)
        activeCatalogEndpoint = nil
        activeCatalogDescriptor = nil
        manifest = nil
        catalog = []
        homeShelves = []
        clearSearch()
        clearRecommendationPagination()
    }

    private func activateProfileSnapshot(
        _ snapshot: ViewingProfileSnapshot
    ) async throws {
        guard let prepared = try await prepareProfileActivation(
            snapshot,
            session: session
        ) else { return }
        publishProfileActivation(prepared)
    }

    private func loadProfileValue<Value: Sendable>(
        label: String,
        operation: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await operation()
        } catch {
            NSLog(
                "VIEWING_PROFILE load_failed store=%@ error=%@",
                label,
                error.localizedDescription
            )
            profileStorageWarning =
                "Bunny could not read saved \(label) data. Its existing file was left unchanged."
            errorMessage = storageWarningMessage
            throw error
        }
    }

    private func commitPreparedProfileMutation(
        _ plan: ViewingProfileMutationPlan
    ) async throws -> Bool {
        do {
            guard let prepared = try await prepareProfileActivation(
                plan.snapshot,
                profileDirectory: plan.activeProfileDataDirectoryURL,
                session: session
            ) else {
                await viewingProfileStore.cancel(plan)
                return false
            }
            guard prepared.revision == profileActivationRevision else {
                await viewingProfileStore.cancel(plan)
                return false
            }
            let committed = try await viewingProfileStore.commit(plan)
            guard committed.snapshot == prepared.snapshot else {
                throw ViewingProfileStoreError.staleMutationPlan
            }
            guard committed.generation >= latestPublishedProfileCommitGeneration else {
                return true
            }
            latestPublishedProfileCommitGeneration = committed.generation
            publishProfileActivation(prepared, committedManifest: true)
            return true
        } catch {
            await viewingProfileStore.cancel(plan)
            throw error
        }
    }

    private func withSerializedProfileMutation<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        await profileMutationGate.enter()
        do {
            let value = try await operation()
            await profileMutationGate.leave()
            return value
        } catch {
            await profileMutationGate.leave()
            throw error
        }
    }

    func createViewingProfile(
        name: String,
        avatar: ViewingProfileAvatar
    ) async throws {
        let committed = try await withSerializedProfileMutation {
            let plan = try await viewingProfileStore.prepareCreateAndActivate(
                name: name,
                avatar: avatar
            )
            return try await commitPreparedProfileMutation(plan)
        }
        guard committed else { return }
        await reloadHomeAfterProfileMutation()
    }

    func updateViewingProfile(
        id: UUID,
        name: String,
        avatar: ViewingProfileAvatar
    ) async throws {
        let shouldReload = try await withSerializedProfileMutation {
            let committed = try await viewingProfileStore.updateWithCommit(
                id: id,
                name: name,
                avatar: avatar
            )
            guard publishProfileMetadataCommit(committed) else { return false }
            return id == activeViewingProfileID
        }
        if shouldReload {
            await reloadHomeAfterProfileMutation()
        }
    }

    func selectViewingProfile(id: UUID) async throws {
        let committed = try await withSerializedProfileMutation {
            guard id != activeViewingProfileID else { return false }
            let plan = try await viewingProfileStore.prepareActivation(id: id)
            return try await commitPreparedProfileMutation(plan)
        }
        guard committed else { return }
        // Profile activation is a local transaction. Publish it immediately;
        // a network outage must not leave the picker open as though selection
        // failed after the active profile has already changed.
        await reloadHomeAfterProfileMutation()
        if session != nil {
            try? await syncAccount()
        }
    }

    func activateViewingProfile(id: UUID) async throws {
        try await selectViewingProfile(id: id)
    }

    func archiveViewingProfile(id: UUID) async throws {
        let result = try await withSerializedProfileMutation { () -> (
            committed: Bool,
            changedActiveProfile: Bool
        ) in
            let previousActiveID = activeViewingProfileID
            let plan = try await viewingProfileStore.prepareArchive(id: id)
            if plan.snapshot.activeProfileID != previousActiveID {
                return (
                    try await commitPreparedProfileMutation(plan),
                    true
                )
            }
            let committed = try await viewingProfileStore.commit(plan)
            guard committed.generation >= latestPublishedProfileCommitGeneration else {
                return (true, false)
            }
            latestPublishedProfileCommitGeneration = committed.generation
            viewingProfileSnapshot = committed.snapshot
            return (true, false)
        }
        guard result.committed else { return }
        if result.changedActiveProfile {
            await reloadHomeAfterProfileMutation()
            if session != nil {
                try? await syncAccount()
            }
        }
    }

    func restoreViewingProfile(id: UUID) async throws {
        try await withSerializedProfileMutation {
            let committed = try await viewingProfileStore.restoreWithCommit(id: id)
            _ = publishProfileMetadataCommit(committed)
        }
    }

    @discardableResult
    private func publishProfileMetadataCommit(
        _ committed: ViewingProfileMutationCommit
    ) -> Bool {
        guard committed.generation >= latestPublishedProfileCommitGeneration else {
            return false
        }
        latestPublishedProfileCommitGeneration = committed.generation
        viewingProfileSnapshot = committed.snapshot
        return true
    }

    func mediaReaction(for item: MetaItem) -> MediaReaction? {
        mediaRatings[LocalMediaIdentity(item: item)]
    }

    func reaction(for item: MetaItem) -> MediaReaction? {
        mediaReaction(for: item)
    }

    func setMediaReaction(
        _ reaction: MediaReaction?,
        for item: MetaItem
    ) async throws {
        guard let profileID = activeViewingProfileID else { return }
        let activeStore = mediaRatingStore
        let ratings = try await activeStore.set(reaction, for: item)
        guard activeStore === mediaRatingStore,
              profileID == activeViewingProfileID
        else { return }
        mediaRatings = Dictionary(
            uniqueKeysWithValues: ratings.map { ($0.id, $0.reaction) }
        )
        await reloadHomeAfterProfileMutation()
    }

    func setReaction(
        _ reaction: MediaReaction?,
        for item: MetaItem
    ) async throws {
        try await setMediaReaction(reaction, for: item)
    }

    func resetViewingProfilePersonalization() async throws {
        guard let profileID = activeViewingProfileID else { return }
        let ratingsStore = mediaRatingStore
        let historyStore = recommendationHistoryStore
        async let resetRatings = ratingsStore.reset()
        async let resetHistory = historyStore.reset()
        _ = try await (resetRatings, resetHistory)
        guard ratingsStore === mediaRatingStore,
              historyStore === recommendationHistoryStore,
              profileID == activeViewingProfileID
        else { return }
        mediaRatings = [:]
        recommendationImpressions = []
        clearRecommendationPagination()
        await reloadHomeAfterProfileMutation()
    }

    func recordRecentSearch(_ query: String) {
        guard let profileID = activeViewingProfileID else { return }
        let namespace = profileID.uuidString
        recentSearchStore.record(query, profileID: namespace)
        recentSearches = recentSearchStore.queries(profileID: namespace)
    }

    func clearRecentSearches() {
        guard let profileID = activeViewingProfileID else { return }
        recentSearchStore.clear(profileID: profileID.uuidString)
        recentSearches = []
    }

    func recordRecommendationImpression(for item: MetaItem) async {
        guard let profileID = activeViewingProfileID else { return }
        let identity = LocalMediaIdentity(item: item)
        guard let recommendation = localRecommendations.first(where: {
            $0.id == identity
        }) else { return }

        let historyStore = recommendationHistoryStore
        guard let updated = try? await historyStore.record([recommendation]),
              historyStore === recommendationHistoryStore,
              profileID == activeViewingProfileID,
              localRecommendations.contains(where: { $0.id == identity })
        else { return }
        recommendationImpressions = updated
    }

    private func migrateLegacyRecentSearchesIfNeeded(to profileID: UUID) {
        let defaults = UserDefaults.standard
        let migrationKey = "viewingProfiles.recentSearchMigration.v1"
        guard !defaults.bool(forKey: migrationKey) else { return }
        let legacy = recentSearchStore.queries(profileID: "default")
        if recentSearchStore.queries(profileID: profileID.uuidString).isEmpty {
            for query in legacy.reversed() {
                recentSearchStore.record(query, profileID: profileID.uuidString)
            }
        }
        defaults.set(true, forKey: migrationKey)
    }

    private func reloadHomeAfterProfileMutation() async {
        guard started,
              ProcessInfo.processInfo.environment["SKELETON_E2E"] != "1"
        else { return }
        do {
            try await loadHome()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    #if targetEnvironment(simulator)
    /// Deterministic, network-free recommendation shelf used by the pagination
    /// UI test. It exercises the same pager and Home shelf that production uses.
    func prepareRecommendationPaginationFixture(totalCount: Int = 36) {
        let recommendations = (0..<max(totalCount, 0)).map { index in
            let number = index + 1
            let item = MetaItem(
                id: "recommendation-fixture-\(number)",
                type: index.isMultiple(of: 3) ? "series" : "movie",
                name: "Recommendation \(number)",
                description: "A deterministic personalized pick for infinite-scroll verification.",
                releaseInfo: "2026",
                genres: [index.isMultiple(of: 2) ? "Drama" : "Adventure"]
            )
            return LocalRecommendation(
                item: item,
                score: Double(totalCount - index),
                reasons: ["Because you enjoyed Fixture Story"]
            )
        }
        catalogPaging.reset()
        catalogPaging.append([], supportsSkip: false)
        recommendationCandidates = recommendations.map(\.item)
        recommendationPager.reset(with: recommendations)
        publishRecommendationPage(syncShelf: false)
        homeShelves = [
            DiscoveryShelf(
                id: "for-you",
                title: "For You",
                subtitle: "Because you enjoyed Fixture Story",
                items: localRecommendations.map(\.item)
            ),
        ]
        isLoading = false
        errorMessage = nil
    }

    /// Network-free Home fixture for distinguishing Continue Watching's tap
    /// and long-press navigation in the UI test target.
    func prepareContinueWatchingNavigationFixture() {
        let episode = Video(
            id: "tt-continue-series:1:2",
            title: "The Return",
            season: 1,
            episode: 2
        )
        let series = MetaItem(
            id: "tt-continue-series",
            type: "series",
            name: "Continue Series",
            description: "A deterministic Continue Watching series fixture.",
            releaseInfo: "2026–",
            videos: [episode]
        )
        let movie = MetaItem(
            id: "tt-continue-movie",
            type: "movie",
            name: "Continue Movie",
            description: "A deterministic Continue Watching movie fixture.",
            releaseInfo: "2026"
        )
        let stream = Stream(
            url: URL(string: "https://example.invalid/continue-watching.mkv"),
            externalUrl: nil,
            name: "Continue Watching fixture",
            title: "1080p · Fixture",
            description: nil,
            infoHash: nil,
            fileIdx: nil,
            sources: nil
        )
        let seriesIdentifier = EpisodePlaybackIdentity.contentIdentifier(
            seriesID: series.id,
            videoID: episode.id
        )
        let seriesProgress = PlaybackProgress(
            contentIdentifier: seriesIdentifier,
            contentTitle: EpisodePlaybackIdentity.contentTitle(
                seriesTitle: series.name,
                video: episode
            ),
            stream: stream,
            providerName: "Fixture",
            position: 1_200,
            duration: 3_600,
            updatedAt: Date(timeIntervalSince1970: 2),
            mediaMetadata: .episode(series: series, episode: episode)
        )
        let movieProgress = PlaybackProgress(
            contentIdentifier: "movie:\(movie.id)",
            contentTitle: movie.name,
            stream: stream,
            providerName: "Fixture",
            position: 900,
            duration: 5_400,
            updatedAt: Date(timeIntervalSince1970: 1),
            mediaMetadata: .movie(movie)
        )

        catalog = [series, movie]
        homeShelves = [
            DiscoveryShelf(
                id: "continue-watching-fixture",
                title: "Fixture Titles",
                items: [series, movie]
            ),
        ]
        playbackProgress = [
            seriesProgress.contentIdentifier: seriesProgress,
            movieProgress.contentIdentifier: movieProgress,
        ]
        currentPlaybackProgress = playbackProgress
        isLoading = false
        errorMessage = nil
    }

    /// Reproduces details-page pressure from a long infinite-scroll session
    /// without depending on a live catalog or provider.
    func prepareDetailsPerformanceFixture(candidateCount: Int = 5_000) {
        if let identity = PlaybackContentIdentity.movie(catalogID: "tt-heavy-details"),
           let key = PlaybackStreamPreferenceKey(
               providerName: "Cinemeta",
               streamName: "Fixture 1080p 999",
               streamTitle: "1080p WEB-DL 10 GB"
           ) {
            // Exercise the expensive preference-ranking branch every time;
            // this is the path that made the lag intermittent in production.
            LastSuccessfulPlaybackPreferenceStore.shared.recordSuccess(
                identity: identity,
                key: key
            )
        }
        let candidates = (0..<max(candidateCount, 0)).map { index in
            MetaItem(
                id: "details-performance-candidate-\(index)",
                type: "movie",
                name: "Related Performance Candidate \(index + 1)",
                description: "Deterministic details-page performance fixture.",
                releaseInfo: "2026",
                genres: index.isMultiple(of: 2)
                    ? ["Animation", "Comedy"] : ["Drama"],
                cast: index.isMultiple(of: 5) ? ["Fixture Performer"] : nil
            )
        }
        catalog = candidates
        homeShelves = [
            DiscoveryShelf(
                id: "details-performance",
                title: "Details Performance",
                items: candidates
            ),
        ]
        searchCatalogs = []
        isLoading = false
        errorMessage = nil
    }

    /// Allows real-account provider audits without writing the supplied password or
    /// resulting session to disk. The session exists only for this simulator process.
    private func activateEphemeralSimulatorAccountIfRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let email = environment["SKELETON_SIMULATOR_ACCOUNT_EMAIL"],
              let password = environment["SKELETON_SIMULATOR_ACCOUNT_PASSWORD"],
              !email.isEmpty,
              !password.isEmpty
        else { return }

        let signedIn = try await accountClient.login(email: email, password: password)
        session = signedIn
        accountEmail = signedIn.user.email ?? email
        NSLog("SIMULATOR_ACCOUNT_AUDIT authenticated ephemeral=1")
    }
    #endif

    func selectCatalogSource(_ source: CatalogSource) async throws {
        guard source.id != selectedCatalogSourceID else { return }
        selectedCatalogSourceID = source.id
        UserDefaults.standard.set(source.id, forKey: "selectedCatalogSource")
        try await loadHome()
    }

    func loadHome(search: String? = nil) async throws {
        catalogLoadRevision += 1
        let revision = catalogLoadRevision
        let traceID = PerformanceMilestoneRecorder.shared.begin(
            flow: .catalog,
            identity: selectedCatalogSourceID
        )
        isLoading = true
        isLoadingNextPage = false
        errorMessage = storageWarningMessage
        currentSearch = search?.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentSearch?.isEmpty == true { currentSearch = nil }
        defer {
            if revision == catalogLoadRevision { isLoading = false }
        }

        guard let source = selectedCatalogSource else {
            throw E2EFailure("No selected catalog source")
        }
        let selectedResult: CatalogLoadResult
        do {
            selectedResult = try await loadCatalogResult(
                for: source,
                search: currentSearch
            )
        } catch {
            // Profile publication invalidates this load before replacing its
            // catalog state. A late transport/decode failure owned by the old
            // profile must not escape to a caller and overwrite the new
            // profile's error presentation.
            guard revision == catalogLoadRevision, !Task.isCancelled else {
                return
            }
            throw error
        }
        guard revision == catalogLoadRevision, !Task.isCancelled else { return }

        catalogPaging.reset()
        catalogPaging.append(
            selectedResult.items,
            supportsSkip: selectedResult.descriptor.supportsSkip
        )
        activeCatalogEndpoint = selectedResult.endpoint
        activeCatalogDescriptor = selectedResult.descriptor
        manifest = selectedResult.manifest
        catalog = catalogPaging.items

        let companionSources = catalogSources.filter { candidate in
            candidate.id != source.id
                && (candidate.id == "cinemeta" || candidate.id == "cinemeta-series")
        }
        let companionResults = await loadCompanionCatalogs(companionSources)
        guard revision == catalogLoadRevision, !Task.isCancelled else { return }
        await rebuildHomeShelves(
            selected: selectedResult,
            companions: companionResults,
            revision: revision
        )
        guard revision == catalogLoadRevision, !Task.isCancelled else { return }
        let elapsed = PerformanceMilestoneRecorder.shared.mark(.catalogReady, for: traceID)
        NSLog(
            "CATALOG_BENCHMARK ready_ms=%.1f selected_cache=%@ shelves=%ld",
            elapsed ?? 0,
            selectedResult.cacheHit ? "hit" : "miss",
            homeShelves.count
        )
    }

    private func loadCatalogResult(
        for source: CatalogSource,
        search: String?
    ) async throws -> CatalogLoadResult {
        let endpoint = try AddonEndpoint(manifestURL: source.manifestURL)
        let loadedManifest: AddonManifest
        if let cached = addonManifestCache[source.manifestURL] {
            loadedManifest = cached
        } else {
            loadedManifest = try await Self.withAddonTimeout {
                try await AddonClient(endpoint: endpoint).manifest()
            }
            addonManifestCache[source.manifestURL] = loadedManifest
        }
        guard let descriptor = catalogDescriptor(
            in: loadedManifest,
            source: source,
            search: search
        ) else {
            throw E2EFailure("No compatible catalog in \(loadedManifest.name)")
        }

        let cacheKey = [
            source.manifestURL.absoluteString,
            descriptor.type,
            descriptor.id,
            search ?? "",
        ].joined(separator: "|")
        if let cached = catalogResponseCache.value(forKey: cacheKey) {
            return CatalogLoadResult(
                source: source,
                endpoint: endpoint,
                manifest: loadedManifest,
                descriptor: descriptor,
                items: cached,
                cacheHit: true
            )
        }

        let manifestURL = source.manifestURL
        let descriptorType = descriptor.type
        let descriptorID = descriptor.id
        let loadedItems = try await catalogRequestGate.run(key: cacheKey) {
            let requestEndpoint = try AddonEndpoint(manifestURL: manifestURL)
            return try await AddonClient(endpoint: requestEndpoint).catalog(
                type: descriptorType,
                id: descriptorID,
                search: search
            )
        }
        catalogResponseCache.insert(loadedItems, forKey: cacheKey)
        return CatalogLoadResult(
            source: source,
            endpoint: endpoint,
            manifest: loadedManifest,
            descriptor: descriptor,
            items: loadedItems,
            cacheHit: false
        )
    }

    private func loadCompanionCatalogs(
        _ sources: [CatalogSource]
    ) async -> [CatalogLoadResult] {
        await withTaskGroup(of: (Int, CatalogLoadResult?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let result = try? await self.loadCatalogResult(
                        for: source,
                        search: nil
                    )
                    return (index, result)
                }
            }
            var loaded: [(Int, CatalogLoadResult)] = []
            for await (index, result) in group {
                if let result { loaded.append((index, result)) }
            }
            return loaded.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func rebuildHomeShelves(
        selected: CatalogLoadResult,
        companions: [CatalogLoadResult],
        revision: Int
    ) async {
        let candidates = selected.items + companions.flatMap(\.items) + library
        await refreshLocalRecommendations(
            candidates: candidates,
            catalogRevision: revision,
            resetPagination: true
        )
        guard revision == catalogLoadRevision, !Task.isCancelled else { return }

        var shelves: [DiscoveryShelf] = []
        if !localRecommendations.isEmpty {
            shelves.append(
                DiscoveryShelf(
                    id: "for-you",
                    title: activeViewingProfile.map { "For \($0.name)" } ?? "For You",
                    subtitle: localRecommendations.first?.reasons.first,
                    items: localRecommendations.map(\.item)
                )
            )
        }
        if !library.isEmpty {
            shelves.append(
                DiscoveryShelf(
                    id: "my-list",
                    title: "My List",
                    subtitle: "Saved by this profile",
                    items: library
                )
            )
        }
        shelves.append(
                DiscoveryShelf(
                    id: "selected-catalog",
                    title: selected.source.discoveryShelfTitle,
                    subtitle: selected.source.subtitle,
                    items: selected.items
            )
        )
        let recentItems = DiscoveryShelfBuilder.recentItems(from: candidates)
        if !recentItems.isEmpty {
            shelves.append(
                DiscoveryShelf(
                    id: "new-and-recent",
                    title: "New & Recent",
                    subtitle: "Recent and upcoming",
                    items: recentItems
                )
            )
        }
        shelves.append(contentsOf: companions.map { result in
            DiscoveryShelf(
                id: "source:\(result.source.id)",
                title: result.source.preferredType == "series"
                    ? "Popular Series"
                    : "Popular Movies",
                subtitle: result.source.subtitle,
                items: result.items
            )
        })

        shelves.append(
            contentsOf: DiscoveryShelfBuilder.genreShelves(
                from: candidates,
                excluding: []
            )
        )
        // A title may legitimately appear in Popular, My List, Recent, and a
        // genre row. Dedupe only within each row so one discovery path does not
        // erase another.
        guard revision == catalogLoadRevision, !Task.isCancelled else { return }
        homeShelves = DiscoveryShelfBuilder.deduplicated(shelves, globally: false)
    }

    private func refreshLocalRecommendations(
        candidates: [MetaItem],
        catalogRevision: Int,
        resetPagination: Bool
    ) async {
        guard let profileID = activeViewingProfileID else {
            clearRecommendationPagination()
            return
        }
        let uniqueCandidates = Self.uniqueMediaItems(candidates)
        recommendationCandidates = uniqueCandidates
        let ratingsStore = mediaRatingStore
        let historyStore = recommendationHistoryStore
        let stateStore = playbackStateStore
        var knownItems: [LocalMediaIdentity: MetaItem] = [:]
        for item in uniqueCandidates + library {
            knownItems[LocalMediaIdentity(item: item)] = item
        }
        let libraryActivity = library.map {
            RecommendationActivity(item: $0, kind: .addedToLibrary)
        }
        let playbackActivity: [RecommendationActivity] = currentPlaybackProgress.values.compactMap { progress in
            guard let metadata = progress.mediaMetadata,
                  let item = knownItems[
                    LocalMediaIdentity(id: metadata.mediaID, type: metadata.mediaType)
                  ]
            else { return nil }
            return RecommendationActivity(
                item: item,
                kind: .watched,
                occurredAt: progress.updatedAt
            )
        }
        // `mediaRatings` is optimized for synchronous SwiftUI lookup; recover
        // the richer stored snapshots for recommendation signals off the main path.
        let storedRatings = (try? await ratingsStore.items()) ?? []
        let storedPlaybackState = try? await stateStore.snapshot()
        let storedCompletions = storedPlaybackState?.completions ?? []
        guard ratingsStore === mediaRatingStore,
              historyStore === recommendationHistoryStore,
              stateStore === playbackStateStore,
              catalogRevision == catalogLoadRevision,
              profileID == activeViewingProfileID
        else { return }
        let activelyWatchedIDs = Set(playbackActivity.map { $0.media.identity })
        var latestCompleted: [LocalMediaIdentity: (item: MetaItem, date: Date)] = [:]
        for completion in storedCompletions {
            guard let completedItem = recommendationItem(
                for: completion.contentIdentifier,
                knownItems: knownItems
            ) else { continue }
            let identity = LocalMediaIdentity(item: completedItem)
            guard !activelyWatchedIDs.contains(identity),
                  (latestCompleted[identity]?.date ?? .distantPast) < completion.completedAt
            else { continue }
            latestCompleted[identity] = (completedItem, completion.completedAt)
        }
        let completionActivity = latestCompleted.values.map { completed in
            RecommendationActivity(
                item: completed.item,
                kind: .completed,
                occurredAt: completed.date
            )
        }
        let activity = libraryActivity + playbackActivity + completionActivity
        guard !activity.isEmpty || !storedRatings.isEmpty else {
            clearRecommendationPagination()
            return
        }
        let refreshed = LocalRecommendationEngine.recommend(
            candidates: uniqueCandidates,
            activity: activity,
            ratings: storedRatings,
            impressions: recommendationImpressions,
            limit: .max
        )
        if resetPagination {
            recommendationPager.reset(with: refreshed)
        } else {
            recommendationPager.appendRanked(refreshed)
        }
        publishRecommendationPage(syncShelf: false)
    }

    private func clearRecommendationPagination() {
        recommendationPager.clear()
        recommendationCandidates = []
        localRecommendations = []
        isLoadingMoreRecommendations = false
        canLoadMoreRecommendations = false
    }

    private func publishRecommendationPage(syncShelf: Bool) {
        localRecommendations = recommendationPager.visibleRecommendations
        canLoadMoreRecommendations = !localRecommendations.isEmpty
            && (recommendationPager.canRevealMore || catalogPaging.canLoadMore)
        if syncShelf {
            updateRecommendationShelfIfPresent()
        }
    }

    private func updateRecommendationShelfIfPresent() {
        guard let shelfIndex = homeShelves.firstIndex(where: { $0.id == "for-you" }) else {
            return
        }
        var shelves = homeShelves
        if localRecommendations.isEmpty {
            shelves.remove(at: shelfIndex)
        } else {
            let existing = shelves[shelfIndex]
            shelves[shelfIndex] = DiscoveryShelf(
                id: existing.id,
                title: existing.title,
                subtitle: localRecommendations.first?.reasons.first ?? existing.subtitle,
                items: localRecommendations.map(\.item)
            )
        }
        homeShelves = shelves
    }

    private static func uniqueMediaItems(_ items: [MetaItem]) -> [MetaItem] {
        var seen = Set<LocalMediaIdentity>()
        return items.filter { seen.insert(LocalMediaIdentity(item: $0)).inserted }
    }

    private func recommendationItem(
        for contentIdentifier: String,
        knownItems: [LocalMediaIdentity: MetaItem]
    ) -> MetaItem? {
        if let episodeIdentity = Self.legacyEpisodeIdentity(contentIdentifier) {
            return knownItems[
                LocalMediaIdentity(id: episodeIdentity.seriesID, type: "series")
            ]
        }
        guard let separator = contentIdentifier.firstIndex(of: ":") else { return nil }
        let type = String(contentIdentifier[..<separator])
        let idStart = contentIdentifier.index(after: separator)
        let id = String(contentIdentifier[idStart...])
        return knownItems[LocalMediaIdentity(id: id, type: type)]
    }

    func searchAllCatalogs(_ input: String, mediaType: String? = nil) async {
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
        searchFailureMessage = nil
        errorMessage = storageWarningMessage
        let requestedType = mediaType ?? selectedCatalogSource?.preferredType ?? "movie"
        let localMatches = DiscoveryShelfBuilder.matchingItems(
            homeShelves.flatMap(\.items) + catalog + library,
            query: query,
            mediaType: requestedType
        )
        let localGroup = localMatches.isEmpty ? nil : SearchCatalogGroup(
            id: "local-metadata#\(requestedType)",
            providerName: Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
                as? String ?? "Bunny",
            catalogName: "Titles, People & Genres",
            manifestURL: primaryEndpoint.manifestURL,
            items: localMatches
        )

        var urls: [URL] = []
        var seenURLs = Set<URL>()
        for url in catalogSources.map(\.manifestURL) + installedAddons {
            if seenURLs.insert(url).inserted { urls.append(url) }
        }
        var knownManifests = addonManifestCache
        for descriptor in syncedAddonDescriptors {
            knownManifests[descriptor.transportUrl] = descriptor.manifest
        }

        let outcomes = await withTaskGroup(of: SearchProviderOutcome.self) { group in
            for (providerIndex, url) in urls.enumerated() {
                let knownManifest = knownManifests[url]
                group.addTask {
                    guard let endpoint = try? AddonEndpoint(manifestURL: url) else {
                        return SearchProviderOutcome(
                            index: providerIndex,
                            groups: [],
                            attemptedRequestCount: 1,
                            successfulRequestCount: 0
                        )
                    }
                    let client = AddonClient(endpoint: endpoint)
                    let manifest: AddonManifest
                    if let knownManifest {
                        manifest = knownManifest
                    } else {
                        guard let loadedManifest = try? await Self.withAddonTimeout({
                            try await client.manifest()
                        }) else {
                            return SearchProviderOutcome(
                                index: providerIndex,
                                groups: [],
                                attemptedRequestCount: 1,
                                successfulRequestCount: 0
                            )
                        }
                        manifest = loadedManifest
                    }

                    let searchable = manifest.catalogs.filter { descriptor in
                        descriptor.supportsExtra("search")
                            && descriptor.type == requestedType
                    }
                    let results = await withTaskGroup(
                        of: SearchCatalogAttempt.self
                    ) { catalogGroup in
                        for (catalogIndex, descriptor) in searchable.enumerated() {
                            catalogGroup.addTask {
                                do {
                                    let items = try await Self.withAddonTimeout {
                                        try await client.catalog(
                                            type: descriptor.type,
                                            id: descriptor.id,
                                            search: query
                                        )
                                    }
                                    guard !items.isEmpty else {
                                        return SearchCatalogAttempt(
                                            index: catalogIndex,
                                            group: nil,
                                            succeeded: true
                                        )
                                    }

                                    var seenItems = Set<String>()
                                    let uniqueItems = items.filter {
                                        seenItems.insert("\($0.type)|\($0.id)").inserted
                                    }
                                    return SearchCatalogAttempt(
                                        index: catalogIndex,
                                        group: SearchCatalogGroup(
                                            id: "\(url.absoluteString)#\(descriptor.type)#\(descriptor.id)",
                                            providerName: manifest.name,
                                            catalogName: descriptor.name ?? descriptor.id,
                                            manifestURL: url,
                                            items: uniqueItems
                                        ),
                                        succeeded: true
                                    )
                                } catch {
                                    return SearchCatalogAttempt(
                                        index: catalogIndex,
                                        group: nil,
                                        succeeded: false
                                    )
                                }
                            }
                        }
                        var attempts: [SearchCatalogAttempt] = []
                        for await attempt in catalogGroup {
                            attempts.append(attempt)
                        }
                        return attempts
                    }
                    return SearchProviderOutcome(
                        index: providerIndex,
                        groups: results.sorted { $0.index < $1.index }.compactMap(\.group),
                        attemptedRequestCount: searchable.count,
                        successfulRequestCount: results.filter(\.succeeded).count
                    )
                }
            }

            var providers: [SearchProviderOutcome] = []
            for await result in group { providers.append(result) }
            return providers.sorted { $0.index < $1.index }
        }

        guard revision == searchRevision, activeSearchQuery == query, !Task.isCancelled else {
            return
        }
        searchCatalogs = localGroup.map { [$0] } ?? []
        searchCatalogs.append(contentsOf: outcomes.flatMap(\.groups))
        let attemptedRequestCount = outcomes.reduce(0) {
            $0 + $1.attemptedRequestCount
        }
        let successfulRequestCount = outcomes.reduce(0) {
            $0 + $1.successfulRequestCount
        }
        if attemptedRequestCount > 0, successfulRequestCount == 0 {
            searchFailureMessage = "Installed add-ons did not respond to this search. Check your connection and try again."
        } else {
            searchFailureMessage = nil
        }
        isSearching = false
    }

    func clearSearch() {
        guard activeSearchQuery != nil || isSearching || !searchCatalogs.isEmpty
            || searchFailureMessage != nil else { return }
        searchRevision += 1
        activeSearchQuery = nil
        searchCatalogs = []
        searchFailureMessage = nil
        isSearching = false
    }

    func loadNextPageIfNeeded(currentItem: MetaItem) async {
        guard let index = catalog.firstIndex(where: {
            $0.id == currentItem.id && $0.type == currentItem.type
        }), index >= max(0, catalog.count - 8) else { return }

        let revision = catalogLoadRevision
        do {
            try await loadNextPage()
        } catch {
            if revision == catalogLoadRevision {
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadMoreRecommendationsIfNeeded(currentItem: MetaItem) async {
        guard let index = localRecommendations.firstIndex(where: {
            $0.item.id == currentItem.id && $0.item.type == currentItem.type
        }), index >= max(0, localRecommendations.count - 4) else { return }

        await loadMoreRecommendations()
    }

    private func loadMoreRecommendations() async {
        guard !isLoading, !isLoadingMoreRecommendations,
              canLoadMoreRecommendations
        else { return }

        let revision = catalogLoadRevision

        if recommendationPager.canRevealMore {
            recommendationPager.revealNextPage()
            publishRecommendationPage(syncShelf: true)
            return
        }

        guard !isLoadingNextPage else { return }
        guard catalogPaging.canLoadMore else {
            canLoadMoreRecommendations = false
            return
        }

        isLoadingMoreRecommendations = true
        defer {
            if revision == catalogLoadRevision {
                isLoadingMoreRecommendations = false
                canLoadMoreRecommendations = !localRecommendations.isEmpty
                    && (recommendationPager.canRevealMore || catalogPaging.canLoadMore)
            }
        }

        do {
            try await loadNextPage()
            guard revision == catalogLoadRevision, !Task.isCancelled else { return }
            if recommendationPager.canRevealMore {
                recommendationPager.revealNextPage()
            }
            publishRecommendationPage(syncShelf: true)
        } catch {
            if revision == catalogLoadRevision {
                errorMessage = error.localizedDescription
            }
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
        if let shelfIndex = homeShelves.firstIndex(where: {
            $0.id == "selected-catalog"
        }) {
            var shelves = homeShelves
            let selectedShelf = shelves[shelfIndex]
            shelves[shelfIndex] = DiscoveryShelf(
                id: selectedShelf.id,
                title: selectedShelf.title,
                subtitle: selectedShelf.subtitle,
                items: catalog
            )
            homeShelves = shelves
        }

        if !recommendationCandidates.isEmpty {
            await refreshLocalRecommendations(
                candidates: recommendationCandidates + page,
                catalogRevision: revision,
                resetPagination: false
            )
            guard revision == catalogLoadRevision, !Task.isCancelled else { return }
            updateRecommendationShelfIfPresent()
        }
        canLoadMoreRecommendations = !localRecommendations.isEmpty
            && (recommendationPager.canRevealMore || catalogPaging.canLoadMore)
    }

    func details(
        for item: MetaItem,
        preferredManifestURL: URL? = nil
    ) async -> MetaItem {
        let traceID = PerformanceMilestoneRecorder.shared.begin(
            flow: .detail,
            identity: "\(item.type):\(item.id)"
        )
        let startedAt = ProcessInfo.processInfo.systemUptime
        let identity = MediaIdentity(item)
        let candidateEndpointURLs = [
            preferredManifestURL,
            activeCatalogEndpoint?.manifestURL,
            primaryEndpoint.manifestURL,
        ].compactMap { $0 }
        var seen = Set<URL>()
        let endpointURLs = candidateEndpointURLs.filter { seen.insert($0).inserted }
        let requestKey = DetailRequestKey(
            identity: identity,
            endpointURLs: endpointURLs
        )
        if let cached = detailResponseCache.value(forKey: requestKey) {
            let elapsed = PerformanceMilestoneRecorder.shared.mark(.detailReady, for: traceID)
            NSLog(
                "DETAIL_BENCHMARK elapsed_ms=%.1f cache=hit result=remote",
                elapsed ?? 0
            )
            return cached
        }

        do {
            let enriched = try await detailRequestGate.run(key: requestKey) {
                let responses = await withTaskGroup(
                    of: (Int, MetaItem?).self
                ) { group in
                    for (index, manifestURL) in endpointURLs.enumerated() {
                        group.addTask {
                            guard let endpoint = try? AddonEndpoint(
                                manifestURL: manifestURL
                            ) else { return (index, nil) }
                            let detail = try? await AddonClient(endpoint: endpoint)
                                .meta(type: item.type, id: item.id)
                            return (index, detail)
                        }
                    }

                    var loaded: [(Int, MetaItem)] = []
                    for await (index, detail) in group {
                        if let detail { loaded.append((index, detail)) }
                    }
                    return loaded.sorted { $0.0 < $1.0 }.map(\.1)
                }
                guard var resolvedDetail = responses.first else {
                    throw E2EFailure("No metadata provider returned this title")
                }
                for fallback in responses.dropFirst() {
                    resolvedDetail = resolvedDetail.fillingTrailerMetadata(from: fallback)
                }
                return resolvedDetail.fillingTrailerMetadata(from: item)
            }
            detailResponseCache.insert(enriched, forKey: requestKey)
            let elapsed = PerformanceMilestoneRecorder.shared.mark(.detailReady, for: traceID)
            NSLog(
                "DETAIL_BENCHMARK elapsed_ms=%.1f wall_ms=%.1f endpoints=%ld cache=miss result=remote",
                elapsed ?? 0,
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                endpointURLs.count
            )
            return enriched
        } catch {
            let elapsed = PerformanceMilestoneRecorder.shared.mark(.detailReady, for: traceID)
            NSLog(
                "DETAIL_BENCHMARK elapsed_ms=%.1f wall_ms=%.1f endpoints=%ld cache=miss result=seed",
                elapsed ?? 0,
                (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000,
                endpointURLs.count
            )
            return item
        }
    }

    func streamProviders(
        for item: MetaItem,
        videoID: String? = nil,
        onUpdate: (([StreamProviderGroup]) -> Void)? = nil
    ) async -> [StreamProviderGroup] {
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
                if let provider {
                    results.append((index, provider))
                    onUpdate?(results.sorted { $0.0 < $1.0 }.map(\.1))
                }
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
            let activeStore = libraryStore
            let activeProfileID = activeViewingProfileID
            let syncSession = session
            let activeAuthKey = syncSession?.authKey
            let canSyncAccountLibrary = viewingProfileSnapshot?
                .activeProfileAllowsAccountLibrarySync == true
            let remoteMutation: LibraryMutationCoordinator.RemoteMutation?
            if let syncSession, canSyncAccountLibrary {
                remoteMutation = { [accountClient] removing in
                    try await accountClient.pushLibrary(
                        authKey: syncSession.authKey,
                        changes: [RemoteLibraryItem(item: item, removed: removing)]
                    )
                }
            } else {
                remoteMutation = nil
            }
            let updatedLibrary = try await libraryMutationCoordinator.toggle(
                item,
                store: activeStore,
                remoteMutation: remoteMutation
            )
            guard activeStore === libraryStore,
                  activeProfileID == activeViewingProfileID,
                  activeAuthKey == session?.authKey
            else { return }
            library = updatedLibrary
            await reloadHomeAfterProfileMutation()
            if syncSession != nil, canSyncAccountLibrary {
                accountSyncStatus = "Library synced"
            } else if session != nil {
                accountSyncStatus = "Local profile · Library stays private"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isInLibrary(_ item: MetaItem) -> Bool {
        library.contains { $0.id == item.id && $0.type == item.type }
    }

    func resumeProgress(for item: MetaItem) -> PlaybackProgress? {
        currentPlaybackProgress["\(item.type):\(item.id)"]
    }

    func episodeContentIdentifier(_ video: Video, in series: MetaItem) -> String {
        EpisodePlaybackIdentity.contentIdentifier(
            seriesID: series.id,
            videoID: video.id
        )
    }

    func episodeContentTitle(_ video: Video, in series: MetaItem) -> String {
        EpisodePlaybackIdentity.contentTitle(seriesTitle: series.name, video: video)
    }

    func episodeProgress(_ video: Video, in series: MetaItem) -> PlaybackProgress? {
        playbackProgress[episodeContentIdentifier(video, in: series)]
    }

    func seriesResumeSelection(for series: MetaItem) -> EpisodeResumeSelection? {
        EpisodeResumeSelector.latest(
            episodes: series.videos ?? [],
            seriesID: series.id,
            progressByIdentifier: currentPlaybackProgress
        )
    }

    func seasonResumeSelection(
        _ season: Int,
        in series: MetaItem
    ) -> EpisodeResumeSelection? {
        EpisodeResumeSelector.latest(
            episodes: series.videos ?? [],
            seriesID: series.id,
            season: season,
            progressByIdentifier: currentPlaybackProgress
        )
    }

    func isEpisodeCompleted(_ video: Video, in series: MetaItem) -> Bool {
        completedPlaybackIdentifiers.contains(
            episodeContentIdentifier(video, in: series)
        )
    }

    func recordPlaybackProgress(
        contentIdentifier: String?,
        contentTitle: String?,
        stream: Stream,
        providerName: String?,
        position: TimeInterval,
        duration: TimeInterval,
        mediaMetadata: PlaybackMediaMetadata? = nil,
        updateKind: PlaybackProgressUpdateKind = .final
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
            duration: duration,
            mediaMetadata: mediaMetadata
        )
        let isCompleted = PlaybackProgress.isCompleted(
            position: position,
            duration: duration
        )
        let isEpisodePlayback = mediaMetadata?.episodeID != nil
            || (contentIdentifier.hasPrefix("series:")
                && contentIdentifier.contains(":episode:"))
        let completionTransition = isEpisodePlayback
            ? EpisodePlaybackCompletionPolicy.transition(
                isCompleted: currentCompletedPlaybackIdentifiers.contains(
                    contentIdentifier
                ),
                position: position,
                duration: duration
            )
            : .noChange
        let activeStateStore = playbackStateStore
        let activeProfileID = activeViewingProfileID
        playbackProgressUpdateDates[contentIdentifier] = progress.updatedAt
        if PlaybackProgress.shouldSave(position: position, duration: duration) {
            currentPlaybackProgress[contentIdentifier] = progress
            if completionTransition == .markIncomplete {
                currentCompletedPlaybackIdentifiers.remove(contentIdentifier)
                completedPlaybackIdentifiers.remove(contentIdentifier)
            }
            if updateKind == .final {
                playbackProgress[contentIdentifier] = progress
            }
        } else if isCompleted {
            currentPlaybackProgress.removeValue(forKey: contentIdentifier)
            currentCompletedPlaybackIdentifiers.insert(contentIdentifier)
            if updateKind == .final {
                playbackProgress.removeValue(forKey: contentIdentifier)
                completedPlaybackIdentifiers.insert(contentIdentifier)
            }
        } else {
            return
        }

        Task {
            do {
                let stateTransition: EpisodePlaybackCompletionTransition = isCompleted
                    ? .markCompleted : completionTransition
                let persisted = try await activeStateStore.record(
                    progress,
                    completionTransition: stateTransition
                )
                guard activeStateStore === playbackStateStore,
                      activeProfileID == activeViewingProfileID
                else { return }
                guard playbackProgressUpdateDates[contentIdentifier] == progress.updatedAt else {
                    return
                }
                publishPlaybackState(
                    persisted,
                    contentIdentifier: contentIdentifier,
                    updateKind: updateKind
                )
            } catch {
                let restored = try? await activeStateStore.snapshot()
                guard activeStateStore === playbackStateStore,
                      activeProfileID == activeViewingProfileID,
                      playbackProgressUpdateDates[contentIdentifier] == progress.updatedAt
                else { return }
                if let restored {
                    publishPlaybackState(
                        restored,
                        contentIdentifier: contentIdentifier,
                        updateKind: updateKind
                    )
                }
                profileStorageWarning =
                    "Bunny could not save playback state. The previous saved state was restored."
                errorMessage = storageWarningMessage
                NSLog("PLAYBACK_STATE save_failed=%@", error.localizedDescription)
            }
        }
    }

    private func publishPlaybackState(
        _ state: PlaybackStateSnapshot,
        contentIdentifier: String,
        updateKind: PlaybackProgressUpdateKind
    ) {
        if let saved = state.progress.first(where: {
            $0.contentIdentifier == contentIdentifier
        }) {
            currentPlaybackProgress[contentIdentifier] = saved
            if updateKind == .final {
                playbackProgress[contentIdentifier] = saved
            }
        } else {
            currentPlaybackProgress.removeValue(forKey: contentIdentifier)
            if updateKind == .final {
                playbackProgress.removeValue(forKey: contentIdentifier)
            }
        }

        let completed = state.completions.contains {
            $0.contentIdentifier == contentIdentifier
        }
        if completed {
            currentCompletedPlaybackIdentifiers.insert(contentIdentifier)
            if updateKind == .final {
                completedPlaybackIdentifiers.insert(contentIdentifier)
            }
        } else {
            currentCompletedPlaybackIdentifiers.remove(contentIdentifier)
            if updateKind == .final {
                completedPlaybackIdentifiers.remove(contentIdentifier)
            }
        }
    }

    private func continueWatchingEntry(
        for progress: PlaybackProgress,
        knownItemsByIdentifier: [String: MetaItem]
    ) -> ContinueWatchingEntry {
        if let metadata = progress.mediaMetadata {
            let key = "\(metadata.mediaType):\(metadata.mediaID)"
            let knownItem = knownItemsByIdentifier[key]
            let fallbackEpisode = metadata.episodeID.map { episodeID in
                Video(
                    id: episodeID,
                    title: metadata.episodeTitle,
                    season: metadata.season,
                    episode: metadata.episode,
                    thumbnail: metadata.episodeThumbnailURL
                )
            }
            let episode = metadata.episodeID.flatMap { episodeID in
                knownItem?.videos?.first { $0.id == episodeID }
            } ?? fallbackEpisode
            let item = knownItem ?? MetaItem(
                id: metadata.mediaID,
                type: metadata.mediaType,
                name: metadata.mediaTitle,
                poster: metadata.posterURL,
                videos: episode.map { [$0] }
            )
            return ContinueWatchingEntry(
                progress: progress,
                item: item,
                episode: episode
            )
        }

        if let identity = Self.legacyEpisodeIdentity(progress.contentIdentifier) {
            let key = "series:\(identity.seriesID)"
            let knownItem = knownItemsByIdentifier[key]
            let episode = knownItem?.videos?.first { $0.id == identity.videoID }
                ?? Video(id: identity.videoID)
            let fallbackTitle = progress.contentTitle
                .components(separatedBy: " • ")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let seriesTitle = fallbackTitle.flatMap { $0.isEmpty ? nil : $0 }
                ?? progress.contentTitle
            let item = knownItem ?? MetaItem(
                id: identity.seriesID,
                type: "series",
                name: seriesTitle,
                videos: [episode]
            )
            return ContinueWatchingEntry(
                progress: progress,
                item: item,
                episode: episode
            )
        }

        let identity = progress.contentIdentifier.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        let type = identity.first.map(String.init) ?? "movie"
        let mediaID = identity.count > 1 ? String(identity[1]) : progress.contentIdentifier
        let item = knownItemsByIdentifier["\(type):\(mediaID)"] ?? MetaItem(
            id: mediaID,
            type: type,
            name: progress.contentTitle
        )
        return ContinueWatchingEntry(progress: progress, item: item, episode: nil)
    }

    private nonisolated static func legacyEpisodeIdentity(
        _ contentIdentifier: String
    ) -> (seriesID: String, videoID: String)? {
        guard contentIdentifier.hasPrefix("series:"),
              let marker = contentIdentifier.range(of: ":episode:")
        else { return nil }
        let seriesStart = contentIdentifier.index(
            contentIdentifier.startIndex,
            offsetBy: "series:".count
        )
        let seriesID = String(contentIdentifier[seriesStart..<marker.lowerBound])
        let videoID = String(contentIdentifier[marker.upperBound...])
        guard !seriesID.isEmpty, !videoID.isEmpty else { return nil }
        return (seriesID, videoID)
    }

    func installAddon(_ input: String) async throws {
        let endpoint = try AddonEndpoint(manifestInput: input)
        let manifest = try await AddonClient(endpoint: endpoint).manifest()
        addonManifestCache[endpoint.manifestURL] = manifest
        try await withSerializedAddonMutation {
            guard !installedAddons.contains(endpoint.manifestURL) else { return }
            if let session {
                addonMutationRevision += 1
                let addonDescriptors = try await addonSyncCoordinator.install(
                    SyncedAddon(manifest: manifest, transportUrl: endpoint.manifestURL),
                    authKey: session.authKey
                )
                guard self.session?.authKey == session.authKey else { return }
                // The account snapshot is authoritative. Persist it before
                // publishing; on a local failure the unchanged membership
                // keeps this same install retryable.
                try applySyncedAddonSnapshot(addonDescriptors)
                accountSyncStatus = "Add-ons synced"
            } else {
                let updatedAddons = installedAddons + [endpoint.manifestURL]
                try persistAddonURLs(updatedAddons)
                installedAddons = updatedAddons
                addonMutationRevision += 1
            }
        }
    }

    func removeAddon(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await withSerializedAddonMutation {
                    guard url != primaryEndpoint.manifestURL,
                          installedAddons.contains(url)
                    else { return }
                    if let session {
                        addonMutationRevision += 1
                        let addonDescriptors = try await addonSyncCoordinator.remove(
                            transportURL: url,
                            authKey: session.authKey
                        )
                        guard self.session?.authKey == session.authKey else { return }
                        try applySyncedAddonSnapshot(addonDescriptors)
                        accountSyncStatus = "Add-ons synced"
                    } else {
                        let updatedAddons = installedAddons.filter { $0 != url }
                        try persistAddonURLs(updatedAddons)
                        installedAddons = updatedAddons
                        syncedAddonDescriptors.removeAll { $0.transportUrl == url }
                        addonMutationRevision += 1
                    }
                }
            } catch {
                accountSyncStatus = "Add-on removal failed"
                errorMessage = error.localizedDescription
            }
        }
    }

    private func withSerializedAddonMutation<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        await addonMutationGate.enter()
        do {
            let value = try await operation()
            await addonMutationGate.leave()
            return value
        } catch {
            await addonMutationGate.leave()
            throw error
        }
    }

    func signIn(email: String, password: String) async throws {
        let credentials = try SignInFormCredentials(email: email, password: password)
        let responseSession = try await accountClient.login(
            email: credentials.email,
            password: credentials.password
        )
        let signedIn = AccountStorageScope.sessionEnsuringStableIdentity(
            responseSession,
            submittedEmail: credentials.email
        )
        try await withSerializedProfileMutation {
            if let snapshot = viewingProfileSnapshot {
                try await migrateLegacyAccountLibraryIfNeeded(
                    for: signedIn,
                    in: snapshot
                )
            }

            let preparedProfile: PreparedProfileActivation?
            if let snapshot = viewingProfileSnapshot {
                guard let prepared = try await prepareProfileActivation(
                    snapshot,
                    session: signedIn
                ) else { throw CancellationError() }
                preparedProfile = prepared
            } else {
                preparedProfile = nil
            }

            // Preparation performs every fallible profile read first. Persisting
            // the credential is the last fallible step; publication below is only
            // in-memory assignment, so sign-in never needs a fallible rollback.
            try sessionStore.save(signedIn)
            session = signedIn
            accountEmail = signedIn.user.email ?? credentials.email
            addonMutationRevision += 1
            sessionStorageWarning = nil
            if let preparedProfile {
                publishProfileActivation(preparedProfile)
            }
        }
        await reloadHomeAfterProfileMutation()
        try? await syncAccount()
    }

    func signOut() async {
        var failureMessage: String?
        do {
            try await withSerializedProfileMutation {
                let preparedProfile: PreparedProfileActivation?
                if let snapshot = viewingProfileSnapshot {
                    do {
                        guard let prepared = try await prepareProfileActivation(
                            snapshot,
                            session: nil
                        ) else { throw CancellationError() }
                        preparedProfile = prepared
                    } catch {
                        failureMessage = error.localizedDescription
                        throw error
                    }
                } else {
                    preparedProfile = nil
                }

                do {
                    try sessionStore.clear()
                } catch {
                    failureMessage =
                        "Bunny could not remove the saved session. Nothing was changed."
                    throw error
                }

                // The secure credential is gone and the prepared anonymous stores are
                // already readable. Everything remaining is non-fallible publication.
                session = nil
                accountEmail = nil
                addonMutationRevision += 1
                syncedAddonDescriptors = []
                accountSyncStatus = "Not signed in"
                sessionStorageWarning = nil
                if let preparedProfile {
                    publishProfileActivation(preparedProfile)
                }
            }
        } catch {
            accountSyncStatus = "Sign out failed"
            errorMessage = failureMessage ?? error.localizedDescription
            return
        }
        await reloadHomeAfterProfileMutation()
    }

    func syncAccount() async throws {
        try await withSerializedAccountSync {
            try await performAccountSync()
        }
    }

    private func withSerializedAccountSync<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        await accountSyncGate.enter()
        do {
            let value = try await operation()
            await accountSyncGate.leave()
            return value
        } catch {
            await accountSyncGate.leave()
            throw error
        }
    }

    private func performAccountSync() async throws {
        guard let session else { return }
        let activeStore = libraryStore
        let activeProfileID = activeViewingProfileID
        let canSyncAccountLibrary = viewingProfileSnapshot?
            .activeProfileAllowsAccountLibrarySync == true
        let addonRevision = addonMutationRevision
        accountSyncStatus = "Syncing…"
        do {
            if canSyncAccountLibrary {
                async let updatedLibrary = libraryMutationCoordinator.synchronize(
                    store: activeStore,
                    remoteSnapshot: { [accountClient] in
                        try await accountClient.pullLibrary(authKey: session.authKey)
                    }
                )
                async let remoteAddons = addonSyncCoordinator.snapshot(
                    authKey: session.authKey
                )
                let (syncedLibrary, addonDescriptors) = try await (
                    updatedLibrary,
                    remoteAddons
                )
                guard self.session?.authKey == session.authKey,
                      activeStore === libraryStore,
                      activeProfileID == activeViewingProfileID,
                      viewingProfileSnapshot?
                        .activeProfileAllowsAccountLibrarySync == true
                else { return }

                library = syncedLibrary
                if addonMutationRevision == addonRevision {
                    try applySyncedAddonSnapshot(addonDescriptors)
                }
                accountSyncStatus = "Synced now"
                await reloadHomeAfterProfileMutation()
            } else {
                // Add-ons are an account-level setting. Secondary viewing
                // profiles receive them, but their private library never reads
                // from or writes to the Stremio account snapshot.
                let addonDescriptors = try await addonSyncCoordinator.snapshot(
                    authKey: session.authKey
                )
                guard self.session?.authKey == session.authKey else { return }
                if addonMutationRevision == addonRevision {
                    try applySyncedAddonSnapshot(addonDescriptors)
                }
                accountSyncStatus = "Local profile · Add-ons synced"
            }
        } catch {
            guard self.session?.authKey == session.authKey else { return }
            accountSyncStatus = "Sync failed"
            NSLog("[AccountSync] %@", error.localizedDescription)
            throw error
        }
    }

    private func applySyncedAddonSnapshot(
        _ addonDescriptors: [SyncedAddon]
    ) throws {
        var updatedAddons = try addonDescriptors.map { descriptor in
            guard (try? AddonEndpoint(manifestURL: descriptor.transportUrl)) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return descriptor.transportUrl
        }
        if !updatedAddons.contains(primaryEndpoint.manifestURL) {
            updatedAddons.insert(primaryEndpoint.manifestURL, at: 0)
        }
        try persistAddonURLs(updatedAddons)

        syncedAddonDescriptors = addonDescriptors
        for descriptor in addonDescriptors {
            addonManifestCache[descriptor.transportUrl] = descriptor.manifest
        }
        installedAddons = updatedAddons
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
        var detectedMIMEType: String?
        var trustedPrivateNetworkOrigin: URL? = nil
        var requiresFreshProviderResolutionOnFailure = false
        if let url = stream.url {
            if TorBoxPlaybackResolver.shouldResolve(
                stream: stream,
                url: url,
                providerName: providerName
            ) {
                requiresFreshProviderResolutionOnFailure = true
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
                    #if os(tvOS)
                    // AVKit on Apple TV gets the provider URL first and the
                    // existing streaming-server HLS route as its fallback.
                    // The iOS loopback bridge depends on the Rust timing core
                    // and custom players, which are intentionally absent from
                    // the lightweight tvOS target.
                    _ = contentLength
                    #else
                    sourceURL = try await StreamTransportBridge.shared.localURL(
                        upstream: resolved.url,
                        contentLength: contentLength,
                        mimeType: "video/mp2t"
                    )
                    detectedMIMEType = "application/vnd.apple.mpegurl"
                    trustedPrivateNetworkOrigin = sourceURL
                    #endif
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
            trustedPrivateNetworkOrigin = endpoint?.baseURL
        }

        #if os(tvOS)
        let requiresCompatibilityPlayback = TVPlaybackCompatibilityPolicy
            .requiresFallback(
                streamPrefersCompatibility: stream.prefersCompatibilityPlayback,
                detectedMIMEType: detectedMIMEType
            )
        #else
        // Bunny always tries the direct URL first. For containers/codecs that
        // need capabilities outside Apple's decoders, prepare the configured
        // server's HLS route as a second candidate without changing the
        // primary clean-room Rust path.
        let requiresCompatibilityPlayback = stream.prefersCompatibilityPlayback
        #endif
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
            detectedMIMEType: detectedMIMEType,
            trustedPrivateNetworkOrigin: trustedPrivateNetworkOrigin,
            requiresFreshProviderResolutionOnFailure:
                requiresFreshProviderResolutionOnFailure
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
            let directStartup = try await AppPlayerStartupBenchmark.measure(url: url)
            let hlsURL = url.deletingLastPathComponent().appendingPathComponent("sample.m3u8")
            let hlsStartup = try await AppPlayerStartupBenchmark.measure(url: hlsURL)
            guard let compatibilityStream = loadedStreams.first(where: {
                $0.url != nil && $0.prefersCompatibilityPlayback
            }), let compatibilitySourceURL = compatibilityStream.url else {
                throw E2EFailure("No incompatible direct stream")
            }
            let containerStartup = try await AppPlayerStartupBenchmark.measure(
                url: compatibilitySourceURL,
                timeoutSeconds: 20
            )
            guard let torrent = loadedStreams.first(where: \.isTorrent) else {
                throw E2EFailure("No torrent stream")
            }
            let torrentPlan = try await playbackPlan(for: torrent)
            let torrentStartup = try await AppPlayerStartupBenchmark.measure(
                url: torrentPlan.primaryURL
            )

            guard let e2eEmail = ProcessInfo.processInfo.environment["SKELETON_E2E_EMAIL"],
                  let e2ePassword = ProcessInfo.processInfo.environment["SKELETON_E2E_PASSWORD"]
            else { throw E2EFailure("Missing E2E account credentials") }
            let e2eSession = try await accountClient.login(email: e2eEmail, password: e2ePassword)
            try sessionStore.save(e2eSession)
            let sessionPersistenceRoundTrip = try sessionStore.load() == e2eSession
            try sessionStore.clear()
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
                bunnyDirectStartupMilliseconds: directStartup,
                bunnyHLSStartupMilliseconds: hlsStartup,
                bunnyContainerStartupMilliseconds: containerStartup,
                bunnyTorrentStartupMilliseconds: torrentStartup,
                libraryRoundTrip: added && removed,
                accountSync: accountSynced,
                sessionPersistenceRoundTrip: sessionPersistenceRoundTrip
            )
            NSLog(
                "[SkeletonE2E:%@] PASS manifest=%@ catalog=%ld letterboxd=%ld paging=%d search=%d streams=%ld providers=%d bunny_direct_ms=%.1f bunny_hls_ms=%.1f bunny_mkv_h264_ms=%.1f bunny_torrent_ms=%.1f library=%d account=%d session=%d",
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
        let matchingCatalogs = manifest.catalogs.filter {
            $0.type == source.preferredType
        }
        if search != nil,
           let searchable = matchingCatalogs.first(where: { $0.supportsExtra("search") }) {
            return searchable
        }
        return matchingCatalogs.first(where: { $0.id == source.preferredCatalogID })
            ?? matchingCatalogs.first
            ?? manifest.catalogs.first
    }

    private func migrateLegacyAddonURLsIfNeeded(
        profileID: UUID,
        session scopedSession: StremioSession?
    ) throws {
        let scope = AccountStorageScope.storageScope(
            profileID: profileID,
            session: scopedSession
        )
        do {
            let destination = try addonURLStore.load(scope: scope)
            let legacySecure = try addonURLStore.load()
            let defaults = UserDefaults.standard
            let hasLegacyDefaults = defaults.object(
                forKey: "installedAddonURLs"
            ) != nil
            let legacyDefaults = try (
                defaults.stringArray(forKey: "installedAddonURLs") ?? []
            ).map { value in
                guard let url = URL(string: value),
                      (try? AddonEndpoint(manifestURL: url)) != nil
                else { throw CocoaError(.fileReadCorruptFile) }
                return url
            }

            if destination == nil,
               let legacy = legacySecure ?? (hasLegacyDefaults ? legacyDefaults : nil) {
                try addonURLStore.save(legacy, scope: scope)
            }
            if legacySecure != nil {
                try addonURLStore.clearLegacy()
            }
            if hasLegacyDefaults {
                defaults.removeObject(forKey: "installedAddonURLs")
            }
            addonURLStoreReady = true
            addonStorageWarning = nil
        } catch {
            addonURLStoreReady = false
            addonStorageWarning =
                "Bunny could not migrate saved add-ons. Their existing data was left unchanged."
            NSLog(
                "ADDON_URL_STORE migration_failed code=%ld",
                (error as NSError).code
            )
            throw error
        }
    }

    private func loadAddonURLs(
        profileID: UUID,
        session scopedSession: StremioSession?
    ) throws -> [URL] {
        let scope = AccountStorageScope.storageScope(
            profileID: profileID,
            session: scopedSession
        )
        do {
            var stored = try addonURLStore.load(scope: scope) ?? []
            var seen = Set<URL>()
            stored = ([primaryEndpoint.manifestURL] + stored).filter {
                seen.insert($0).inserted
            }
            addonURLStoreReady = true
            addonStorageWarning = nil
            return stored
        } catch {
            addonURLStoreReady = false
            addonStorageWarning =
                "Bunny could not read saved add-ons. Their existing data was left unchanged."
            NSLog("ADDON_URL_STORE load_failed code=%ld", (error as NSError).code)
            throw error
        }
    }

    private var storageWarningMessage: String? {
        let messages = [
            sessionStorageWarning,
            addonStorageWarning,
            profileStorageWarning,
        ].compactMap { $0 }
        return messages.isEmpty ? nil : messages.joined(separator: "\n\n")
    }

    private func persistAddonURLs(_ urls: [URL]) throws {
        guard addonURLStoreReady else {
            let error = AppModelPersistenceError.addonStoreUnavailable
            addonStorageWarning = error.localizedDescription
            errorMessage = storageWarningMessage
            throw error
        }
        do {
            guard let profileID = activeViewingProfileID else {
                throw CocoaError(.fileNoSuchFile)
            }
            try addonURLStore.save(
                urls,
                scope: AccountStorageScope.storageScope(
                    profileID: profileID,
                    session: session
                )
            )
            UserDefaults.standard.removeObject(forKey: "installedAddonURLs")
            addonStorageWarning = nil
        } catch {
            NSLog("ADDON_URL_STORE save_failed code=%ld", (error as NSError).code)
            addonStorageWarning =
                "Bunny could not save add-on changes. The previous saved list was left unchanged."
            errorMessage = storageWarningMessage
            throw error
        }
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

#if os(tvOS)
private typealias AppPlayerStartupBenchmark = PlayerStartupBenchmark
#else
private typealias AppPlayerStartupBenchmark = BunnyPlayerStartupBenchmark

@MainActor
enum BunnyPlayerStartupBenchmark {
    static func measure(url: URL, timeoutSeconds: Double = 10) async throws -> Double {
        let policy = PlaybackPerformanceCore.policy(
            url: url,
            title: url.lastPathComponent,
            player: .bunny
        )
        guard policy.decoder != .avFoundation else {
            return try await PlayerStartupBenchmark.measure(
                url: url,
                timeoutSeconds: timeoutSeconds
            )
        }

        let trustedOrigin: URL?
        #if targetEnvironment(simulator)
        trustedOrigin = ["127.0.0.1", "localhost", "::1"]
            .contains(url.host?.lowercased() ?? "") ? url : nil
        #else
        trustedOrigin = nil
        #endif

        let decoder = BunnyNativeDecoder(
            url: url,
            trustedPrivateNetworkOrigin: trustedOrigin
        )
        let host = UIView(frame: CGRect(x: -4, y: -4, width: 2, height: 2))
        host.alpha = 0.01
        decoder.videoLayer.frame = host.bounds
        host.layer.addSublayer(decoder.videoLayer)

        var mediaInfo: BunnyNativeMediaInfo?
        var visibleFrame = false
        var renderedAudioSamples = 0
        var failure: Error?
        decoder.onOpen = { info in mediaInfo = info }
        decoder.onFirstFrame = { visibleFrame = true }
        decoder.onMetrics = { _, _, audio, _, _, _ in
            renderedAudioSamples = audio
        }
        decoder.onFailure = { error in failure = error }

        let started = CFAbsoluteTimeGetCurrent()
        decoder.start()
        defer {
            decoder.stop()
            decoder.videoLayer.removeFromSuperlayer()
        }

        let attempts = Int(timeoutSeconds / 0.05)
        for _ in 0..<attempts {
            if let failure { throw failure }
            if let mediaInfo {
                decoder.play(atRate: 1)
                let hasRenderedMedia = mediaInfo.hasVideo
                    ? visibleFrame
                    : renderedAudioSamples > 0
                if hasRenderedMedia {
                    decoder.pause()
                    return (CFAbsoluteTimeGetCurrent() - started) * 1_000
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw E2EFailure("Bunny player startup timed out")
    }
}
#endif
