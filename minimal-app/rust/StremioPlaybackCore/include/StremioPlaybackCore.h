#ifndef STREMIO_PLAYBACK_CORE_H
#define STREMIO_PLAYBACK_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct StremioPlaybackPolicy {
    uint32_t abi_version;
    uint32_t source_kind;
    uint32_t decoder_kind;
    uint32_t network_cache_ms;
    uint32_t forward_buffer_ms;
    uint32_t maximum_buffer_ms;
    uint8_t prefer_compatibility_stream;
    uint8_t use_bounded_renderer;
    uint8_t require_hardware_decode;
    uint8_t prefer_videotoolbox_chain;
} StremioPlaybackPolicy;

typedef struct StremioTransportTiming {
    uint32_t abi_version;
    uint16_t pcr_pid;
    uint8_t has_timing;
    uint8_t reserved;
    uint64_t first_pcr_ticks;
    uint64_t last_pcr_ticks;
    uint64_t first_byte_offset;
    uint64_t last_byte_offset;
    uint64_t bitrate_bps;
} StremioTransportTiming;

/// Player kinds: 0 performance, 1 KSPlayer, 2 VLC, 3 AVPlayer.
StremioPlaybackPolicy stremio_playback_policy(
    const char *url,
    const char *title,
    uint32_t player_kind
);

/// Estimates the aggregate MPEG-TS bitrate from PCR samples. Returns zero
/// when the buffer does not contain enough consistent transport timing data.
uint64_t stremio_mpegts_bitrate_bps(const uint8_t *bytes, size_t length);

/// Returns the PCR PID, timestamp span, and byte positions used by the
/// transport estimator. Tick values use MPEG-TS's 27 MHz PCR clock.
StremioTransportTiming stremio_mpegts_timing(
    const uint8_t *bytes,
    size_t length
);

#ifdef __cplusplus
}
#endif

#endif
