import Foundation

public protocol PlaybackTransitionRecord: Codable, Equatable, Sendable {
    var contentIdentifier: String { get }
    var position: TimeInterval { get }
    var duration: TimeInterval { get }
    var updatedAt: Date { get }
    var playbackPersistenceSafe: Self? { get }
}

public struct PlaybackTransitionSnapshot<Record: PlaybackTransitionRecord>:
    Equatable,
    Sendable
{
    public let progress: [Record]
    public let completions: [PlaybackCompletion]

    public init(progress: [Record], completions: [PlaybackCompletion]) {
        self.progress = progress
        self.completions = completions
    }
}

/// Persists resume progress and completion markers in one atomic document.
/// This generic form is used by watchOS, whose resume records carry watch-only
/// routing metadata that cannot be represented by `PlaybackProgress`.
public actor PlaybackTransitionStore<Record: PlaybackTransitionRecord> {
    public typealias PersistenceWillWrite = @Sendable () throws -> Void

    private struct Document: Codable {
        let schemaVersion: Int
        let progress: [Record]
        let completions: [PlaybackCompletion]
    }

    private static var schemaVersion: Int { 1 }

    private let fileURL: URL
    private let legacyProgressFileURL: URL?
    private let legacyCompletionFileURL: URL?
    private let persistenceWillWrite: PersistenceWillWrite
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: PlaybackTransitionSnapshot<Record>?
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

    public func snapshot() throws -> PlaybackTransitionSnapshot<Record> {
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
                let empty = PlaybackTransitionSnapshot<Record>(
                    progress: [],
                    completions: []
                )
                try persist(empty)
                return empty
            }
            let state = sanitized(
                progress: document.progress,
                completions: document.completions
            )
            if state.progress != document.progress
                || state.completions != document.completions {
                try persist(state)
            } else {
                cacheState(state)
            }
            return state
        }

        let migrated = try migratedLegacyState()
        try persist(migrated)
        return migrated
    }

    @discardableResult
    public func record(
        _ record: Record,
        completionTransition: EpisodePlaybackCompletionTransition
    ) throws -> PlaybackTransitionSnapshot<Record> {
        let current = try snapshot()
        guard !record.contentIdentifier.isEmpty,
              let safeRecord = record.playbackPersistenceSafe,
              safeRecord.position >= PlaybackProgress.minimumResumePosition
        else { return current }
        if let latest = latestUpdates[safeRecord.contentIdentifier],
           latest > safeRecord.updatedAt {
            return current
        }

        let identifier = safeRecord.contentIdentifier
        var nextProgress = current.progress
        var nextCompletions = current.completions
        if PlaybackProgress.shouldSave(
            position: safeRecord.position,
            duration: safeRecord.duration
        ) {
            nextProgress.removeAll { $0.contentIdentifier == identifier }
            nextProgress.append(safeRecord)
            if completionTransition == .markIncomplete {
                nextCompletions.removeAll { $0.contentIdentifier == identifier }
            }
        } else if PlaybackProgress.isCompleted(
            position: safeRecord.position,
            duration: safeRecord.duration
        ) {
            nextProgress.removeAll { $0.contentIdentifier == identifier }
            if completionTransition == .markCompleted {
                nextCompletions.removeAll { $0.contentIdentifier == identifier }
                nextCompletions.append(
                    PlaybackCompletion(
                        contentIdentifier: identifier,
                        completedAt: safeRecord.updatedAt
                    )
                )
            }
        } else {
            return current
        }

        let next = PlaybackTransitionSnapshot(
            progress: nextProgress.sorted { $0.updatedAt > $1.updatedAt },
            completions: nextCompletions.sorted { $0.completedAt > $1.completedAt }
        )
        try persist(next)
        return next
    }

    @discardableResult
    public func removeProgress(
        contentIdentifier: String,
        updatedAt: Date = Date()
    ) throws -> PlaybackTransitionSnapshot<Record> {
        let current = try snapshot()
        guard !contentIdentifier.isEmpty else { return current }
        if let latest = latestUpdates[contentIdentifier], latest > updatedAt {
            return current
        }
        let remaining = current.progress.filter {
            $0.contentIdentifier != contentIdentifier
        }
        guard remaining.count != current.progress.count else { return current }
        let next = PlaybackTransitionSnapshot(
            progress: remaining,
            completions: current.completions
        )
        try persist(next)
        latestUpdates[contentIdentifier] = updatedAt
        return next
    }

    private func migratedLegacyState() throws -> PlaybackTransitionSnapshot<Record> {
        let progress: [Record]
        if let legacyProgressFileURL,
           FileManager.default.fileExists(atPath: legacyProgressFileURL.path) {
            let data = try Data(contentsOf: legacyProgressFileURL)
            do {
                progress = try decoder.decode([Record].self, from: data)
            } catch {
                try LocalPreferenceRecovery.preserveCorruptFile(
                    legacyProgressFileURL
                )
                progress = []
            }
        } else {
            progress = []
        }
        let completions: [PlaybackCompletion]
        if let legacyCompletionFileURL,
           FileManager.default.fileExists(atPath: legacyCompletionFileURL.path) {
            let data = try Data(contentsOf: legacyCompletionFileURL)
            do {
                completions = try decoder.decode(
                    [PlaybackCompletion].self,
                    from: data
                )
            } catch {
                try LocalPreferenceRecovery.preserveCorruptFile(
                    legacyCompletionFileURL
                )
                completions = []
            }
        } else {
            completions = []
        }
        return sanitized(progress: progress, completions: completions)
    }

    private func sanitized(
        progress: [Record],
        completions: [PlaybackCompletion]
    ) -> PlaybackTransitionSnapshot<Record> {
        var progressByID: [String: Record] = [:]
        for record in progress {
            guard let safe = record.playbackPersistenceSafe,
                  !safe.contentIdentifier.isEmpty
            else { continue }
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
        for (identifier, completion) in completionByID {
            guard let record = progressByID[identifier] else { continue }
            if completion.completedAt >= record.updatedAt {
                progressByID.removeValue(forKey: identifier)
            } else {
                completionByID.removeValue(forKey: identifier)
            }
        }
        return PlaybackTransitionSnapshot(
            progress: progressByID.values.sorted { $0.updatedAt > $1.updatedAt },
            completions: completionByID.values.sorted {
                $0.completedAt > $1.completedAt
            }
        )
    }

    private func persist(_ state: PlaybackTransitionSnapshot<Record>) throws {
        try persistenceWillWrite()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = Document(
            schemaVersion: Self.schemaVersion,
            progress: state.progress,
            completions: state.completions
        )
        try encoder.encode(document).write(to: fileURL, options: .atomic)
        cacheState(state)
    }

    private func cacheState(_ state: PlaybackTransitionSnapshot<Record>) {
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
