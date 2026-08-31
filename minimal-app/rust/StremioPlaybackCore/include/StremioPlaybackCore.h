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

typedef struct StremioBunnyClock StremioBunnyClock;
typedef struct StremioMediaSession StremioMediaSession;
typedef struct StremioPgsDecoder StremioPgsDecoder;

typedef int64_t (*StremioMediaReadAtCallback)(
    void *context,
    uint64_t offset,
    uint8_t *output,
    size_t length
);

typedef struct StremioMediaSourceCallbacks {
    uint32_t abi_version;
    uint64_t source_length;
    StremioMediaReadAtCallback read_at;
} StremioMediaSourceCallbacks;

typedef struct StremioMediaSummary {
    uint32_t abi_version;
    uint32_t container_kind;
    uint64_t duration_ns;
    uint64_t timecode_scale_ns;
    uint32_t track_count;
    uint32_t cue_count;
} StremioMediaSummary;

enum {
    STREMIO_MEDIA_SUMMARY_ABI_VERSION = 1,
    STREMIO_MEDIA_TRACK_INFO_ABI_VERSION = 2,
    STREMIO_MEDIA_PACKET_ABI_VERSION = 4,
};

typedef struct StremioMediaTrackInfo {
    uint32_t abi_version;
    uint32_t index;
    uint64_t number;
    uint64_t uid;
    uint32_t kind;
    uint32_t codec;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t display_width;
    uint32_t display_height;
    uint32_t display_unit;
    uint32_t audio_frames_per_packet;
    double sample_rate;
    uint32_t channels;
    uint32_t bit_depth;
    uint64_t default_duration_ns;
    uint64_t codec_delay_ns;
    size_t codec_private_size;
} StremioMediaTrackInfo;

typedef struct StremioMediaVideoColorInfo {
    uint32_t abi_version;
    uint32_t flags;
    uint32_t matrix_coefficients;
    uint32_t bits_per_channel;
    uint32_t range;
    uint32_t transfer_characteristics;
    uint32_t primaries;
    uint32_t max_cll;
    uint32_t max_fall;
    double primary_r_x;
    double primary_r_y;
    double primary_g_x;
    double primary_g_y;
    double primary_b_x;
    double primary_b_y;
    double white_point_x;
    double white_point_y;
    double luminance_max;
    double luminance_min;
} StremioMediaVideoColorInfo;

typedef struct StremioMediaBlockAdditionMappingInfo {
    uint32_t abi_version;
    uint32_t reserved;
    uint64_t id_value;
    uint64_t id_type;
    const uint8_t *extra_data;
    size_t extra_data_size;
} StremioMediaBlockAdditionMappingInfo;

typedef struct StremioMediaPacket {
    uint32_t abi_version;
    uint32_t track_index;
    int64_t presentation_time_ns;
    int64_t decode_time_ns;
    uint64_t duration_ns;
    int64_t discard_padding_ns;
    uint32_t flags;
    const uint8_t *data;
    size_t data_size;
    const uint8_t *hdr10_plus_data;
    size_t hdr10_plus_data_size;
} StremioMediaPacket;

typedef struct StremioPgsPresentationInfo {
    uint32_t abi_version;
    uint64_t presentation_time_ns;
    uint32_t canvas_width;
    uint32_t canvas_height;
    uint32_t part_count;
    uint8_t is_clear;
} StremioPgsPresentationInfo;

typedef struct StremioPgsPartInfo {
    uint32_t abi_version;
    uint32_t x;
    uint32_t y;
    uint32_t width;
    uint32_t height;
    uint8_t forced;
    const uint8_t *rgba;
    size_t rgba_size;
} StremioPgsPartInfo;

enum {
    STREMIO_MEDIA_TRACK_VIDEO = 1,
    STREMIO_MEDIA_TRACK_AUDIO = 2,
    STREMIO_MEDIA_TRACK_SUBTITLE = 3,
};

