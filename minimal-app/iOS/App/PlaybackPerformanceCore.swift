import Foundation

enum PerformanceDecoder: UInt32, Sendable {
    case automatic = 0
    case avFoundation = 1
    case bunnyRust = 2
}

struct PlaybackPerformancePolicy: Sendable {
    let decoder: PerformanceDecoder
    let networkCacheMilliseconds: Int
    let forwardBufferSeconds: TimeInterval
    let maximumBufferSeconds: TimeInterval
    let prefersCompatibilityStream: Bool
    let usesBoundedRenderer: Bool
    let requiresHardwareDecode: Bool
    let prefersVideoToolboxChain: Bool
    let mpegTSByteSeekResolver: (@Sendable (
        TimeInterval,
        TimeInterval
    ) async -> Int64?)?
}

enum PlaybackPerformanceCore {
    struct MPEGTransportTiming: Sendable {
        let pcrPID: UInt16
        let firstPCRTicks: UInt64
        let lastPCRTicks: UInt64
        let firstByteOffset: UInt64
        let lastByteOffset: UInt64
        let bitrateBPS: UInt64
    }

    static func mpegTransportTiming(in data: Data) -> MPEGTransportTiming? {
        let raw = data.withUnsafeBytes { buffer in
            stremio_mpegts_timing(
                buffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                buffer.count
            )
        }
        precondition(raw.abi_version == 1, "Unsupported Rust transport-timing ABI")
        guard raw.has_timing != 0 else { return nil }
        return MPEGTransportTiming(
            pcrPID: raw.pcr_pid,
            firstPCRTicks: raw.first_pcr_ticks,
            lastPCRTicks: raw.last_pcr_ticks,
            firstByteOffset: raw.first_byte_offset,
            lastByteOffset: raw.last_byte_offset,
            bitrateBPS: raw.bitrate_bps
        )
    }

    static func estimatedMPEGTSBitrateBPS(in data: Data) -> UInt64? {
        mpegTransportTiming(in: data)?.bitrateBPS
    }

    static func policy(
        url: URL,
        title: String,
        player: StremioInternalPlayer
    ) -> PlaybackPerformancePolicy {
        let playerKind: UInt32 = switch player {
        case .bunny: 4
        }
        let raw = url.absoluteString.withCString { urlPointer in
            title.withCString { titlePointer in
                stremio_playback_policy(urlPointer, titlePointer, playerKind)
            }
        }
        precondition(raw.abi_version == 1, "Unsupported Rust playback-core ABI")
        let isLoopbackTransportBridge = url.host == "127.0.0.1"
            && url.path.hasPrefix("/stream/")
            && url.path.hasSuffix("/media.ts")
        let mpegTSByteSeekResolver: (@Sendable (
            TimeInterval,
            TimeInterval
        ) async -> Int64?)?
        if isLoopbackTransportBridge {
            mpegTSByteSeekResolver = { @Sendable time, duration in
                await StreamTransportBridge.shared.resolvedByteOffset(
                    for: url,
                    time: time,
                    duration: duration
                )
            }
        } else {
            mpegTSByteSeekResolver = nil
        }
        let policy = PlaybackPerformancePolicy(
            decoder: PerformanceDecoder(rawValue: raw.decoder_kind) ?? .automatic,
            networkCacheMilliseconds: Int(raw.network_cache_ms),
            forwardBufferSeconds: TimeInterval(raw.forward_buffer_ms) / 1_000,
            maximumBufferSeconds: TimeInterval(raw.maximum_buffer_ms) / 1_000,
            prefersCompatibilityStream: raw.prefer_compatibility_stream != 0,
            usesBoundedRenderer: raw.use_bounded_renderer != 0,
            requiresHardwareDecode: raw.require_hardware_decode != 0,
            prefersVideoToolboxChain: raw.prefer_videotoolbox_chain != 0,
            mpegTSByteSeekResolver: mpegTSByteSeekResolver
        )
        NSLog(
            "RUST_PLAYBACK_POLICY player=\(player.rawValue) decoder=\(policy.decoder) "
                + "network_cache_ms=\(policy.networkCacheMilliseconds) "
                + "forward_buffer_s=\(policy.forwardBufferSeconds) "
                + "maximum_buffer_s=\(policy.maximumBufferSeconds) "
                + "bounded_renderer=\(policy.usesBoundedRenderer) "
                + "hardware_required=\(policy.requiresHardwareDecode)"
        )
        return policy
    }
}
