use std::{
    collections::HashMap,
    ffi::{CStr, c_char},
    sync::Mutex,
    time::Instant,
};

pub mod media;

const ABI_VERSION: u32 = 1;

const SOURCE_UNKNOWN: u32 = 0;
const SOURCE_NATIVE_FILE: u32 = 1;
const SOURCE_HLS: u32 = 2;
const SOURCE_DIRECT_CONTAINER: u32 = 3;
const SOURCE_HIGH_RESOLUTION: u32 = 4;

const DECODER_AUTOMATIC: u32 = 0;
const DECODER_AVFOUNDATION: u32 = 1;
const DECODER_BUNNY_RUST: u32 = 2;

const PLAYER_PERFORMANCE: u32 = 0;
const PLAYER_AVPLAYER: u32 = 3;
const PLAYER_BUNNY: u32 = 4;

#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StremioPlaybackPolicy {
    pub abi_version: u32,
    pub source_kind: u32,
    pub decoder_kind: u32,
    pub network_cache_ms: u32,
    pub forward_buffer_ms: u32,
    pub maximum_buffer_ms: u32,
    pub prefer_compatibility_stream: u8,
    pub use_bounded_renderer: u8,
    pub require_hardware_decode: u8,
    pub prefer_videotoolbox_chain: u8,
}

fn text(pointer: *const c_char) -> String {
    if pointer.is_null() {
        return String::new();
    }
    // SAFETY: The C ABI contract requires a valid, NUL-terminated string for
    // the duration of this call. Invalid UTF-8 is lossily normalized because
    // source labels are hints, never trusted executable input.
    unsafe { CStr::from_ptr(pointer) }
        .to_string_lossy()
        .to_ascii_lowercase()
}

fn contains_any(haystack: &str, needles: &[&str]) -> bool {
    needles.iter().any(|needle| haystack.contains(needle))
}

fn contains_file_extension(haystack: &str, extension: &str) -> bool {
    haystack.match_indices(extension).any(|(index, _)| {
        let end = index + extension.len();
        haystack
            .as_bytes()
            .get(end)
            .is_none_or(|byte| !byte.is_ascii_alphanumeric())
    })
}

fn classify(url: &str, title: &str) -> (u32, bool, bool) {
    let normalized_url = url.to_ascii_lowercase();
    let hint = format!("{normalized_url} {title}").to_ascii_lowercase();
    let high_resolution = contains_any(&hint, &["4320p", "2160p", " 8k", " 4k", "ai upscale"]);
    let hls = contains_any(&hint, &[".m3u8", " hls", "mpegurl"]);
    let hevc = contains_any(&hint, &["x265", "hevc"]);
    let native_file = [".mp4", ".m4v", ".mov", ".m4a", ".mp3", ".aac", ".ts"]
        .iter()
        .any(|extension| contains_file_extension(&hint, extension));
    let native_mime = contains_any(&hint, &["video/mp4", "video/quicktime", "video/mp2t"]);
    let direct_container = [".mkv", ".webm", ".avi"]
        .iter()
        .any(|extension| contains_file_extension(&hint, extension))
        || contains_any(&hint, &[" mkv", "matroska", " webm"]);
    let uncommon_codec = contains_any(&hint, &["av1", "flac", "truehd", " dts"]);
    // Container evidence is stronger than resolution or codec hints. Provider
    // resolvers frequently replace a descriptive filename with an extensionless
    // signed CDN URL, so the stream title must participate in classification.
    let kind = if hls {
        SOURCE_HLS
    } else if native_file {
        SOURCE_NATIVE_FILE
    } else if direct_container {
        SOURCE_DIRECT_CONTAINER
    } else if high_resolution {
        SOURCE_HIGH_RESOLUTION
    } else {
        SOURCE_UNKNOWN
    };
    (
        kind,
        hls || native_file || native_mime,
        direct_container || uncommon_codec || high_resolution || hevc,
    )
}

