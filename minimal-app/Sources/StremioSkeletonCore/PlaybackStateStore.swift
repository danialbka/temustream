import Foundation

public struct PlaybackStateSnapshot: Equatable, Sendable {
    public let progress: [PlaybackProgress]
    public let completions: [PlaybackCompletion]

    public init(
        progress: [PlaybackProgress],
        completions: [PlaybackCompletion]
    ) {
        self.progress = progress
        self.completions = completions
    }
}

/// Owns progress and completion as one atomic document. A playback transition
/// can therefore never durably remove resume state without also recording its
/// completion marker (or vice versa).
public actor PlaybackStateStore {
    public typealias PersistenceWillWrite = @Sendable () throws -> Void

    private struct Document: Codable {
        let schemaVersion: Int
        let progress: [PlaybackProgress]
        let completions: [PlaybackCompletion]
    }

    private static let schemaVersion = 1

    private let fileURL: URL
    private let legacyProgressFileURL: URL?
    private let legacyCompletionFileURL: URL?
    private let persistenceWillWrite: PersistenceWillWrite
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: PlaybackStateSnapshot?
    private var latestUpdates: [String: Date] = [:]

    public init(
        fileURL: URL,
        legacyProgressFileURL: URL? = nil,
        legacyCompletionFileURL: URL? = nil,
        persistenceWillWrite: @escaping PersistenceWillWrite = {}
    ) {
        self.fileURL = fileURL
        self.legacyProgressFileURL = legacyProgressFileURL
        self.legacyCompletionFileURL = legacyCompletionFileURL
        self.persistenceWillWrite = persistenceWillWrite
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func snapshot() async throws -> PlaybackStateSnapshot {
        if let cache { return cache }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            let document: Document
            do {
                document = try decoder.decode(Document.self, from: data)
                guard document.schemaVersion == Self.schemaVersion else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } catch {
                try LocalPreferenceRecovery.preserveCorruptFile(fileURL)
                let empty = PlaybackStateSnapshot(progress: [], completions: [])
                latestUpdates.removeAll()
                try persist(empty)
                return empty
            }
            let state = Self.sanitized(
                progress: document.progress,
                completions: document.completions
            )
            if state.progress != document.progress
                || state.completions != document.completions {
                // This is an operational normalization write. Propagate its
                // failure without classifying the valid document as corrupt.
                try persist(state)
            } else {
                cacheState(state)
            }
            return state
        }

        let migrated = try await migratedLegacyState()
        try persist(migrated)
        return migrated
    }

    /// Applies the entire transition with one atomic replacement.
    @discardableResult
    public func record(
        _ progress: PlaybackProgress,
        completionTransition: EpisodePlaybackCompletionTransition
    ) async throws -> PlaybackStateSnapshot {
        let current = try await snapshot()
        guard !progress.contentIdentifier.isEmpty,
              progress.isValidForPersistence,
              progress.position >= PlaybackProgress.minimumResumePosition
        else { return current }
        if let latest = latestUpdates[progress.contentIdentifier],
           latest > progress.updatedAt {
            return current
        }

        var nextProgress = current.progress
        var nextCompletions = current.completions
        let identifier = progress.contentIdentifier
        if PlaybackProgress.shouldSave(
            position: progress.position,
            duration: progress.duration
        ) {
            nextProgress.removeAll { $0.contentIdentifier == identifier }
            nextProgress.append(progress.persistenceSafe)
            if completionTransition == .markIncomplete {
                nextCompletions.removeAll { $0.contentIdentifier == identifier }
            }
        } else if PlaybackProgress.isCompleted(
            position: progress.position,
            duration: progress.duration
        ) {
            nextProgress.removeAll { $0.contentIdentifier == identifier }
            if completionTransition == .markCompleted {
                nextCompletions.removeAll { $0.contentIdentifier == identifier }
                nextCompletions.append(
                    PlaybackCompletion(
                        contentIdentifier: identifier,
                        completedAt: progress.updatedAt
                    )
                )
            }
        } else {
            return current
        }

        nextProgress.sort { $0.updatedAt > $1.updatedAt }
        nextCompletions.sort { $0.completedAt > $1.completedAt }
        let next = PlaybackStateSnapshot(
            progress: nextProgress,
            completions: nextCompletions
        )
        try persist(next)
        return next
    }

    private func migratedLegacyState() async throws -> PlaybackStateSnapshot {
        let progress: [PlaybackProgress]
        if let legacyProgressFileURL,
           FileManager.default.fileExists(atPath: legacyProgressFileURL.path) {
            progress = try await PlaybackProgressStore(
                fileURL: legacyProgressFileURL
            ).items()
        } else {
            progress = []
        }

        let completions: [PlaybackCompletion]
        if let legacyCompletionFileURL,
           FileManager.default.fileExists(atPath: legacyCompletionFileURL.path) {
            completions = try await PlaybackCompletionStore(
                fileURL: legacyCompletionFileURL
            ).items()
        } else {
            completions = []
        }
        return Self.sanitized(progress: progress, completions: completions)
    }

    private static func sanitized(
        progress: [PlaybackProgress],
        completions: [PlaybackCompletion]
    ) -> PlaybackStateSnapshot {
        var progressByID: [String: PlaybackProgress] = [:]
        for item in progress where item.isValidForPersistence {
            let safe = item.persistenceSafe
            if progressByID[safe.contentIdentifier]?.updatedAt ?? .distantPast
                < safe.updatedAt {
                progressByID[safe.contentIdentifier] = safe
            }
        }
        var completionByID: [String: PlaybackCompletion] = [:]
        for completion in completions where !completion.contentIdentifier.isEmpty {
            if completionByID[completion.contentIdentifier]?.completedAt ?? .distantPast
                < completion.completedAt {
                completionByID[completion.contentIdentifier] = completion
            }
        }

        // Legacy files could already disagree. The newest event wins during
        // one-time migration so the unified document starts coherent.
        for (identifier, completion) in completionByID {
            guard let saved = progressByID[identifier] else { continue }
            if completion.completedAt >= saved.updatedAt {
                progressByID.removeValue(forKey: identifier)
            } else {
                completionByID.removeValue(forKey: identifier)
            }
        }
        return PlaybackStateSnapshot(
            progress: progressByID.values.sorted { $0.updatedAt > $1.updatedAt },
            completions: completionByID.values.sorted { $0.completedAt > $1.completedAt }
        )
    }

    private func persist(_ state: PlaybackStateSnapshot) throws {
        try persistenceWillWrite()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = Document(
            schemaVersion: Self.schemaVersion,
            progress: state.progress.map(\.persistenceSafe),
            completions: state.completions
        )
        try encoder.encode(document).write(to: fileURL, options: .atomic)
        cacheState(state)
    }

    private func cacheState(_ state: PlaybackStateSnapshot) {
        cache = state
        var updates = Dictionary(
            uniqueKeysWithValues: state.progress.map {
                ($0.contentIdentifier, $0.updatedAt)
            }
        )
        for completion in state.completions {
            if updates[completion.contentIdentifier] ?? .distantPast
                < completion.completedAt {
                updates[completion.contentIdentifier] = completion.completedAt
            }
        }
        latestUpdates = updates
    }
}
