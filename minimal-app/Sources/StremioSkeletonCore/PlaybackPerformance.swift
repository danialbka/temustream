import Foundation

/// Count-bounded, time-bounded LRU cache suitable for catalog and detail
/// responses. It deliberately has no networking or URL persistence behavior.
public struct BoundedCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var expiresAt: Date
        var accessOrder: UInt64
    }

    public let capacity: Int
    public let timeToLive: TimeInterval
    private var entries: [Key: Entry] = [:]
    private var nextAccessOrder: UInt64 = 0

    public init(capacity: Int, timeToLive: TimeInterval) {
        self.capacity = max(capacity, 1)
        self.timeToLive = max(timeToLive, 0)
    }

    public var count: Int { entries.count }

    public mutating func value(forKey key: Key, now: Date = Date()) -> Value? {
        removeExpired(now: now)
        guard var entry = entries[key] else { return nil }
        entry.accessOrder = nextOrder()
        entries[key] = entry
        return entry.value
    }

    public mutating func insert(_ value: Value, forKey key: Key, now: Date = Date()) {
        removeExpired(now: now)
        entries[key] = Entry(
            value: value,
            expiresAt: now.addingTimeInterval(timeToLive),
            accessOrder: nextOrder()
        )
        trimToCapacity()
    }

    @discardableResult
    public mutating func removeValue(forKey key: Key) -> Value? {
        entries.removeValue(forKey: key)?.value
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }

    public mutating func removeExpired(now: Date = Date()) {
        entries = entries.filter { timeToLive == 0 || $0.value.expiresAt > now }
    }

    private mutating func nextOrder() -> UInt64 {
        nextAccessOrder &+= 1
        return nextAccessOrder
    }

    private mutating func trimToCapacity() {
        guard entries.count > capacity else { return }
        let overflow = entries.count - capacity
        let oldest = entries
            .sorted { $0.value.accessOrder < $1.value.accessOrder }
            .prefix(overflow)
            .map(\.key)
        for key in oldest { entries.removeValue(forKey: key) }
    }
}

/// Coalesces identical async loads so SwiftUI rerenders do not restart the same
/// catalog/detail request. Callers choose separate gates per response type.
public actor InFlightRequestGate<Key: Hashable & Sendable, Value: Sendable> {
    private struct Entry {
        let id: UUID
        let task: Task<Value, Error>
    }

    private var tasks: [Key: Entry] = [:]

    public init() {}

    public func run(
        key: Key,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let entry = tasks[key] { return try await entry.task.value }
        let id = UUID()
        let task = Task { try await operation() }
        tasks[key] = Entry(id: id, task: task)
        defer {
            // A cancelled request can finish after a replacement has already
            // been installed for the same key. Never let the old waiter erase
            // that newer in-flight operation.
            if tasks[key]?.id == id { tasks[key] = nil }
        }
        return try await task.value
    }

    public func cancel(key: Key) {
        tasks.removeValue(forKey: key)?.task.cancel()
    }

    public func cancelAll() {
        for entry in tasks.values { entry.task.cancel() }
        tasks.removeAll()
    }

    public var activeRequestCount: Int { tasks.count }
}

/// Pure index policy used by a view-owned prefetcher. It does not fetch or
/// retain artwork itself, so the caller remains in control of cancellation.
public enum NearViewportPrefetchPolicy {
    public static func indices(
        visibleRange: Range<Int>,
        itemCount: Int,
        lookBehind: Int = 2,
        lookAhead: Int = 6
    ) -> [Int] {
        guard itemCount > 0, !visibleRange.isEmpty else { return [] }
        let lower = max(visibleRange.lowerBound - max(lookBehind, 0), 0)
        let upper = min(visibleRange.upperBound + max(lookAhead, 0), itemCount)
        guard lower < upper else { return [] }
        return Array(lower..<upper)
    }
}

public enum PerformanceFlow: String, Sendable {
    case catalog
    case detail
    case playback
}

public enum PerformanceMilestone: String, CaseIterable, Sendable {
    case catalogReady = "catalog_ready"
    case detailReady = "detail_ready"
    case streamResolved = "stream_resolved"
    case firstVisibleFrame = "first_visible_frame"
}

public struct PerformanceTraceID: Hashable, Sendable {
    fileprivate let value: UUID

    public init() { value = UUID() }
}

public struct PerformanceTraceSnapshot: Equatable, Sendable {
    public let id: PerformanceTraceID
    public let flow: PerformanceFlow
    public let identity: String
    public let startedAt: TimeInterval
    public let milestones: [PerformanceMilestone: TimeInterval]

    public func elapsedMilliseconds(to milestone: PerformanceMilestone) -> Double? {
        milestones[milestone].map { max(($0 - startedAt) * 1_000, 0) }
    }
}

/// UIKit-free, bounded timing recorder shared by catalog, detail and playback.
/// Repeated marks are idempotent, keeping first-frame timings honest.
public final class PerformanceMilestoneRecorder: @unchecked Sendable {
    public static let shared = PerformanceMilestoneRecorder()

    private struct Trace {
        let id: PerformanceTraceID
        let flow: PerformanceFlow
        let identity: String
        let startedAt: TimeInterval
        var milestones: [PerformanceMilestone: TimeInterval]
    }

    private let capacity: Int
    private let lock = NSLock()
    private var traces: [PerformanceTraceID: Trace] = [:]
    private var order: [PerformanceTraceID] = []

    public init(capacity: Int = 128) {
        self.capacity = max(capacity, 1)
    }

    @discardableResult
    public func begin(
        flow: PerformanceFlow,
        identity: String,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> PerformanceTraceID {
        let id = PerformanceTraceID()
        withLock {
            traces[id] = Trace(
                id: id,
                flow: flow,
                identity: identity,
                startedAt: timestamp,
                milestones: [:]
            )
            order.append(id)
            trimToCapacity()
        }
        return id
    }

    @discardableResult
    public func mark(
        _ milestone: PerformanceMilestone,
        for id: PerformanceTraceID,
        at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Double? {
        withLock {
            guard var trace = traces[id] else { return nil }
            if trace.milestones[milestone] == nil {
                trace.milestones[milestone] = timestamp
                traces[id] = trace
            }
            return trace.milestones[milestone].map {
                max(($0 - trace.startedAt) * 1_000, 0)
            }
        }
    }

    public func snapshot(for id: PerformanceTraceID) -> PerformanceTraceSnapshot? {
        withLock {
            traces[id].map {
                PerformanceTraceSnapshot(
                    id: $0.id,
                    flow: $0.flow,
                    identity: $0.identity,
                    startedAt: $0.startedAt,
                    milestones: $0.milestones
                )
            }
        }
    }

    public func recentSnapshots() -> [PerformanceTraceSnapshot] {
        withLock {
            order.compactMap { id in
                traces[id].map {
                    PerformanceTraceSnapshot(
                        id: $0.id,
                        flow: $0.flow,
                        identity: $0.identity,
                        startedAt: $0.startedAt,
                        milestones: $0.milestones
                    )
                }
            }
        }
    }

    public func removeAll() {
        withLock {
            traces.removeAll()
            order.removeAll()
        }
    }

    private func trimToCapacity() {
        guard order.count > capacity else { return }
        let overflow = order.count - capacity
        for id in order.prefix(overflow) { traces.removeValue(forKey: id) }
        order.removeFirst(overflow)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