enum {
    STREMIO_MEDIA_VIDEO_COLOR_MATRIX_PRESENT = 1 << 0,
    STREMIO_MEDIA_VIDEO_COLOR_BITS_PER_CHANNEL_PRESENT = 1 << 1,
    STREMIO_MEDIA_VIDEO_COLOR_RANGE_PRESENT = 1 << 2,
    STREMIO_MEDIA_VIDEO_COLOR_TRANSFER_PRESENT = 1 << 3,
    STREMIO_MEDIA_VIDEO_COLOR_PRIMARIES_PRESENT = 1 << 4,
    STREMIO_MEDIA_VIDEO_COLOR_MAX_CLL_PRESENT = 1 << 5,
    STREMIO_MEDIA_VIDEO_COLOR_MAX_FALL_PRESENT = 1 << 6,
    STREMIO_MEDIA_VIDEO_COLOR_MASTERING_PRESENT = 1 << 7,
};

enum {
    STREMIO_MEDIA_BLOCK_ADD_ID_TYPE_ITU_T_T35 = 4,
    STREMIO_MEDIA_BLOCK_ADD_ID_TYPE_DVCC = 0x64766343,
    STREMIO_MEDIA_BLOCK_ADD_ID_TYPE_DVVC = 0x64767643,
    STREMIO_MEDIA_BLOCK_ADD_ID_TYPE_DVWC = 0x64767743,
    STREMIO_MEDIA_BLOCK_ADD_ID_TYPE_HVCE = 0x68766345,
};

enum {
    STREMIO_MEDIA_CODEC_UNKNOWN = 0,
    STREMIO_MEDIA_CODEC_H264 = 1,
    STREMIO_MEDIA_CODEC_HEVC = 2,
    STREMIO_MEDIA_CODEC_AV1 = 3,
    STREMIO_MEDIA_CODEC_VP9 = 4,
    STREMIO_MEDIA_CODEC_MPEG4 = 5,
    STREMIO_MEDIA_CODEC_AAC = 100,
    STREMIO_MEDIA_CODEC_AC3 = 101,
    STREMIO_MEDIA_CODEC_EAC3 = 102,
    STREMIO_MEDIA_CODEC_FLAC = 103,
    STREMIO_MEDIA_CODEC_OPUS = 104,
    STREMIO_MEDIA_CODEC_TRUEHD = 105,
    STREMIO_MEDIA_CODEC_DTS = 106,
    STREMIO_MEDIA_CODEC_PCM = 107,
    STREMIO_MEDIA_CODEC_SUBRIP = 200,
    STREMIO_MEDIA_CODEC_WEBVTT = 201,
    STREMIO_MEDIA_CODEC_ASS = 202,
    STREMIO_MEDIA_CODEC_PGS = 203,
};

enum {
    STREMIO_MEDIA_TRACK_DEFAULT = 1 << 0,
    STREMIO_MEDIA_TRACK_FORCED = 1 << 1,
    STREMIO_MEDIA_TRACK_APPLE_DECODABLE = 1 << 2,
    STREMIO_MEDIA_TRACK_ENABLED = 1 << 3,
};

enum {
    STREMIO_MEDIA_PACKET_KEYFRAME = 1 << 0,
    STREMIO_MEDIA_PACKET_INVISIBLE = 1 << 1,
    STREMIO_MEDIA_PACKET_DISCARDABLE = 1 << 2,
    STREMIO_MEDIA_PACKET_LACED = 1 << 3,
};

enum {
    STREMIO_DOLBY_CHANNEL_CONFIGURATION_LFE = 1 << 3,
    STREMIO_DOLBY_CHANNEL_CONFIGURATION_VALID = 1 << 8,
};

uint32_t stremio_media_dolby_channel_configuration(
    uint32_t codec,
    const uint8_t *bytes,
    size_t length
);

/// Returns the decoded sample frames represented by one AC-3/E-AC-3 sync
/// frame, or zero when the packet header is invalid or unsupported.
uint32_t stremio_media_dolby_sample_frames(
    uint32_t codec,
    const uint8_t *bytes,
    size_t length
);

enum {
    STREMIO_MEDIA_TRACK_TEXT_CODEC_ID = 1,
    STREMIO_MEDIA_TRACK_TEXT_NAME = 2,
    STREMIO_MEDIA_TRACK_TEXT_LANGUAGE = 3,
};