fn policy(url: &str, title: &str, player_kind: u32) -> StremioPlaybackPolicy {
    let (source_kind, apple_native, demanding) = classify(url, title);
    let loopback_transport_bridge = contains_any(url, &["127.0.0.1", "localhost"])
        && url.contains("/stream/")
        && url.contains(".ts");
    let (network_cache_ms, forward_buffer_ms, maximum_buffer_ms) = if loopback_transport_bridge {
        // The bridge already owns a compressed 64 MiB seek cache. Keeping a
        // second 30-45 second decoded queue inside a renderer lets its audio
        // prefill clock run far ahead of the displayed frame, especially
        // immediately after a transport-stream seek. A short active queue
        // preserves instant starts while keeping frame pacing clock-bound.
        (500, 3_000, 12_000)
    } else if demanding {
        (1_500, 4_000, 45_000)
    } else if source_kind == SOURCE_HLS {
        (750, 6_000, 30_000)
    } else {
        (900, 3_000, 30_000)
    };

    let decoder_kind = match player_kind {
        PLAYER_AVPLAYER => DECODER_AVFOUNDATION,
        // Keep Apple's optimized HLS/file pipeline for formats it owns. Bunny's
        // dependency-free Rust demuxer handles direct containers and feeds
        // compressed samples into Apple system decoders.
        PLAYER_BUNNY => {
            // Extensionless provider and torrent routes often serve ordinary
            // MP4 bytes. Let AVFoundation sniff unknown sources first; Bunny
            // still falls back to the Rust Matroska path if Apple's probe
            // cannot open them.
            if apple_native || matches!(source_kind, SOURCE_UNKNOWN | SOURCE_HIGH_RESOLUTION) {
                DECODER_AVFOUNDATION
            } else {
                DECODER_BUNNY_RUST
            }
        }
        PLAYER_PERFORMANCE => {
            if apple_native || matches!(source_kind, SOURCE_UNKNOWN | SOURCE_HIGH_RESOLUTION) {
                DECODER_AVFOUNDATION
            } else {
                DECODER_BUNNY_RUST
            }
        }
        _ => DECODER_AUTOMATIC,
    };

    StremioPlaybackPolicy {
        abi_version: ABI_VERSION,
        source_kind,
        decoder_kind,
        network_cache_ms,
        forward_buffer_ms,
        maximum_buffer_ms,
        prefer_compatibility_stream: u8::from(
            player_kind == PLAYER_AVPLAYER && !apple_native && demanding,
        ),
        use_bounded_renderer: 0,
        require_hardware_decode: u8::from(demanding),
        prefer_videotoolbox_chain: u8::from(decoder_kind == DECODER_BUNNY_RUST && demanding),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn stremio_playback_policy(
    url: *const c_char,
    title: *const c_char,
    player_kind: u32,
) -> StremioPlaybackPolicy {
    policy(&text(url), &text(title), player_kind)
}

#[derive(Debug)]
struct BunnyClockState {
    media_time_us: i64,
    rate: f64,
    updated_at: Instant,
}

/// Opaque, thread-safe media clock shared with Bunny's Objective-C decoder.
/// Apple's audio renderer remains the physical A/V clock; this clock owns the
/// deterministic rate/seek state used for UI and bounded queue decisions.
pub struct StremioBunnyClock {
    state: Mutex<BunnyClockState>,
}

fn clock_position_us(state: &BunnyClockState, now: Instant) -> i64 {
    if state.rate <= 0.0 {
        return state.media_time_us.max(0);
    }
    let elapsed_us = now
        .saturating_duration_since(state.updated_at)
        .as_micros()
        .min(i64::MAX as u128) as f64;
    state
        .media_time_us
        .saturating_add((elapsed_us * state.rate).round() as i64)
        .max(0)
}

#[unsafe(no_mangle)]
pub extern "C" fn stremio_bunny_clock_create() -> *mut StremioBunnyClock {
    Box::into_raw(Box::new(StremioBunnyClock {
        state: Mutex::new(BunnyClockState {
            media_time_us: 0,
            rate: 0.0,
            updated_at: Instant::now(),
        }),
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_bunny_clock_destroy(clock: *mut StremioBunnyClock) {
    if !clock.is_null() {
        // SAFETY: The caller transfers the unique pointer returned by create
        // and must destroy it exactly once.
        drop(unsafe { Box::from_raw(clock) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_bunny_clock_seek(
    clock: *mut StremioBunnyClock,
    media_time_us: i64,
) {
    // SAFETY: Null is a no-op; non-null pointers must originate from create.
    let Some(clock) = (unsafe { clock.as_ref() }) else {
        return;
    };
    let mut state = clock
        .state
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    state.media_time_us = media_time_us.max(0);
    state.updated_at = Instant::now();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_bunny_clock_set_rate(clock: *mut StremioBunnyClock, rate: f64) {
    // SAFETY: See stremio_bunny_clock_seek.
    let Some(clock) = (unsafe { clock.as_ref() }) else {
        return;
    };
    let now = Instant::now();
    let mut state = clock
        .state
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    state.media_time_us = clock_position_us(&state, now);
    state.rate = rate.clamp(0.0, 2.0);
    state.updated_at = now;
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_bunny_clock_observe(
    clock: *mut StremioBunnyClock,
    media_time_us: i64,
) {
    // SAFETY: See stremio_bunny_clock_seek.
    let Some(clock) = (unsafe { clock.as_ref() }) else {
        return;
    };
    let mut state = clock
        .state
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    state.media_time_us = media_time_us.max(0);
    state.updated_at = Instant::now();
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_bunny_clock_position_us(clock: *const StremioBunnyClock) -> i64 {
    // SAFETY: See stremio_bunny_clock_seek.
    let Some(clock) = (unsafe { clock.as_ref() }) else {
        return 0;
    };
    let state = clock
        .state
        .lock()
        .unwrap_or_else(|error| error.into_inner());
    clock_position_us(&state, Instant::now())
}

#[derive(Clone, Copy)]
struct PcrSpan {
    first_ticks: u64,
    first_offset: usize,
    last_ticks: u64,
    last_offset: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StremioTransportTiming {
    pub abi_version: u32,
    pub pcr_pid: u16,
    pub has_timing: u8,
    pub reserved: u8,
    pub first_pcr_ticks: u64,
    pub last_pcr_ticks: u64,
    pub first_byte_offset: u64,
    pub last_byte_offset: u64,
    pub bitrate_bps: u64,
}

fn transport_layout(bytes: &[u8]) -> Option<(usize, usize)> {
    for stride in [188_usize, 192, 204] {
        let maximum_offset = stride.min(bytes.len());
        for offset in 0..maximum_offset {
            let enough_packets = offset + stride * 4 < bytes.len();
            if enough_packets && (0..5).all(|index| bytes[offset + stride * index] == 0x47) {
                return Some((offset, stride));
            }
        }
    }
    None
}

fn packet_pcr(bytes: &[u8], offset: usize) -> Option<(u16, u64, bool)> {
    if offset + 12 > bytes.len() || bytes[offset] != 0x47 {
        return None;
    }
    let adaptation_control = (bytes[offset + 3] >> 4) & 0x03;
    if adaptation_control != 2 && adaptation_control != 3 {
        return None;
    }
    let adaptation_length = usize::from(bytes[offset + 4]);
    if adaptation_length < 7 || offset + 5 + adaptation_length > bytes.len() {
        return None;
    }
    let flags = bytes[offset + 5];
    if flags & 0x10 == 0 {
        return None;
    }
    let pcr = &bytes[offset + 6..offset + 12];
    let base = (u64::from(pcr[0]) << 25)
        | (u64::from(pcr[1]) << 17)
        | (u64::from(pcr[2]) << 9)
        | (u64::from(pcr[3]) << 1)
        | (u64::from(pcr[4]) >> 7);
    let extension = (u64::from(pcr[4] & 0x01) << 8) | u64::from(pcr[5]);
    let pid = (u16::from(bytes[offset + 1] & 0x1f) << 8) | u16::from(bytes[offset + 2]);
    Some((pid, base * 300 + extension, flags & 0x80 != 0))
}

fn pcr_delta(first: u64, last: u64) -> u64 {
    const PCR_WRAP: u64 = (1_u64 << 33) * 300;
    if last >= first {
        last - first
    } else {
        PCR_WRAP - first + last
    }
}

fn probe_mpegts_timing(bytes: &[u8]) -> Option<(u16, PcrSpan, u64)> {
    let (sync_offset, stride) = transport_layout(bytes)?;
    let mut spans = HashMap::<u16, PcrSpan>::new();
    let mut offset = sync_offset;
    while offset + 12 <= bytes.len() {
        if let Some((pid, ticks, discontinuity)) = packet_pcr(bytes, offset) {
            if discontinuity {
                spans.remove(&pid);
            }
            spans
                .entry(pid)
                .and_modify(|span| {
                    span.last_ticks = ticks;
                    span.last_offset = offset;
                })
                .or_insert(PcrSpan {
                    first_ticks: ticks,
                    first_offset: offset,
                    last_ticks: ticks,
                    last_offset: offset,
                });
        }
        offset += stride;
    }

    spans
        .into_iter()
        .filter_map(|(pid, span)| {
            let ticks = pcr_delta(span.first_ticks, span.last_ticks);
            let byte_count = span.last_offset.checked_sub(span.first_offset)?;
            // Reject spans shorter than 250 ms: short PCR jitter is not a
            // dependable basis for pacing a multi-gigabyte stream.
            if ticks < 27_000_000 / 4 || byte_count == 0 {
                return None;
            }
            let bitrate = (byte_count as u128 * 8 * 27_000_000_u128) / u128::from(ticks);
            let bitrate = u64::try_from(bitrate).ok()?;
            (64_000..=200_000_000)
                .contains(&bitrate)
                .then_some((byte_count, pid, span, bitrate))
        })
        .max_by_key(|(byte_count, _, _, _)| *byte_count)
        .map(|(_, pid, span, bitrate)| (pid, span, bitrate))
}

fn estimate_mpegts_bitrate_bps(bytes: &[u8]) -> Option<u64> {
    probe_mpegts_timing(bytes).map(|(_, _, bitrate)| bitrate)
}

/// # Safety
///
/// `bytes` must point to `length` readable bytes for the duration of this
/// call. A null pointer is accepted only when `length` is zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_mpegts_bitrate_bps(bytes: *const u8, length: usize) -> u64 {
    if bytes.is_null() || length == 0 {
        return 0;
    }
    // SAFETY: The caller contract above guarantees a readable buffer, and the
    // slice cannot outlive this synchronous FFI call.
    let bytes = unsafe { std::slice::from_raw_parts(bytes, length) };
    estimate_mpegts_bitrate_bps(bytes).unwrap_or(0)
}

/// # Safety
///
/// `bytes` must point to `length` readable bytes for the duration of this
/// call. A null pointer is accepted only when `length` is zero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_mpegts_timing(
    bytes: *const u8,
    length: usize,
) -> StremioTransportTiming {
    if bytes.is_null() || length == 0 {
        return StremioTransportTiming {
            abi_version: ABI_VERSION,
            ..Default::default()
        };
    }
    // SAFETY: The caller contract above guarantees a readable buffer, and the
    // slice cannot outlive this synchronous FFI call.
    let bytes = unsafe { std::slice::from_raw_parts(bytes, length) };
    let Some((pid, span, bitrate)) = probe_mpegts_timing(bytes) else {
        return StremioTransportTiming {
            abi_version: ABI_VERSION,
            ..Default::default()
        };
    };
    StremioTransportTiming {
        abi_version: ABI_VERSION,
        pcr_pid: pid,
        has_timing: 1,
        reserved: 0,
        first_pcr_ticks: span.first_ticks,
        last_pcr_ticks: span.last_ticks,
        first_byte_offset: span.first_offset as u64,
        last_byte_offset: span.last_offset as u64,
        bitrate_bps: bitrate,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes_hls_to_avfoundation() {
        let result = policy(
            "https://example.test/master.m3u8",
            "Movie",
            PLAYER_PERFORMANCE,
        );
        assert_eq!(result.source_kind, SOURCE_HLS);
        assert_eq!(result.decoder_kind, DECODER_AVFOUNDATION);
        assert_eq!(result.use_bounded_renderer, 0);
    }

    #[test]
    fn routes_hevc_to_bunny_rust() {
        let result = policy(
            "https://example.test/download",
            "1080p BluRay x265 HEVC MKV",
            PLAYER_PERFORMANCE,
        );
        assert_eq!(result.source_kind, SOURCE_DIRECT_CONTAINER);
        assert_eq!(result.decoder_kind, DECODER_BUNNY_RUST);
        assert_eq!(result.use_bounded_renderer, 0);
        assert_eq!(result.require_hardware_decode, 1);
    }

    #[test]
    fn routes_relabeled_transport_stream_to_avfoundation() {
        let result = policy(
            "https://cdn.example.test/movie.mp4",
            "Movie video/mp2t",
            PLAYER_PERFORMANCE,
        );
        assert_eq!(result.source_kind, SOURCE_NATIVE_FILE);
        assert_eq!(result.decoder_kind, DECODER_AVFOUNDATION);
        assert_eq!(result.require_hardware_decode, 0);
    }

    #[test]
    fn keeps_loopback_transport_bridge_decode_queue_short() {
        let result = policy(
            "http://127.0.0.1:54321/stream/token/media.ts",
            "Movie video/mp2t",
            PLAYER_PERFORMANCE,
        );
        assert_eq!(result.source_kind, SOURCE_NATIVE_FILE);
        assert_eq!(result.decoder_kind, DECODER_AVFOUNDATION);
        assert_eq!(result.forward_buffer_ms, 3_000);
        assert_eq!(result.maximum_buffer_ms, 12_000);
    }

    #[test]
    fn routes_extensionless_transport_stream_hint_to_avfoundation() {
        let result = policy(
            "https://cdn.example.test/signed/provider/source",
            "Movie video/mp2t MPEGTS transport stream",
            PLAYER_BUNNY,
        );
        assert_eq!(result.source_kind, SOURCE_UNKNOWN);
        assert_eq!(result.decoder_kind, DECODER_AVFOUNDATION);
        assert_eq!(result.require_hardware_decode, 0);
    }

    fn packet_with_pcr(pid: u16, ticks: u64) -> [u8; 188] {
        let mut packet = [0xff; 188];
        packet[0] = 0x47;
        packet[1] = ((pid >> 8) as u8) & 0x1f;
        packet[2] = pid as u8;
        packet[3] = 0x20;
        packet[4] = 7;
        packet[5] = 0x10;
        let base = ticks / 300;
        let extension = ticks % 300;
        packet[6] = (base >> 25) as u8;
        packet[7] = (base >> 17) as u8;
        packet[8] = (base >> 9) as u8;
        packet[9] = (base >> 1) as u8;
        packet[10] = ((base & 1) << 7) as u8 | 0x7e | ((extension >> 8) as u8 & 1);
        packet[11] = extension as u8;
        packet
    }

    #[test]
    fn estimates_mpegts_bitrate_from_pcr_span() {
        let mut bytes = vec![0xff; 188 * 1_001];
        for packet_index in 0..=1_000 {
            bytes[packet_index * 188] = 0x47;
            bytes[packet_index * 188 + 3] = 0x10;
        }
        bytes[..188].copy_from_slice(&packet_with_pcr(256, 0));
        bytes[188_000..188_188].copy_from_slice(&packet_with_pcr(256, 27_000_000));
        assert_eq!(estimate_mpegts_bitrate_bps(&bytes), Some(1_504_000));
        let (pid, span, bitrate) = probe_mpegts_timing(&bytes).unwrap();
        assert_eq!(pid, 256);
        assert_eq!(span.first_offset, 0);
        assert_eq!(span.last_offset, 188_000);
        assert_eq!(span.first_ticks, 0);
        assert_eq!(span.last_ticks, 27_000_000);
        assert_eq!(bitrate, 1_504_000);
    }

    #[test]
    fn keeps_native_hevc_mp4_on_avfoundation() {
        let result = policy(
            "https://cdn.example.test/movie.mp4",
            "1080p HEVC video/mp4",
            PLAYER_PERFORMANCE,
        );
        assert_eq!(result.source_kind, SOURCE_NATIVE_FILE);
        assert_eq!(result.decoder_kind, DECODER_AVFOUNDATION);
        assert_eq!(result.use_bounded_renderer, 0);
    }

    #[test]
    fn uses_mp4_title_hint_after_provider_replaces_filename_with_signed_url() {
        let result = policy(
            "https://cdn.example.test/signed/provider/source",
            "The.Movie.2160p.H.265.AAC.mp4",
            PLAYER_BUNNY,
        );
        assert_eq!(result.source_kind, SOURCE_NATIVE_FILE);
        assert_eq!(result.decoder_kind, DECODER_AVFOUNDATION);
    }

    #[test]
    fn keeps_mkv_title_hint_on_rust_after_provider_replaces_filename() {
        let result = policy(
            "https://cdn.example.test/signed/provider/source",
            "The.Movie.2160p.HEVC.TrueHD.mkv",
            PLAYER_BUNNY,
        );
        assert_eq!(result.source_kind, SOURCE_DIRECT_CONTAINER);
        assert_eq!(result.decoder_kind, DECODER_BUNNY_RUST);
    }

    #[test]
    fn sniffs_ambiguous_extensionless_hevc_before_rust_fallback() {
        let result = policy(
            "https://cdn.example.test/signed/provider/source",
            "The Movie 1080p HEVC",
            PLAYER_BUNNY,
        );
        assert_eq!(result.source_kind, SOURCE_UNKNOWN);
        assert_eq!(result.decoder_kind, DECODER_AVFOUNDATION);
    }

    #[test]
    fn sniffs_ambiguous_extensionless_4k_av1_before_rust_fallback() {
        let result = policy(
            "https://cdn.example.test/signed/provider/source",
            "The Movie 2160p AV1 10-bit",
            PLAYER_BUNNY,
        );
        assert_eq!(result.source_kind, SOURCE_HIGH_RESOLUTION);
        assert_eq!(result.decoder_kind, DECODER_AVFOUNDATION);
    }

    #[test]
    fn routes_high_resolution_performance_sources_to_bunny_rust() {
        let result = policy(
            "https://example.test/video.mkv",
            "2160p HEVC",
            PLAYER_PERFORMANCE,
        );
        assert_eq!(result.decoder_kind, DECODER_BUNNY_RUST);
        assert_eq!(result.use_bounded_renderer, 0);
        assert_eq!(result.prefer_videotoolbox_chain, 1);
    }

    #[test]
    fn asks_avplayer_for_compatibility_on_non_native_sources() {
        let result = policy("https://example.test/file", "AV1 FLAC", PLAYER_AVPLAYER);
        assert_eq!(result.prefer_compatibility_stream, 1);
    }

    #[test]
    fn routes_native_sources_to_apple_and_direct_containers_to_bunny_rust() {
        let native = policy("https://example.test/video.mp4", "H264 AAC", PLAYER_BUNNY);
        let uncommon = policy("https://example.test/video.mkv", "AV1 FLAC", PLAYER_BUNNY);
        let hls = policy("https://example.test/master.m3u8", "HLS", PLAYER_BUNNY);
        assert_eq!(native.decoder_kind, DECODER_AVFOUNDATION);
        assert_eq!(uncommon.decoder_kind, DECODER_BUNNY_RUST);
        assert_eq!(hls.decoder_kind, DECODER_AVFOUNDATION);
        assert_eq!(uncommon.prefer_compatibility_stream, 0);
    }

    #[test]
    fn lets_avfoundation_sniff_extensionless_unknown_sources_first() {
        let result = policy(
            "https://stream.example.test/0123456789abcdef/0?token=redacted",
            "0",
            PLAYER_BUNNY,
        );
        assert_eq!(result.source_kind, SOURCE_UNKNOWN);
        assert_eq!(result.decoder_kind, DECODER_AVFOUNDATION);
    }

    #[test]
    fn keeps_bunny_selected_across_the_custom_format_matrix() {
        for (url, title) in [
            ("https://example.test/video.webm", "VP9 Opus"),
            ("https://example.test/video.avi", "MPEG4 MP3"),
            ("https://example.test/video.mkv", "HEVC TrueHD"),
            ("https://example.test/download", "H264 DTS Matroska"),
        ] {
            let result = policy(url, title, PLAYER_BUNNY);
            assert_eq!(result.decoder_kind, DECODER_BUNNY_RUST, "{url} {title}");
            assert_eq!(result.prefer_compatibility_stream, 0, "{url} {title}");
        }
    }

    #[test]
    fn bunny_clock_preserves_seek_position_while_paused() {
        let clock = stremio_bunny_clock_create();
        unsafe {
            stremio_bunny_clock_seek(clock, 42_500_000);
            stremio_bunny_clock_set_rate(clock, 0.0);
            assert_eq!(stremio_bunny_clock_position_us(clock), 42_500_000);
            stremio_bunny_clock_destroy(clock);
        }
    }
}
