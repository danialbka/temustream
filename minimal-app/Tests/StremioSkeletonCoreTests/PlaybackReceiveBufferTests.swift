import Foundation
import XCTest
@testable import StremioSkeletonCore

final class PlaybackReceiveBufferTests: XCTestCase {
    func testTakeTransfersBytesAndReleasesReusableStorage() {
        var buffer = PlaybackReceiveBuffer()
        buffer.append(Data([1, 2]), maximumCount: 4)
        buffer.append(Data([3, 4, 5]), maximumCount: 4)

        let result = buffer.take()

        XCTAssertEqual(result, Data([1, 2, 3, 4]))
        XCTAssertEqual(buffer.count, 0)
    }

    func testDiscardReleasesCancelledOperationBytes() {
        var buffer = PlaybackReceiveBuffer()
        buffer.append(Data(repeating: 0x7f, count: 8 * 1_024 * 1_024), maximumCount: 8 * 1_024 * 1_024)

        XCTAssertEqual(buffer.discard(), 8 * 1_024 * 1_024)
        XCTAssertEqual(buffer.count, 0)

        buffer.append(Data([9]), maximumCount: 1)
        XCTAssertEqual(buffer.take(), Data([9]))
    }
}
