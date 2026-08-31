import Foundation

public actor LibraryStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cache: [MetaItem]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    public func items() throws -> [MetaItem] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cache = []
            return []
        }
        let data = try Data(contentsOf: fileURL)
        do {
            let decoded = try decoder.decode([MetaItem].self, from: data)
            cache = decoded
            return decoded
        } catch {
            try LocalPreferenceRecovery.preserveCorruptFile(fileURL)
            try persist([])
            return []
        }
    }

    @discardableResult
    public func toggle(_ item: MetaItem) throws -> [MetaItem] {
        var current = try items()
        if let index = current.firstIndex(where: { $0.id == item.id && $0.type == item.type }) {
            current.remove(at: index)
        } else {
            current.insert(item, at: 0)
        }
        try persist(current)
        return current
    }

    public func contains(_ item: MetaItem) throws -> Bool {
        try items().contains { $0.id == item.id && $0.type == item.type }
    }

    @discardableResult
    public func merge(_ incoming: [MetaItem]) throws -> [MetaItem] {
        var merged = try items()
        for item in incoming.reversed() {
            merged.removeAll { $0.id == item.id && $0.type == item.type }
            merged.insert(item, at: 0)
        }
        try persist(merged)
        return merged
    }

    @discardableResult
    public func applyRemote(_ incoming: [RemoteLibraryItem]) throws -> [MetaItem] {
        var merged = try items()
        for remote in incoming.reversed() {
            merged.removeAll { $0.id == remote.id && $0.type == remote.type }
            if !remote.removed { merged.insert(remote.metaItem, at: 0) }
        }
        try persist(merged)
        return merged
    }

    /// Replaces this store with a complete account snapshot returned by
    /// `datastoreGet(all: true)`. Anonymous or other-account items must not be
    /// merged into that snapshot.
    @discardableResult
    public func replaceWithRemoteSnapshot(
        _ incoming: [RemoteLibraryItem]
    ) throws -> [MetaItem] {
        var seen = Set<String>()
        let snapshot = incoming.compactMap { remote -> MetaItem? in
            guard !remote.removed,
                  seen.insert("\(remote.type)|\(remote.id)").inserted
            else { return nil }
            return remote.metaItem
        }
        try persist(snapshot)
        return snapshot
    }

    private func persist(_ items: [MetaItem]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(items).write(to: fileURL, options: .atomic)
        cache = items
    }
}
