import Foundation
import XCTest
@testable import StremioSkeletonCore

final class StreamIdentityTests: XCTestCase {
    func testTorrentFilesWithSameInfoHashHaveDistinctIDs() throws {
        let first = try JSONDecoder().decode(
            Stream.self,
            from: Data(#"{"infoHash":"abc123","fileIdx":0,"name":"Torrent"}"#.utf8)
        )
        let second = try JSONDecoder().decode(
            Stream.self,
            from: Data(#"{"infoHash":"abc123","fileIdx":1,"name":"Torrent"}"#.utf8)
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.id.contains("|0|"))
        XCTAssertTrue(second.id.contains("|1|"))
    }
}
