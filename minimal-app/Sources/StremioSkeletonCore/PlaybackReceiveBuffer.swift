import Foundation

/// Owns bytes received for one network operation.
///
/// Successful operations transfer their storage with `take()`. Failed or
/// cancelled operations call `discard()` so a reusable fetch object cannot
/// accidentally retain a large response buffer between requests.
struct PlaybackReceiveBuffer: Sendable {
    private var storage = Data()

    var count: Int {
        storage.count
    }

    mutating func reset() {
        storage = Data()
    }

    mutating func append(_ data: Data, maximumCount: Int) {
        let remaining = max(maximumCount - storage.count, 0)
        guard remaining > 0 else { return }
        storage.append(data.prefix(remaining))
    }

    func copy(
        relativeOffset: Int,
        to output: UnsafeMutablePointer<UInt8>,
        maximumLength: Int
    ) -> Int? {
        guard relativeOffset >= 0,
              relativeOffset < storage.count,
              maximumLength > 0
        else { return nil }
        let count = min(maximumLength, storage.count - relativeOffset)
        storage.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            output.update(
                from: base.advanced(by: relativeOffset).assumingMemoryBound(to: UInt8.self),
                count: count
            )
        }
        return count
    }

    mutating func take() -> Data {
        let result = storage
        storage = Data()
        return result
    }

    @discardableResult
    mutating func discard() -> Int {
        let discardedCount = storage.count
        storage = Data()
        return discardedCount
    }
}
