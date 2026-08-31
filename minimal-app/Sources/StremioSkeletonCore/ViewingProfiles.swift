import Foundation

public enum ViewingProfileAvatar: String, CaseIterable, Codable, Equatable, Sendable {
    case bunny
    case carrot
    case moon
    case star
    case popcorn
    case rocket
    case avril
    case sam
    case lopBunny
    case goldenPuppy
    case tabbyKitten
    case seaOtter
}

public struct ViewingProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var name: String
    public var avatar: ViewingProfileAvatar
    public var updatedAt: Date
    public var archivedAt: Date?

    public var isArchived: Bool { archivedAt != nil }

    public init(
        id: UUID = UUID(),
        name: String,
        avatar: ViewingProfileAvatar = .bunny,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.name = name
        self.avatar = avatar
        self.updatedAt = updatedAt ?? createdAt
        self.archivedAt = archivedAt
    }
}

public struct ViewingProfileSnapshot: Equatable, Sendable {
    public let profiles: [ViewingProfile]
    public let archivedProfiles: [ViewingProfile]
    public let activeProfileID: UUID
    public let primaryProfileID: UUID

    public init(
        profiles: [ViewingProfile],
        archivedProfiles: [ViewingProfile],
        activeProfileID: UUID,
        primaryProfileID: UUID
    ) {
        self.profiles = profiles
        self.archivedProfiles = archivedProfiles
        self.activeProfileID = activeProfileID
        self.primaryProfileID = primaryProfileID
    }

    public var activeProfile: ViewingProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    /// Secondary viewing profiles deliberately stay local. Restrict signed-in
    /// library push/pull to the first migrated profile so a guest cannot
    /// replace the account's canonical Stremio library snapshot.
    public var activeProfileAllowsAccountLibrarySync: Bool {
        activeProfileID == primaryProfileID
    }

    public func allowsAccountLibrarySync(for profileID: UUID) -> Bool {
        profileID == primaryProfileID
    }
}

public struct ViewingProfileLegacyFile: Equatable, Sendable {
    public let fileName: String
    public let sourceURL: URL

    public init(fileName: String, sourceURL: URL) {
        self.fileName = fileName
        self.sourceURL = sourceURL
    }
}

public enum ViewingProfileDataFile {
    public static let anonymousLibrary = "library.json"
    public static let playbackState = "playback-state.json"
    public static let playbackProgress = "playback-progress.json"
    public static let playbackCompletions = "playback-completions.json"
    public static let recentSearches = "recent-searches.json"
    public static let mediaRatings = "media-ratings.json"
    public static let recommendationHistory = "recommendation-history.json"
}

public enum ViewingProfileStoreError: Error, Equatable, LocalizedError, Sendable {
    case emptyName
    case nameTooLong(maximum: Int)
    case duplicateName
    case profileNotFound
    case cannotActivateArchivedProfile
    case cannotArchiveLastProfile
    case invalidLegacyFileName
    case staleMutationPlan

    public var errorDescription: String? {
        switch self {
        case .emptyName: return "Enter a profile name."
        case let .nameTooLong(maximum):
            return "Profile names can contain at most \(maximum) characters."
        case .duplicateName: return "A profile with that name already exists."
        case .profileNotFound: return "That profile no longer exists."
        case .cannotActivateArchivedProfile:
            return "Restore this profile before selecting it."
        case .cannotArchiveLastProfile:
            return "At least one viewing profile must remain."
        case .invalidLegacyFileName:
            return "A legacy profile-data filename was invalid."
        case .staleMutationPlan:
            return "The viewing profiles changed before this operation could finish."
        }
    }
}

/// An opaque, one-use profile mutation that can be prepared before its
/// manifest change is persisted. Callers may load and validate the target
/// profile directory, then commit only when publication can no longer fail.
public struct ViewingProfileMutationPlan: Identifiable, Sendable {
    public let id: UUID
    public let snapshot: ViewingProfileSnapshot
    public let activeProfileDataDirectoryURL: URL

    fileprivate init(
        id: UUID,
        snapshot: ViewingProfileSnapshot,
        activeProfileDataDirectoryURL: URL
    ) {
        self.id = id
        self.snapshot = snapshot
        self.activeProfileDataDirectoryURL = activeProfileDataDirectoryURL
    }
}

public struct ViewingProfileMutationCommit: Sendable {
    public let snapshot: ViewingProfileSnapshot
    public let generation: Int

