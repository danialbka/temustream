import Foundation

/// Serializes the Stremio add-on collection's read-modify-write operations.
/// The account API replaces the complete collection, so overlapping pushes
/// must not be allowed to finish out of order or build from a stale snapshot.
public actor StremioAddonSyncCoordinator {
    private let client: StremioAccountClient
    private var operationTail: Task<Void, Never>?

    public init(client: StremioAccountClient) {
        self.client = client
    }

    public func snapshot(authKey: String) async throws -> [SyncedAddon] {
        try await enqueue { client in
            try await client.pullAddons(authKey: authKey)
        }
    }

    public func install(
        _ addon: SyncedAddon,
        authKey: String
    ) async throws -> [SyncedAddon] {
        try await enqueue { client in
            var remote = try await client.pullAddons(authKey: authKey)
            remote.removeAll { $0.transportUrl == addon.transportUrl }
            remote.append(addon)
            try await client.pushAddons(authKey: authKey, addons: remote)
            return remote
        }
    }

    public func remove(
        transportURL: URL,
        authKey: String
    ) async throws -> [SyncedAddon] {
        try await enqueue { client in
            var remote = try await client.pullAddons(authKey: authKey)
            remote.removeAll { $0.transportUrl == transportURL }
            try await client.pushAddons(authKey: authKey, addons: remote)
            return remote
        }
    }

    private func enqueue(
        _ operation: @escaping @Sendable (StremioAccountClient) async throws -> [SyncedAddon]
    ) async throws -> [SyncedAddon] {
        let predecessor = operationTail
        let client = self.client
        let task = Task<[SyncedAddon], Error> {
            await predecessor?.value
            return try await operation(client)
        }
        operationTail = Task<Void, Never> {
            _ = try? await task.value
        }
        return try await task.value
    }
}
