import XCTest
@testable import StremioSkeletonCore

final class PlaybackDynamicRangeDiagnosticsTests: XCTestCase {
    func testWaitsForDecodedOutputBeforeClaimingDynamicRange() {
        XCTAssertEqual(
            PlaybackDynamicRangeDiagnostics.classify(
                inputBitsPerChannel: 10,
                inputTransferCharacteristics: 16
            ),
            .detecting
        )
    }

    func testDolbyVisionConfigurationTakesPriorityOverPQBaseLayer() {
        XCTAssertEqual(
            PlaybackDynamicRangeDiagnostics.classify(
                inputBitsPerChannel: 10,
                inputTransferCharacteristics: 16,
                inputDolbyVisionConfiguration: "dvvC",
                outputPixelFormat: "x420",
                outputTransferFunction: "SMPTE_ST_2084_PQ"
            ),
            .dolbyVision
        )
    }

    func testClassifiesDecodedPQAsHDR10() {
        XCTAssertEqual(
            PlaybackDynamicRangeDiagnostics.classify(
                outputPixelFormat: "x420",
                outputColorPrimaries: "ITU_R_2020",
                outputTransferFunction: "SMPTE_ST_2084_PQ"
            ),
            .hdr10
        )
    }

    func testClassifiesDecodedHLG() {
        XCTAssertEqual(
            PlaybackDynamicRangeDiagnostics.classify(
                outputPixelFormat: "x420",
                outputColorPrimaries: "ITU_R_2020",
                outputTransferFunction: "ITU_R_2100_HLG"
            ),
            .hlg
        )
    }

    func testUsesInputTransferWhenDecoderOmitsOutputTransferString() {
        XCTAssertEqual(
            PlaybackDynamicRangeDiagnostics.classify(
                inputTransferCharacteristics: 16,
                outputPixelFormat: "x420"
            ),
            .hdr10
        )
        XCTAssertEqual(
            PlaybackDynamicRangeDiagnostics.classify(
                inputTransferCharacteristics: 18,
                outputPixelFormat: "x420"
            ),
            .hlg
        )
    }

    func testTenBitAloneDoesNotClaimHDR() {
        XCTAssertEqual(
            PlaybackDynamicRangeDiagnostics.classify(
                inputBitsPerChannel: 10,
                outputPixelFormat: "x420",
                outputTransferFunction: "ITU_R_709_2"
            ),
            .sdr
        )
    }

    func testMasteringMetadataProvidesHDR10Fallback() {
        XCTAssertEqual(
            PlaybackDynamicRangeDiagnostics.classify(
                inputBitsPerChannel: 10,
                inputHasMasteringMetadata: true,
                outputPixelFormat: "x420"
            ),
            .hdr10
        )
    }
}
