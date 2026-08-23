import Foundation

public struct EpisodeResumeSelection: Equatable, Sendable {
    public let episode: Video
    public let progress: PlaybackProgress

    public init(episode: Video, progress: PlaybackProgress) {
        self.episode = episode
        self.progress = progress
    }
}

public enum EpisodeResumeSelector {
    /// Returns the most recently watched unfinished episode. Supplying a
    /// season keeps each season's resume point independent while the same
    /// selector without a season powers the series-wide resume action.
    public static func latest(
        episodes: [Video],
        seriesID: String,
        season: Int? = nil,
        progressByIdentifier: [String: PlaybackProgress]
    ) -> EpisodeResumeSelection? {
        episodes
            .filter { season == nil || ($0.season ?? 0) == season }
            .compactMap { episode -> EpisodeResumeSelection? in
                let identifier = EpisodePlaybackIdentity.contentIdentifier(
                    seriesID: seriesID,
                    videoID: episode.id
                )
                guard let progress = progressByIdentifier[identifier] else {
                    return nil
                }
                return EpisodeResumeSelection(
                    episode: episode,
                    progress: progress
                )
            }
            .max { $0.progress.updatedAt < $1.progress.updatedAt }
    }
}

public enum EpisodeAutoplaySelector {
    /// Returns the next regular episode in playback order. Specials only
    /// advance within the Specials season, so finishing a series finale never
    /// unexpectedly jumps into bonus material.
    public static func nextEpisode(
        after currentEpisode: Video,
        episodes: [Video]
    ) -> Video? {
        var seen = Set<String>()
        let currentSeason = currentEpisode.season ?? 0
        let ordered = episodes
            .filter { episode in
                guard !episode.id.isEmpty, seen.insert(episode.id).inserted else {
                    return false
                }
                let season = episode.season ?? 0
                return currentSeason == 0 ? season == 0 : season > 0
            }
            .sorted(by: episodePlaybackOrder)

        guard let currentIndex = ordered.firstIndex(where: {
            $0.id == currentEpisode.id
        }) else { return nil }
        let nextIndex = ordered.index(after: currentIndex)
        return ordered.indices.contains(nextIndex) ? ordered[nextIndex] : nil
    }

    private static func episodePlaybackOrder(_ lhs: Video, _ rhs: Video) -> Bool {
        let lhsSeason = lhs.season ?? 0
        let rhsSeason = rhs.season ?? 0
        if lhsSeason != rhsSeason { return lhsSeason < rhsSeason }

        let lhsEpisode = lhs.episode ?? Int.max
        let rhsEpisode = rhs.episode ?? Int.max
        if lhsEpisode != rhsEpisode { return lhsEpisode < rhsEpisode }

        if lhs.released != rhs.released {
            return (lhs.released ?? "") < (rhs.released ?? "")
        }
        return lhs.id < rhs.id
    }
}

public enum EpisodeAutoplayPresentationPolicy {
    /// Autoplay is tied to a true final callback near the media end rather
    /// than the broader "watched" threshold used to hide resume cards.
    public static func shouldPresent(
        position: TimeInterval,
        duration: TimeInterval,
        isFinalUpdate: Bool
    ) -> Bool {
        guard isFinalUpdate,
              position.isFinite,
              duration.isFinite,
              duration >= PlaybackProgress.minimumResumePosition
        else { return false }
        let remaining = max(duration - position, 0)
        return position >= duration * 0.995 || remaining <= 2
    }
}

public enum EpisodeSeasonSelector {
    /// Restores a valid explicit choice first. New series begin on Season 1,
    /// then the earliest regular season, with Specials as the final fallback.
    public static func initialSeason(
        availableSeasons: [Int],
        persistedSeason: Int?
    ) -> Int? {
        let seasons = Array(Set(availableSeasons)).sorted()
        guard !seasons.isEmpty else { return nil }
        if let persistedSeason, seasons.contains(persistedSeason) {
            return persistedSeason
        }
        if seasons.contains(1) { return 1 }
        if let firstRegularSeason = seasons.first(where: { $0 > 0 }) {
            return firstRegularSeason
        }
        if seasons.contains(0) { return 0 }
        return seasons.first
    }
}

public struct EpisodeSeasonSelectionStore {
    public static let defaultStorageKey = "selectedEpisodeSeasonBySeries.v1"

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func season(for seriesID: String) -> Int? {
        guard !seriesID.isEmpty else { return nil }
        let selections = defaults.dictionary(forKey: storageKey) ?? [:]
        if let season = selections[seriesID] as? Int { return season }
        return (selections[seriesID] as? NSNumber)?.intValue
    }

    public func setSeason(_ season: Int, for seriesID: String) {
        guard !seriesID.isEmpty else { return }
        var selections = defaults.dictionary(forKey: storageKey) ?? [:]
        selections[seriesID] = season
        defaults.set(selections, forKey: storageKey)
    }
}
