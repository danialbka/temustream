import Foundation

public enum PlaybackDynamicRange: String, Codable, Equatable, Sendable {
    case detecting
    case sdr
    case hdr10
    case hlg
    case dolbyVision
    case systemManaged

    public var displayName: String {
        switch self {
        case .detecting:
            "Detecting…"
        case .sdr:
            "SDR"
        case .hdr10:
            "HDR10"
        case .hlg:
            "HLG"
        case .dolbyVision:
            "Dolby Vision"
        case .systemManaged:
            "Apple managed"
        }
    }

    public var logValue: String {
        switch self {
        case .detecting:
            "detecting"
        case .sdr:
            "sdr"
        case .hdr10:
            "hdr10"
        case .hlg:
            "hlg"
        case .dolbyVision:
            "dolby_vision"
        case .systemManaged:
            "apple_managed"
        }
    }
}

/// Classifies decoded video using container colour metadata and the metadata
/// attached to VideoToolbox output. Stream names are deliberately ignored:
/// labels such as "10-bit" do not by themselves establish HDR playback.
public enum PlaybackDynamicRangeDiagnostics {
    public static func classify(
        inputBitsPerChannel: UInt32? = nil,
        inputTransferCharacteristics: UInt32? = nil,
        inputHasMasteringMetadata: Bool = false,
        inputHasContentLightLevel: Bool = false,
        inputDolbyVisionConfiguration: String? = nil,
        outputPixelFormat: String? = nil,
        outputColorPrimaries: String? = nil,
        outputTransferFunction: String? = nil
    ) -> PlaybackDynamicRange {
        let hasDecodedOutput = nonEmpty(outputPixelFormat) != nil
            || nonEmpty(outputColorPrimaries) != nil
            || nonEmpty(outputTransferFunction) != nil
        guard hasDecodedOutput else { return .detecting }

        if nonEmpty(inputDolbyVisionConfiguration) != nil {
            return .dolbyVision
        }

        let transfer = normalized(outputTransferFunction)
        if transfer.contains("HLG") {
            return .hlg
        }
        if transfer.contains("2084") || transfer.contains("PQ") {
            return .hdr10
        }

        // ISO/IEC 23091-2 transfer-characteristic code points used by
        // Matroska: 16 is SMPTE ST 2084 (PQ), and 18 is ARIB STD-B67 (HLG).
        switch inputTransferCharacteristics {
        case 16:
            return .hdr10
        case 18:
            return .hlg
        default:
            break
        }

        // Mastering-display or content-light metadata on a decoded 10-bit
        // stream is a useful HDR10 fallback for files with incomplete transfer
        // tagging. A 10-bit pixel format alone remains SDR.
        if (inputHasMasteringMetadata || inputHasContentLightLevel),
           (inputBitsPerChannel ?? 0) >= 10 {
            return .hdr10
        }

        return .sdr
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.lowercased() != "none"
        else { return nil }
        return value
    }

    private static func normalized(_ value: String?) -> String {
        nonEmpty(value)?.uppercased() ?? ""
    }
}
