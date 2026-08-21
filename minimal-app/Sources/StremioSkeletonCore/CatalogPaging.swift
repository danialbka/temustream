import Foundation

/// Accumulates add-on catalog pages without repeatedly scanning the full result list.
/// `nextSkip` follows the protocol response size because add-ons use different page sizes.
public struct CatalogPageAccumulator: Sendable {
    public private(set) var items: [MetaItem] = []
    public private(set) var nextSkip = 0
    public private(set) var canLoadMore = true

    private var itemKeys = Set<CatalogItemKey>()

    public init() {}

    public mutating func reset() {
        items.removeAll(keepingCapacity: true)
        itemKeys.removeAll(keepingCapacity: true)
        nextSkip = 0
        canLoadMore = true
    }

    @discardableResult
    public mutating func append(_ page: [MetaItem], supportsSkip: Bool) -> Int {
        let previousCount = items.count
        nextSkip += page.count

        for item in page {
            if itemKeys.insert(CatalogItemKey(item)).inserted {
                items.append(item)
            }
        }

        let addedCount = items.count - previousCount
        canLoadMore = supportsSkip && !page.isEmpty && addedCount > 0
        return addedCount
    }
}

private struct CatalogItemKey: Hashable, Sendable {
    let type: String
    let id: String

    init(_ item: MetaItem) {
        type = item.type
        id = item.id
    }
}
