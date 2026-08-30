import Foundation

public enum PlaybackSeekOutcome: Equatable, Sendable {
    case completed
    case failed
    case timedOut
    case superseded
    case cancelled
}

public struct PlaybackSeekRequest: Equatable, Hashable, Sendable {
    public let id: UInt64
    public let target: TimeInterval

    public init(id: UInt64, target: TimeInterval) {
        self.id = id
        self.target = target
    }
}

/// Owns the lifecycle of one decoder seek at a time.
///
/// Decoder callbacks carry the request identifier all the way back to this
/// coordinator, so a late completion can never satisfy a newer request that
/// happens to use the same target. Every request receives exactly one terminal
/// outcome, including cancellation and a bounded timeout.
public actor PlaybackSeekCoordinator {
    private var nextRequestID: UInt64 = 0
    private var activeRequest: PlaybackSeekRequest?
    private var activeWaiter: CheckedContinuation<PlaybackSeekOutcome, Never>?
    private var activeTimeoutTask: Task<Void, Never>?
    private var resolvedOutcomes: [UInt64: PlaybackSeekOutcome] = [:]

    public init() {}

    public func begin(
        requestID: UInt64? = nil,
        target: TimeInterval
    ) -> PlaybackSeekRequest {
        let resolvedRequestID = requestID ?? (nextRequestID &+ 1)
        let request = PlaybackSeekRequest(
            id: resolvedRequestID,
            target: target.isFinite ? max(target, 0) : 0
        )
        guard resolvedRequestID > nextRequestID else { return request }
        if let activeRequest {
            resolve(requestID: activeRequest.id, outcome: .superseded)
        }
        nextRequestID = resolvedRequestID
        activeRequest = request
        return request
    }

    public func wait(
        for request: PlaybackSeekRequest,
        timeout: TimeInterval
    ) async -> PlaybackSeekOutcome {
        if let resolved = resolvedOutcomes.removeValue(forKey: request.id) {
            return resolved
        }
        guard activeRequest?.id == request.id else { return .superseded }
        guard !Task.isCancelled else {
            resolve(requestID: request.id, outcome: .cancelled)
            return resolvedOutcomes.removeValue(forKey: request.id) ?? .cancelled
        }
        guard timeout.isFinite, timeout > 0 else {
            resolve(requestID: request.id, outcome: .timedOut)
            return resolvedOutcomes.removeValue(forKey: request.id) ?? .timedOut
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard activeRequest?.id == request.id else {
                    continuation.resume(
                        returning: resolvedOutcomes.removeValue(forKey: request.id)
                            ?? .superseded
                    )
                    return
                }
                activeWaiter = continuation
                let nanoseconds = Self.nanoseconds(for: timeout)
                activeTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    await self?.timeout(requestID: request.id)
                }
            }
        } onCancel: {
            Task { await self.cancel(requestID: request.id) }
        }
    }

    public func complete(
        requestID: UInt64,
        target: TimeInterval,
        succeeded: Bool,
        targetTolerance: TimeInterval = 0.01
    ) {
        guard let activeRequest,
              activeRequest.id == requestID,
              target.isFinite,
              abs(activeRequest.target - target) <= max(targetTolerance, 0)
        else { return }
        resolve(
            requestID: requestID,
            outcome: succeeded ? .completed : .failed
        )
    }

    public func cancelAll() {
        guard let activeRequest else { return }
        resolve(requestID: activeRequest.id, outcome: .cancelled)
    }

    /// Releases a request whose caller learned it was obsolete before it
    /// reached `wait`. This prevents supersession races from retaining one
    /// resolved outcome per abandoned scrub gesture.
    public func discard(_ request: PlaybackSeekRequest) {
        if activeRequest?.id == request.id {
            resolve(requestID: request.id, outcome: .cancelled)
        }
        resolvedOutcomes.removeValue(forKey: request.id)
    }

    private func timeout(requestID: UInt64) {
        resolve(requestID: requestID, outcome: .timedOut)
    }

    private func cancel(requestID: UInt64) {
        resolve(requestID: requestID, outcome: .cancelled)
    }

    private func resolve(requestID: UInt64, outcome: PlaybackSeekOutcome) {
        guard activeRequest?.id == requestID else { return }
        activeTimeoutTask?.cancel()
        activeTimeoutTask = nil
        activeRequest = nil
        if let waiter = activeWaiter {
            activeWaiter = nil
            waiter.resume(returning: outcome)
        } else {
            resolvedOutcomes[requestID] = outcome
        }
    }

    private static func nanoseconds(for timeout: TimeInterval) -> UInt64 {
        let bounded = min(max(timeout, 0), TimeInterval(UInt64.max) / 1_000_000_000)
        return UInt64((bounded * 1_000_000_000).rounded(.up))
    }
}
