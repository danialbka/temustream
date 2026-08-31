import Foundation

public struct LatestOperationToken: Hashable, Sendable {
    fileprivate let identifier: UUID
}

/// A small value-type ownership gate for re-entrant actor operations. Callers
/// mint a token before their first suspension and may publish only while that
/// token remains current.
public struct LatestOperationOwner: Sendable {
    private var current: LatestOperationToken?

    public init() {}

    @discardableResult
    public mutating func begin() -> LatestOperationToken {
        let token = LatestOperationToken(identifier: UUID())
        current = token
        return token
    }

    public func owns(_ token: LatestOperationToken) -> Bool {
        current == token
    }

    public mutating func invalidate() {
        current = nil
    }
}
