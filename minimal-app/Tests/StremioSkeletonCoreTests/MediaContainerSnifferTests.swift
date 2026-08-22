import XCTest
@testable import StremioSkeletonCore

final class MediaContainerSnifferTests: XCTestCase {
    func testDetectsMPEGTransportStreamAheadOfMisleadingServerMIME() {
        var signature = Data(repeating: 0, count: 377)
        signature[0] = 0x47
        signature[188] = 0x47
        signature[376] = 0x47

        XCTAssertEqual(
            MediaContainerSniffer.detectedMIMEType(
                signature: signature,
                serverMIMEType: "video/mp4"
            ),
            "video/mp2t"
        )
    }

    func testDetectsMP4FileTypeBox() {
        var signature = Data(repeating: 0, count: 12)
        signature.replaceSubrange(4..<8, with: Data("ftyp".utf8))
        XCTAssertEqual(
            MediaContainerSniffer.detectedMIMEType(
                signature: signature,
                serverMIMEType: "application/octet-stream"
            ),
            "video/mp4"
        )
    }
}