    fileprivate init(snapshot: ViewingProfileSnapshot, generation: Int) {
        self.snapshot = snapshot
        self.generation = generation
    }
}

public actor ViewingProfileStore {
    public static let maximumNameLength = 30
    public static let manifestFileName = "viewing-profiles.json"
    public static let profilesDirectoryName = "viewing-profiles"

    private static let schemaVersion = 1
    private static let legacyMigrationVersion = 1

    private struct Manifest: Codable {
        var schemaVersion: Int
        var legacyMigrationVersion: Int
        var primaryProfileID: UUID
        var activeProfileID: UUID
        var profiles: [ViewingProfile]
    }

    private let rootDirectory: URL
    private let manifestURL: URL
    private let profilesDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cache: Manifest?
    private var mutationGeneration = 0
    private var pendingMutations: [UUID: PendingMutation] = [:]

    private struct PendingMutation {
        let generation: Int
        let manifest: Manifest
    }

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        manifestURL = rootDirectory.appendingPathComponent(Self.manifestFileName)
        profilesDirectoryURL = rootDirectory.appendingPathComponent(
            Self.profilesDirectoryName,
            isDirectory: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Copies legacy single-profile files into the stable default profile.
    /// Originals remain untouched, and the migration marker is written only
    /// after all copies succeed, making retries safe after interruption.
    public func bootstrap(
        defaultName: String = "My Profile",
        defaultAvatar: ViewingProfileAvatar = .bunny,
        migrating legacyFiles: [ViewingProfileLegacyFile] = [],
        now: Date = Date()
    ) throws -> ViewingProfileSnapshot {
        var manifest = try loadOrRecover(
            defaultName: defaultName,
            defaultAvatar: defaultAvatar,
            now: now
        )
        if manifest.legacyMigrationVersion < Self.legacyMigrationVersion {
            try migrate(legacyFiles, to: manifest.primaryProfileID)
            manifest.legacyMigrationVersion = Self.legacyMigrationVersion
            try persist(manifest)
        }
        return makeSnapshot(manifest)
    }

    public func snapshot(now: Date = Date()) throws -> ViewingProfileSnapshot {
        makeSnapshot(try loadOrRecover(now: now))
    }

    /// Prepares creation and activation as one manifest transaction. The new
    /// data directory may be populated and read before `commit` makes the
    /// profile visible or active on the next launch.
    public func prepareCreateAndActivate(
        name: String,
        avatar: ViewingProfileAvatar,
        now: Date = Date()
    ) throws -> ViewingProfileMutationPlan {
        var manifest = try loadOrRecover(now: now)
        let cleanName = try validate(name, excluding: nil, in: manifest)
        let profile = ViewingProfile(
            name: cleanName,
            avatar: avatar,
            createdAt: now
        )
        manifest.profiles.append(profile)
        manifest.activeProfileID = profile.id
        try createDataDirectory(for: profile.id)
        return registerMutation(manifest)
    }

    /// Prepares an active-profile change without persisting it. This lets the
    /// app prove the destination stores are readable before changing startup
    /// state in the manifest.
    public func prepareActivation(
        id: UUID,
        now: Date = Date()
    ) throws -> ViewingProfileMutationPlan {
        var manifest = try loadOrRecover(now: now)
        guard let index = manifest.profiles.firstIndex(where: { $0.id == id }) else {
            throw ViewingProfileStoreError.profileNotFound
        }
        guard !manifest.profiles[index].isArchived else {
            throw ViewingProfileStoreError.cannotActivateArchivedProfile
        }
        manifest.activeProfileID = id
        manifest.profiles[index].updatedAt = now
        try createDataDirectory(for: id)
        return registerMutation(manifest)
    }

    /// Prepares archival, including selection of a replacement when the active
    /// profile is archived, without changing the durable manifest yet.
    public func prepareArchive(
        id: UUID,
        now: Date = Date()
    ) throws -> ViewingProfileMutationPlan {
        var manifest = try loadOrRecover(now: now)
        guard let index = manifest.profiles.firstIndex(where: { $0.id == id }) else {
            throw ViewingProfileStoreError.profileNotFound
        }
        if !manifest.profiles[index].isArchived {
            let remaining = manifest.profiles.filter { !$0.isArchived && $0.id != id }
            guard !remaining.isEmpty else {
                throw ViewingProfileStoreError.cannotArchiveLastProfile
            }
            manifest.profiles[index].archivedAt = now
            manifest.profiles[index].updatedAt = now
            if manifest.activeProfileID == id {
                manifest.activeProfileID = remaining.sorted(by: Self.profileOrder).first!.id
            }
        }
        try createDataDirectory(for: manifest.activeProfileID)
        return registerMutation(manifest)
    }

    /// Commits a previously prepared mutation exactly once. Any intervening
    /// manifest write invalidates the plan rather than overwriting newer state.
    @discardableResult
    public func commit(
        _ plan: ViewingProfileMutationPlan
    ) throws -> ViewingProfileMutationCommit {
        guard let pending = pendingMutations.removeValue(forKey: plan.id),
              pending.generation == mutationGeneration
        else {
            throw ViewingProfileStoreError.staleMutationPlan
        }
        try persist(pending.manifest)
        return ViewingProfileMutationCommit(
            snapshot: makeSnapshot(pending.manifest),
            generation: mutationGeneration
        )
    }

    public func cancel(_ plan: ViewingProfileMutationPlan) {
        pendingMutations.removeValue(forKey: plan.id)
    }

    @discardableResult
    public func create(
        name: String,
        avatar: ViewingProfileAvatar,
        now: Date = Date()
    ) throws -> ViewingProfileSnapshot {
        var manifest = try loadOrRecover(now: now)
        let cleanName = try validate(name, excluding: nil, in: manifest)
        let profile = ViewingProfile(
            name: cleanName,
            avatar: avatar,
            createdAt: now
        )
        manifest.profiles.append(profile)
        try createDataDirectory(for: profile.id)
        try persist(manifest)
        return makeSnapshot(manifest)
    }

    @discardableResult
    public func update(
        id: UUID,
        name: String,
        avatar: ViewingProfileAvatar,
        now: Date = Date()
    ) throws -> ViewingProfileSnapshot {
        try updateWithCommit(
            id: id,
            name: name,
            avatar: avatar,
            now: now
        ).snapshot
    }

    @discardableResult
    public func updateWithCommit(
        id: UUID,
        name: String,
        avatar: ViewingProfileAvatar,
        now: Date = Date()
    ) throws -> ViewingProfileMutationCommit {
        var manifest = try loadOrRecover(now: now)
        guard let index = manifest.profiles.firstIndex(where: { $0.id == id }) else {
            throw ViewingProfileStoreError.profileNotFound
        }
        manifest.profiles[index].name = try validate(name, excluding: id, in: manifest)
        manifest.profiles[index].avatar = avatar
        manifest.profiles[index].updatedAt = now
        try persist(manifest)
        return ViewingProfileMutationCommit(
            snapshot: makeSnapshot(manifest),
            generation: mutationGeneration
        )
    }

    @discardableResult
    public func activate(id: UUID, now: Date = Date()) throws -> ViewingProfileSnapshot {
        var manifest = try loadOrRecover(now: now)
        guard let index = manifest.profiles.firstIndex(where: { $0.id == id }) else {
            throw ViewingProfileStoreError.profileNotFound
        }
        guard !manifest.profiles[index].isArchived else {
            throw ViewingProfileStoreError.cannotActivateArchivedProfile
        }
        manifest.activeProfileID = id
        manifest.profiles[index].updatedAt = now
        try persist(manifest)
        return makeSnapshot(manifest)
    }

    /// Removal is recoverable: metadata and the profile data directory are
    /// retained until the profile is explicitly restored.
    @discardableResult
    public func archive(id: UUID, now: Date = Date()) throws -> ViewingProfileSnapshot {
        var manifest = try loadOrRecover(now: now)
        guard let index = manifest.profiles.firstIndex(where: { $0.id == id }) else {
            throw ViewingProfileStoreError.profileNotFound
        }
        guard !manifest.profiles[index].isArchived else {
            return makeSnapshot(manifest)
        }
        let remaining = manifest.profiles.filter { !$0.isArchived && $0.id != id }
        guard !remaining.isEmpty else {
            throw ViewingProfileStoreError.cannotArchiveLastProfile
        }
        manifest.profiles[index].archivedAt = now
        manifest.profiles[index].updatedAt = now
        if manifest.activeProfileID == id {
            manifest.activeProfileID = remaining.sorted(by: Self.profileOrder).first!.id
        }
        try persist(manifest)
        return makeSnapshot(manifest)
    }

    @discardableResult
    public func restore(id: UUID, now: Date = Date()) throws -> ViewingProfileSnapshot {
        try restoreWithCommit(id: id, now: now).snapshot
    }

    @discardableResult
    public func restoreWithCommit(
        id: UUID,
        now: Date = Date()
    ) throws -> ViewingProfileMutationCommit {
        var manifest = try loadOrRecover(now: now)
        guard let index = manifest.profiles.firstIndex(where: { $0.id == id }) else {
            throw ViewingProfileStoreError.profileNotFound
        }
        // Archived names are intentionally reusable. Restoring one must
        // re-enter the same active-name uniqueness boundary as create/update
        // before changing either metadata or durable profile state.
        _ = try validate(
            manifest.profiles[index].name,
            excluding: id,
            in: manifest
        )
        manifest.profiles[index].archivedAt = nil
        manifest.profiles[index].updatedAt = now
        try createDataDirectory(for: id)
        try persist(manifest)
        return ViewingProfileMutationCommit(
            snapshot: makeSnapshot(manifest),
            generation: mutationGeneration
        )
    }

    public func dataDirectoryURL(for profileID: UUID, now: Date = Date()) throws -> URL {
        let manifest = try loadOrRecover(now: now)
        guard manifest.profiles.contains(where: { $0.id == profileID }) else {
            throw ViewingProfileStoreError.profileNotFound
        }
        let result = directoryURL(for: profileID)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    private func loadOrRecover(
        defaultName: String = "My Profile",
        defaultAvatar: ViewingProfileAvatar = .bunny,
        now: Date
    ) throws -> Manifest {
        if let cache { return cache }
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            let decoded: Manifest
            do {
                decoded = try decoder.decode(Manifest.self, from: data)
                guard isStructurallyValid(decoded) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } catch {
                try preserveCorruptManifest()
                return try loadOrRecover(
                    defaultName: defaultName,
                    defaultAvatar: defaultAvatar,
                    now: now
                )
            }
            let repair = repairingActiveNameCollisions(in: decoded, now: now)
            guard isValid(repair.manifest) else {
                try preserveCorruptManifest()
                return try loadOrRecover(
                    defaultName: defaultName,
                    defaultAvatar: defaultAvatar,
                    now: now
                )
            }
            try repair.manifest.profiles.forEach { try createDataDirectory(for: $0.id) }
            if repair.didChange {
                try persist(repair.manifest)
            } else {
                cache = repair.manifest
            }
            return repair.manifest
        }
        let profile = ViewingProfile(
            name: try normalized(defaultName),
            avatar: defaultAvatar,
            createdAt: now
        )
        let created = Manifest(
            schemaVersion: Self.schemaVersion,
            legacyMigrationVersion: 0,
            primaryProfileID: profile.id,
            activeProfileID: profile.id,
            profiles: [profile]
        )
        try createDataDirectory(for: profile.id)
        try persist(created)
        return created
    }

    private func isStructurallyValid(_ manifest: Manifest) -> Bool {
        guard manifest.schemaVersion == Self.schemaVersion,
              !manifest.profiles.isEmpty,
              Set(manifest.profiles.map(\.id)).count == manifest.profiles.count,
              manifest.profiles.contains(where: { $0.id == manifest.primaryProfileID }),
              manifest.profiles.contains(where: {
                  $0.id == manifest.activeProfileID && !$0.isArchived
              }),
              manifest.profiles.contains(where: { !$0.isArchived })
        else { return false }
        return manifest.profiles.allSatisfy {
            let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !name.isEmpty && name.count <= Self.maximumNameLength
        }
    }

    private func isValid(_ manifest: Manifest) -> Bool {
        isStructurallyValid(manifest) && hasUniqueActiveNames(manifest)
    }

    /// Build 34 and earlier could restore an archived profile after its name
    /// had been reused, leaving two active profiles with the same name. Repair
    /// that exact durable state without deleting either profile directory. The
    /// current profile wins its collision; otherwise the most recently created
    /// profile keeps the name and older colliders return to the archive.
    private func repairingActiveNameCollisions(
        in manifest: Manifest,
        now: Date
    ) -> (manifest: Manifest, didChange: Bool) {
        var repaired = manifest
        let candidates = repaired.profiles.indices
            .filter { !repaired.profiles[$0].isArchived }
            .sorted { lhsIndex, rhsIndex in
                let lhs = repaired.profiles[lhsIndex]
                let rhs = repaired.profiles[rhsIndex]
                let lhsIsActive = lhs.id == repaired.activeProfileID
                let rhsIsActive = rhs.id == repaired.activeProfileID
                if lhsIsActive != rhsIsActive { return lhsIsActive }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        var retainedNames: [String] = []
        var didChange = false

        for index in candidates {
            guard let name = try? normalized(repaired.profiles[index].name) else {
                continue
            }
            if retainedNames.contains(where: {
                $0.caseInsensitiveCompare(name) == .orderedSame
            }) {
                repaired.profiles[index].archivedAt = now
                repaired.profiles[index].updatedAt = now
                didChange = true
            } else {
                retainedNames.append(name)
            }
        }
        return (repaired, didChange)
    }

    private func hasUniqueActiveNames(_ manifest: Manifest) -> Bool {
        var names: [String] = []
        for profile in manifest.profiles where !profile.isArchived {
            guard let name = try? normalized(profile.name),
                  !names.contains(where: {
                      $0.caseInsensitiveCompare(name) == .orderedSame
                  })
            else { return false }
            names.append(name)
        }
        return true
    }

    private func validate(
        _ name: String,
        excluding id: UUID?,
        in manifest: Manifest
    ) throws -> String {
        let cleanName = try normalized(name)
        guard !manifest.profiles.contains(where: {
            guard $0.id != id,
                  !$0.isArchived,
                  let existingName = try? normalized($0.name)
            else { return false }
            return existingName.caseInsensitiveCompare(cleanName) == .orderedSame
        }) else { throw ViewingProfileStoreError.duplicateName }
        return cleanName
    }

    private func normalized(_ name: String) throws -> String {
        let cleanName = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !cleanName.isEmpty else { throw ViewingProfileStoreError.emptyName }
        guard cleanName.count <= Self.maximumNameLength else {
            throw ViewingProfileStoreError.nameTooLong(maximum: Self.maximumNameLength)
        }
        return cleanName
    }

    private func migrate(_ files: [ViewingProfileLegacyFile], to profileID: UUID) throws {
        let destinationDirectory = directoryURL(for: profileID)
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )
        for file in files {
            guard isSafe(file.fileName) else {
                throw ViewingProfileStoreError.invalidLegacyFileName
            }
            guard FileManager.default.fileExists(atPath: file.sourceURL.path) else { continue }
            let destination = destinationDirectory.appendingPathComponent(file.fileName)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            let temporary = destinationDirectory.appendingPathComponent(
                ".\(file.fileName).\(UUID().uuidString).migrating"
            )
            do {
                try FileManager.default.copyItem(at: file.sourceURL, to: temporary)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
    }

    private func isSafe(_ fileName: String) -> Bool {
        !fileName.isEmpty && fileName != "." && fileName != ".."
            && URL(fileURLWithPath: fileName).lastPathComponent == fileName
            && !fileName.contains("/") && !fileName.contains("\\")
    }

    private func preserveCorruptManifest() throws {
        let recovery = rootDirectory.appendingPathComponent(
            "viewing-profiles.corrupt-\(UUID().uuidString).json"
        )
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: manifestURL, to: recovery)
        cache = nil
    }

    private func persist(_ manifest: Manifest) throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        cache = manifest
        mutationGeneration += 1
        pendingMutations.removeAll(keepingCapacity: true)
    }

    private func registerMutation(_ manifest: Manifest) -> ViewingProfileMutationPlan {
        let id = UUID()
        pendingMutations[id] = PendingMutation(
            generation: mutationGeneration,
            manifest: manifest
        )
        return ViewingProfileMutationPlan(
            id: id,
            snapshot: makeSnapshot(manifest),
            activeProfileDataDirectoryURL: directoryURL(for: manifest.activeProfileID)
        )
    }

    private func createDataDirectory(for id: UUID) throws {
        try FileManager.default.createDirectory(
            at: directoryURL(for: id),
            withIntermediateDirectories: true
        )
    }

    private func directoryURL(for id: UUID) -> URL {
        profilesDirectoryURL.appendingPathComponent(
            id.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func makeSnapshot(_ manifest: Manifest) -> ViewingProfileSnapshot {
        ViewingProfileSnapshot(
            profiles: manifest.profiles.filter { !$0.isArchived }.sorted(by: Self.profileOrder),
            archivedProfiles: manifest.profiles.filter(\.isArchived).sorted {
                ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
            },
            activeProfileID: manifest.activeProfileID,
            primaryProfileID: manifest.primaryProfileID
        )
    }

    private static func profileOrder(_ lhs: ViewingProfile, _ rhs: ViewingProfile) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
