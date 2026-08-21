import XCTest
@testable import StremioSkeletonCore

final class CatalogPagingTests: XCTestCase {
    func testAppendsPagesAndAdvancesByActualResponseCount() {
        var paging = CatalogPageAccumulator()

        XCTAssertEqual(paging.append(items(0..<50), supportsSkip: true), 50)
        XCTAssertEqual(paging.nextSkip, 50)
        XCTAssertTrue(paging.canLoadMore)

        XCTAssertEqual(paging.append(items(50..<150), supportsSkip: true), 100)
        XCTAssertEqual(paging.nextSkip, 150)
        XCTAssertEqual(paging.items.count, 150)
    }

    func testStopsWhenProviderRepeatsAPage() {
        var paging = CatalogPageAccumulator()
        let firstPage = items(0..<100)
        paging.append(firstPage, supportsSkip: true)

        XCTAssertEqual(paging.append(firstPage, supportsSkip: true), 0)
        XCTAssertEqual(paging.items.count, 100)
        XCTAssertFalse(paging.canLoadMore)
    }

    func testStopsWhenPaginationIsUnsupportedOrEmpty() {
        var paging = CatalogPageAccumulator()
        paging.append(items(0..<2), supportsSkip: false)
        XCTAssertFalse(paging.canLoadMore)

        paging.reset()
        paging.append([], supportsSkip: true)
        XCTAssertFalse(paging.canLoadMore)
        XCTAssertEqual(paging.nextSkip, 0)
    }

    private func items(_ range: Range<Int>) -> [MetaItem] {
        range.map { MetaItem(id: "tt\($0)", type: "movie", name: "Movie \($0)") }
    }
}
