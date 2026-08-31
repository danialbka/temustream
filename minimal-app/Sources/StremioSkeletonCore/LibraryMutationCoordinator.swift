import Foundation

/// Serializes local library state with its account mutation. Signed-in changes
/// are pushed first, so a failed request leaves local state unchanged and a
/// retry derives the same intent. Full snapshot sync uses the same gate and
/// cannot overtake an in-flight toggle.
public actor LibraryMutationCoordinator {
    public typealias RemoteMutation = @Sendable (Bool) async throws -> Void
    public typealias RemoteSnapshot = @Sendable () async throws -> [RemoteLibraryItem]

    private let gate = AsyncSerialGate()

    public init() {}

    @discardableResult
    public func toggle(
        _ item: MetaItem,
        store: LibraryStore,
        remoteMutation: RemoteMutation? = nil
    ) async throws -> [MetaItem] {
        await gate.enter()
        do {
            let current = try await store.items()
            let removing = current.contains {
                $0.id == item.id && $0.type == item.type
            }
            if let remoteMutation {
                try await remoteMutation(removing)
            }
            let updated = try await store.toggle(item)
            await gate.leave()
            return updated
        } catch {
            await gate.leave()
            throw error
        }
    }

    @discardableResult
    public func synchronize(
        store: LibraryStore,
        remoteSnapshot: @escaping RemoteSnapshot
    ) async throws -> [MetaItem] {
        await gate.enter()
        do {
            let remote = try await remoteSnapshot()
            let updated = try await store.replaceWithRemoteSnapshot(remote)
            await gate.leave()
            return updated
        } catch {
            await gate.leave()
            throw error
        }
    }
}