/// Player kinds retained for ABI stability. Bunny is kind 4.
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

/// Thread-safe Rust session clock used by Bunny's custom media backend.
StremioBunnyClock *stremio_bunny_clock_create(void);
void stremio_bunny_clock_destroy(StremioBunnyClock *clock);
void stremio_bunny_clock_seek(StremioBunnyClock *clock, int64_t media_time_us);
void stremio_bunny_clock_set_rate(StremioBunnyClock *clock, double rate);
void stremio_bunny_clock_observe(StremioBunnyClock *clock, int64_t media_time_us);
int64_t stremio_bunny_clock_position_us(const StremioBunnyClock *clock);

/// Opens a clean-room Matroska/WebM session over a random-access source.
/// The callback and context must remain valid until the session is destroyed.
StremioMediaSession *stremio_media_open_matroska(
    StremioMediaSourceCallbacks callbacks,
    void *context,
    char *error_message,
    size_t error_capacity
);
void stremio_media_session_destroy(StremioMediaSession *session);
StremioMediaSummary stremio_media_summary(const StremioMediaSession *session);
int32_t stremio_media_track_info(
    const StremioMediaSession *session,
    uint32_t track_index,
    StremioMediaTrackInfo *output
);
int32_t stremio_media_track_video_color_info(
    const StremioMediaSession *session,
    uint32_t track_index,
    StremioMediaVideoColorInfo *output
);
uint32_t stremio_media_track_block_addition_mapping_count(
    const StremioMediaSession *session,
    uint32_t track_index
);
int32_t stremio_media_track_block_addition_mapping_info(
    const StremioMediaSession *session,
    uint32_t track_index,
    uint32_t mapping_index,
    StremioMediaBlockAdditionMappingInfo *output
);
size_t stremio_media_track_text(
    const StremioMediaSession *session,
    uint32_t track_index,
    uint32_t field,
    char *output,
    size_t capacity
);
const uint8_t *stremio_media_track_codec_private(
    const StremioMediaSession *session,
    uint32_t track_index,
    size_t *length
);
int32_t stremio_media_select_track(
    StremioMediaSession *session,
    uint32_t track_kind,
    int32_t track_index
);
int32_t stremio_media_seek(
    StremioMediaSession *session,
    uint64_t presentation_time_ns,
    char *error_message,
    size_t error_capacity
);
/// Returns packet iteration to the first cluster without resolving Cues.
int32_t stremio_media_rewind(
    StremioMediaSession *session,
    char *error_message,
    size_t error_capacity
);
/// Resolves deferred Matroska SeekHead/Cues metadata without changing the
/// current playback cursor. Returns 1 on success and 0 on error.
int32_t stremio_media_prepare_seek_index(
    StremioMediaSession *session,
    char *error_message,
    size_t error_capacity
);
/// Returns 1 for a packet, 0 for end-of-stream, and -1 for an error. Packet
/// bytes remain valid until the next mutating session call.
int32_t stremio_media_next_packet(
    StremioMediaSession *session,
    StremioMediaPacket *output,
    char *error_message,
    size_t error_capacity
);

/// Stateful, bounded PGS decoder for Matroska S_HDMV/PGS packets.
StremioPgsDecoder *stremio_pgs_decoder_create(void);
void stremio_pgs_decoder_destroy(StremioPgsDecoder *decoder);
void stremio_pgs_decoder_reset(StremioPgsDecoder *decoder);
int32_t stremio_pgs_push_matroska_packet(
    StremioPgsDecoder *decoder,
    int64_t presentation_time_ns,
    const uint8_t *bytes,
    size_t length,
    char *error_message,
    size_t error_capacity
);
StremioPgsPresentationInfo stremio_pgs_presentation(
    const StremioPgsDecoder *decoder
);
int32_t stremio_pgs_part(
    const StremioPgsDecoder *decoder,
    uint32_t part_index,
    StremioPgsPartInfo *output
);

#ifdef __cplusplus
}
#endif

#endif
