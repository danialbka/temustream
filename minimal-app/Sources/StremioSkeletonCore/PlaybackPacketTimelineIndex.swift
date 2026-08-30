import Foundation

/// Exact timeline bounds for a packet reservoir whose entries may be removed
/// out of insertion order. Min/max heaps use lazy deletion, keeping boundary
/// queries logarithmic without retaining departed packets in the reported span.
public struct PlaybackPacketTimelineIndex: Sendable {
    public struct Token: Equatable, Hashable, Sendable {
        fileprivate let value: UInt64
    }

    public struct Bounds: Equatable, Sendable {
        public let earliestStart: TimeInterval
        public let latestEnd: TimeInterval

        public var duration: TimeInterval {
            max(latestEnd - earliestStart, 0)
        }
    }

    private struct Entry: Sendable {
        let start: TimeInterval
        let end: TimeInterval
    }

    private struct HeapNode: Sendable {
        let token: Token
        let value: TimeInterval
    }

    private var nextTokenValue: UInt64 = 0
    private var entries: [Token: Entry] = [:]
    private var minimumStartHeap: [HeapNode] = []
    private var maximumEndHeap: [HeapNode] = []

    // Lazy deletion keeps steady-state boundary queries cheap, but a FIFO
    // packet stream rarely exposes stale nodes at the maximum-heap root.
    // Rebuild before those unreachable nodes can grow with movie length.
    private static let heapCompactionFloor = 256

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }
    public var count: Int { entries.count }
    var heapNodeCount: Int { minimumStartHeap.count + maximumEndHeap.count }

    @discardableResult
    public mutating func append(
        start: TimeInterval,
        end: TimeInterval
    ) -> Token {
        nextTokenValue &+= 1
        let token = Token(value: nextTokenValue)
        let safeStart = start.isFinite ? start : 0
        let safeEnd = end.isFinite ? max(end, safeStart) : safeStart
        entries[token] = Entry(start: safeStart, end: safeEnd)
        pushMinimum(HeapNode(token: token, value: safeStart))
        pushMaximum(HeapNode(token: token, value: safeEnd))
        return token
    }

    public mutating func remove(_ token: Token) {
        entries.removeValue(forKey: token)
        compactHeapsIfNeeded()
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        minimumStartHeap.removeAll(keepingCapacity: keepingCapacity)
        maximumEndHeap.removeAll(keepingCapacity: keepingCapacity)
    }

    public var bounds: Bounds? {
        mutating get {
            pruneMinimum()
            pruneMaximum()
            guard let minimum = minimumStartHeap.first?.value,
                  let maximum = maximumEndHeap.first?.value
            else { return nil }
            return Bounds(earliestStart: minimum, latestEnd: maximum)
        }
    }

    public var duration: TimeInterval {
        mutating get { bounds?.duration ?? 0 }
    }

    private mutating func pushMinimum(_ node: HeapNode) {
        minimumStartHeap.append(node)
        var index = minimumStartHeap.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard minimumStartHeap[index].value < minimumStartHeap[parent].value else { break }
            minimumStartHeap.swapAt(index, parent)
            index = parent
        }
    }

    private mutating func pushMaximum(_ node: HeapNode) {
        maximumEndHeap.append(node)
        var index = maximumEndHeap.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard maximumEndHeap[index].value > maximumEndHeap[parent].value else { break }
            maximumEndHeap.swapAt(index, parent)
            index = parent
        }
    }

    private mutating func pruneMinimum() {
        while let node = minimumStartHeap.first,
              entries[node.token]?.start != node.value {
            popMinimum()
        }
    }

    private mutating func pruneMaximum() {
        while let node = maximumEndHeap.first,
              entries[node.token]?.end != node.value {
            popMaximum()
        }
    }

    private mutating func compactHeapsIfNeeded() {
        guard !entries.isEmpty else {
            minimumStartHeap.removeAll(keepingCapacity: true)
            maximumEndHeap.removeAll(keepingCapacity: true)
            return
        }
        let maximumRetainedNodes = max(
            entries.count * 2,
            Self.heapCompactionFloor
        )
        guard minimumStartHeap.count > maximumRetainedNodes
            || maximumEndHeap.count > maximumRetainedNodes
        else { return }

        minimumStartHeap.removeAll(keepingCapacity: true)
        maximumEndHeap.removeAll(keepingCapacity: true)
        minimumStartHeap.reserveCapacity(entries.count)
        maximumEndHeap.reserveCapacity(entries.count)
        for (token, entry) in entries {
            pushMinimum(HeapNode(token: token, value: entry.start))
            pushMaximum(HeapNode(token: token, value: entry.end))
        }
    }

    private mutating func popMinimum() {
        guard !minimumStartHeap.isEmpty else { return }
        minimumStartHeap.swapAt(0, minimumStartHeap.count - 1)
        minimumStartHeap.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            let right = left + 1
            guard left < minimumStartHeap.count else { return }
            let child = right < minimumStartHeap.count
                && minimumStartHeap[right].value < minimumStartHeap[left].value
                ? right
                : left
            guard minimumStartHeap[child].value < minimumStartHeap[index].value else { return }
            minimumStartHeap.swapAt(child, index)
            index = child
        }
    }

    private mutating func popMaximum() {
        guard !maximumEndHeap.isEmpty else { return }
        maximumEndHeap.swapAt(0, maximumEndHeap.count - 1)
        maximumEndHeap.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            let right = left + 1
            guard left < maximumEndHeap.count else { return }
            let child = right < maximumEndHeap.count
                && maximumEndHeap[right].value > maximumEndHeap[left].value
                ? right
                : left
            guard maximumEndHeap[child].value > maximumEndHeap[index].value else { return }
            maximumEndHeap.swapAt(child, index)
            index = child
        }
    }
}
