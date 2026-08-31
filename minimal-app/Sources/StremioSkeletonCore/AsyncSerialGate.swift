import Foundation

/// A fair async mutex for transactions that must remain ordered across await
/// points. Actor isolation alone is reentrant and does not provide this.
public actor AsyncSerialGate {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func enter() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    public func leave() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Reuses the one live actor-backed store for each canonical file path. App
/// models can rebuild and preload profile state without creating a second
/// cache owner while an older unstructured write is still in flight. Weak
/// entries let inactive profiles release their cached state once no work owns
/// the store anymore.
@MainActor
public final class FileBackedStoreRegistry<Store: AnyObject & Sendable> {
    private final class WeakStore {
        weak var value: Store?

        init(_ value: Store) {
            self.value = value
        }
    }

    private var stores: [String: WeakStore] = [:]

    public init() {}

    public func store(
        for fileURL: URL,
        create: () -> Store
    ) -> Store {
        let key = fileURL.standardizedFileURL.path
        if let existing = stores[key]?.value {
            return existing
        }
        let created = create()
        stores[key] = WeakStore(created)
        return created
    }
}
