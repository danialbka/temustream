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
        }
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
        var manifest = try loadOrRecover(now: now)
        guard let index = manifest.profiles.firstIndex(where: { $0.id == id }) else {
            throw ViewingProfileStoreError.profileNotFound
        }
        manifest.profiles[index].name = try validate(name, excluding: id, in: manifest)
        manifest.profiles[index].avatar = avatar
        manifest.profiles[index].updatedAt = now
        try persist(manifest)
        return makeSnapshot(manifest)
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
        var manifest = try loadOrRecover(now: now)
        guard let index = manifest.profiles.firstIndex(where: { $0.id == id }) else {
            throw ViewingProfileStoreError.profileNotFound
        }
        manifest.profiles[index].archivedAt = nil
        manifest.profiles[index].updatedAt = now
        try createDataDirectory(for: id)
        try persist(manifest)
        return makeSnapshot(manifest)
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
            do {
                let decoded = try decoder.decode(
                    Manifest.self,
                    from: Data(contentsOf: manifestURL)
                )
                guard isValid(decoded) else { throw CocoaError(.fileReadCorruptFile) }
                try decoded.profiles.forEach { try createDataDirectory(for: $0.id) }
                cache = decoded
                return decoded
            } catch {
                try preserveCorruptManifest()
            }
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

    private func isValid(_ manifest: Manifest) -> Bool {
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

    private func validate(
        _ name: String,
        excluding id: UUID?,
        in manifest: Manifest
    ) throws -> String {
        let cleanName = try normalized(name)
        guard !manifest.profiles.contains(where: {
            $0.id != id && !$0.isArchived
                && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
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
