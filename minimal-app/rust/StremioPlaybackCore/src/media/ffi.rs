//! Stable C ABI for the Apple-facing Bunny media session.

use std::{
    ffi::{c_char, c_void},
    ptr,
};

use super::audio::{dolby_channel_configuration, dolby_sample_frames};
use super::{
    CallbackSource, Codec, MatroskaSession, MediaPacket, MediaTrack, PgsDecoder, PgsPresentation,
    SourceCallbacks, TrackKind,
};

const ABI_VERSION: u32 = 1;
const MEDIA_PACKET_ABI_VERSION: u32 = 3;

const VIDEO_COLOR_MATRIX_PRESENT: u32 = 1 << 0;
const VIDEO_COLOR_BITS_PER_CHANNEL_PRESENT: u32 = 1 << 1;
const VIDEO_COLOR_RANGE_PRESENT: u32 = 1 << 2;
const VIDEO_COLOR_TRANSFER_PRESENT: u32 = 1 << 3;
const VIDEO_COLOR_PRIMARIES_PRESENT: u32 = 1 << 4;
const VIDEO_COLOR_MAX_CLL_PRESENT: u32 = 1 << 5;
const VIDEO_COLOR_MAX_FALL_PRESENT: u32 = 1 << 6;
const VIDEO_COLOR_MASTERING_PRESENT: u32 = 1 << 7;
const BLOCK_ADD_ID_TYPE_ITU_T_T35: u64 = 4;

const TRACK_FLAG_DEFAULT: u32 = 1 << 0;
const TRACK_FLAG_FORCED: u32 = 1 << 1;
const TRACK_FLAG_APPLE_DECODABLE: u32 = 1 << 2;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct StremioMediaSummary {
    pub abi_version: u32,
    pub container_kind: u32,
    pub duration_ns: u64,
    pub timecode_scale_ns: u64,
    pub track_count: u32,
    pub cue_count: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct StremioMediaTrackInfo {
    pub abi_version: u32,
    pub index: u32,
    pub number: u64,
    pub uid: u64,
    pub kind: u32,
    pub codec: u32,
    pub flags: u32,
    pub width: u32,
    pub height: u32,
    pub sample_rate: f64,
    pub channels: u32,
    pub bit_depth: u32,
    pub default_duration_ns: u64,
    pub codec_delay_ns: u64,
    pub codec_private_size: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct StremioMediaVideoColorInfo {
    pub abi_version: u32,
    pub flags: u32,
    pub matrix_coefficients: u32,
    pub bits_per_channel: u32,
    pub range: u32,
    pub transfer_characteristics: u32,
    pub primaries: u32,
    pub max_cll: u32,
    pub max_fall: u32,
    pub primary_r_x: f64,
    pub primary_r_y: f64,
    pub primary_g_x: f64,
    pub primary_g_y: f64,
    pub primary_b_x: f64,
    pub primary_b_y: f64,
    pub white_point_x: f64,
    pub white_point_y: f64,
    pub luminance_max: f64,
    pub luminance_min: f64,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct StremioMediaBlockAdditionMappingInfo {
    pub abi_version: u32,
    pub reserved: u32,
    pub id_value: u64,
    pub id_type: u64,
    pub extra_data: *const u8,
    pub extra_data_size: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct StremioMediaPacket {
    pub abi_version: u32,
    pub track_index: u32,
    pub presentation_time_ns: i64,
    pub decode_time_ns: i64,
    pub duration_ns: u64,
    pub flags: u32,
    pub data: *const u8,
    pub data_size: usize,
    pub hdr10_plus_data: *const u8,
    pub hdr10_plus_data_size: usize,
}

pub struct StremioMediaSession {
    session: MatroskaSession,
    last_packet: Option<MediaPacket>,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct StremioPgsPresentationInfo {
    pub abi_version: u32,
    pub presentation_time_ns: u64,
    pub canvas_width: u32,
    pub canvas_height: u32,
    pub part_count: u32,
    pub is_clear: u8,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct StremioPgsPartInfo {
    pub abi_version: u32,
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub forced: u8,
    pub rgba: *const u8,
    pub rgba_size: usize,
}

pub struct StremioPgsDecoder {
    decoder: PgsDecoder,
    presentation: Option<PgsPresentation>,
}

fn write_message(output: *mut c_char, capacity: usize, message: &str) {
    if output.is_null() || capacity == 0 {
        return;
    }
    let bytes = message.as_bytes();
    let count = bytes.len().min(capacity.saturating_sub(1));
    // SAFETY: The caller provides a writable buffer of `capacity` bytes. The
    // copy is bounded to capacity - 1 and a trailing NUL is always written.
    unsafe {
        ptr::copy_nonoverlapping(bytes.as_ptr(), output.cast::<u8>(), count);
        output.add(count).write(0);
    }
}

fn write_text(output: *mut c_char, capacity: usize, value: &str) -> usize {
    write_message(output, capacity, value);
    value.len()
}

fn ffi_codec(codec: Codec) -> u32 {
    match codec {
        Codec::H264 => 1,
        Codec::Hevc => 2,
        Codec::Av1 => 3,
        Codec::Vp9 => 4,
        Codec::Aac => 100,
        Codec::Ac3 => 101,
        Codec::Eac3 => 102,
        Codec::Flac => 103,
        Codec::Opus => 104,
        Codec::TrueHd => 105,
        Codec::Dts => 106,
        Codec::Pcm => 107,
        Codec::Utf8Subtitle => 200,
        Codec::WebVtt => 201,
        Codec::Ass | Codec::Ssa => 202,
        Codec::Pgs => 203,
        _ => 0,
    }
}

fn codec_from_ffi(codec: u32) -> Option<Codec> {
    match codec {
        101 => Some(Codec::Ac3),
        102 => Some(Codec::Eac3),
        _ => None,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_dolby_channel_configuration(
    codec: u32,
    bytes: *const u8,
    length: usize,
) -> u32 {
    let Some(codec) = codec_from_ffi(codec) else {
        return 0;
    };
    if length > 0 && bytes.is_null() {
        return 0;
    }
    let packet = if length == 0 {
        &[]
    } else {
        // SAFETY: The caller provides a readable packet for the duration of
        // this call. The slice never escapes the function.
        unsafe { std::slice::from_raw_parts(bytes, length) }
    };
    dolby_channel_configuration(codec, packet).unwrap_or(0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_dolby_sample_frames(
    codec: u32,
    bytes: *const u8,
    length: usize,
) -> u32 {
    let Some(codec) = codec_from_ffi(codec) else {
        return 0;
    };
    if length > 0 && bytes.is_null() {
        return 0;
    }
    let packet = if length == 0 {
        &[]
    } else {
        // SAFETY: The caller provides a readable packet for the duration of
        // this call. The slice never escapes the function.
        unsafe { std::slice::from_raw_parts(bytes, length) }
    };
    dolby_sample_frames(codec, packet).unwrap_or(0)
}

fn apple_format_description_supported(codec: Codec) -> bool {
    matches!(
        codec,
        Codec::H264
            | Codec::Hevc
            | Codec::Av1
            | Codec::Vp9
            | Codec::Aac
            | Codec::Ac3
            | Codec::Eac3
            | Codec::Flac
            | Codec::Opus
            | Codec::Utf8Subtitle
            | Codec::WebVtt
            | Codec::Ass
            | Codec::Ssa
            | Codec::Pgs
    )
}

fn track_info(track: &MediaTrack) -> StremioMediaTrackInfo {
    let mut flags = 0;
    if track.default {
        flags |= TRACK_FLAG_DEFAULT;
    }
    if track.forced {
        flags |= TRACK_FLAG_FORCED;
    }
    if apple_format_description_supported(track.codec) {
        flags |= TRACK_FLAG_APPLE_DECODABLE;
    }
    StremioMediaTrackInfo {
        abi_version: ABI_VERSION,
        index: track.index,
        number: track.number,
        uid: track.uid,
        kind: track.kind as u32,
        codec: ffi_codec(track.codec),
        flags,
        width: u32::try_from(track.pixel_width).unwrap_or(u32::MAX),
        height: u32::try_from(track.pixel_height).unwrap_or(u32::MAX),
        sample_rate: track.output_sampling_frequency,
        channels: u32::try_from(track.channels).unwrap_or(u32::MAX),
        bit_depth: u32::try_from(track.bit_depth).unwrap_or(u32::MAX),
        default_duration_ns: track.default_duration_ns,
        codec_delay_ns: track.codec_delay_ns,
        codec_private_size: track.codec_private.len(),
    }
}

fn u32_saturated(value: u64) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

fn video_color_info(track: &MediaTrack) -> StremioMediaVideoColorInfo {
    let color = &track.video_color;
    let mut info = StremioMediaVideoColorInfo {
        abi_version: ABI_VERSION,
        ..StremioMediaVideoColorInfo::default()
    };
    if let Some(value) = color.matrix_coefficients {
        info.flags |= VIDEO_COLOR_MATRIX_PRESENT;
        info.matrix_coefficients = u32_saturated(value);
    }
    if let Some(value) = color.bits_per_channel {
        info.flags |= VIDEO_COLOR_BITS_PER_CHANNEL_PRESENT;
        info.bits_per_channel = u32_saturated(value);
    }
    if let Some(value) = color.range {
        info.flags |= VIDEO_COLOR_RANGE_PRESENT;
        info.range = u32_saturated(value);
    }
    if let Some(value) = color.transfer_characteristics {
        info.flags |= VIDEO_COLOR_TRANSFER_PRESENT;
        info.transfer_characteristics = u32_saturated(value);
    }
    if let Some(value) = color.primaries {
        info.flags |= VIDEO_COLOR_PRIMARIES_PRESENT;
        info.primaries = u32_saturated(value);
    }
    if let Some(value) = color.max_cll {
        info.flags |= VIDEO_COLOR_MAX_CLL_PRESENT;
        info.max_cll = u32_saturated(value);
    }
    if let Some(value) = color.max_fall {
        info.flags |= VIDEO_COLOR_MAX_FALL_PRESENT;
        info.max_fall = u32_saturated(value);
    }
    if let Some(mastering) = color.mastering_metadata.as_ref()
        && let (
            Some(primary_r_x),
            Some(primary_r_y),
            Some(primary_g_x),
            Some(primary_g_y),
            Some(primary_b_x),
            Some(primary_b_y),
            Some(white_point_x),
            Some(white_point_y),
            Some(luminance_max),
            Some(luminance_min),
        ) = (
            mastering.primary_r_x,
            mastering.primary_r_y,
            mastering.primary_g_x,
            mastering.primary_g_y,
            mastering.primary_b_x,
            mastering.primary_b_y,
            mastering.white_point_x,
            mastering.white_point_y,
            mastering.luminance_max,
            mastering.luminance_min,
        )
    {
        info.flags |= VIDEO_COLOR_MASTERING_PRESENT;
        info.primary_r_x = primary_r_x;
        info.primary_r_y = primary_r_y;
        info.primary_g_x = primary_g_x;
        info.primary_g_y = primary_g_y;
        info.primary_b_x = primary_b_x;
        info.primary_b_y = primary_b_y;
        info.white_point_x = white_point_x;
        info.white_point_y = white_point_y;
        info.luminance_max = luminance_max;
        info.luminance_min = luminance_min;
    }
    info
}

fn hdr10_plus_data<'a>(packet: &'a MediaPacket, track: &MediaTrack) -> Option<&'a [u8]> {
    packet.block_additions.iter().find_map(|addition| {
        let is_hdr10_plus = track.block_addition_mappings.iter().any(|mapping| {
            mapping.id_value == addition.id && mapping.id_type == BLOCK_ADD_ID_TYPE_ITU_T_T35
        });
        is_hdr10_plus.then_some(addition.data.as_slice())
    })
}

fn requested_kind(value: u32) -> Option<TrackKind> {
    match value {
        1 => Some(TrackKind::Video),
        2 => Some(TrackKind::Audio),
        3 => Some(TrackKind::Subtitle),
        _ => None,
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn stremio_media_open_matroska(
    callbacks: SourceCallbacks,
    context: *mut c_void,
    error_message: *mut c_char,
    error_capacity: usize,
) -> *mut StremioMediaSession {
    let result = CallbackSource::new(callbacks, context)
        .and_then(|source| MatroskaSession::open_streaming(Box::new(source)));
    match result {
        Ok(session) => Box::into_raw(Box::new(StremioMediaSession {
            session,
            last_packet: None,
        })),
        Err(error) => {
            write_message(error_message, error_capacity, &error.to_string());
            ptr::null_mut()
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_session_destroy(session: *mut StremioMediaSession) {
    if !session.is_null() {
        // SAFETY: The caller passes the unique pointer returned by open and
        // destroys it no more than once.
        drop(unsafe { Box::from_raw(session) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_summary(
    session: *const StremioMediaSession,
) -> StremioMediaSummary {
    if session.is_null() {
        return StremioMediaSummary {
            abi_version: ABI_VERSION,
            ..StremioMediaSummary::default()
        };
    }
    // SAFETY: Null was checked and the ABI requires a live session pointer.
    let summary = unsafe { &*session }.session.summary();
    StremioMediaSummary {
        abi_version: ABI_VERSION,
        container_kind: if summary.document_type == "webm" {
            2
        } else {
            1
        },
        duration_ns: summary.duration_ns,
        timecode_scale_ns: summary.timestamp_scale_ns,
        track_count: summary.track_count,
        cue_count: summary.cue_count,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_track_info(
    session: *const StremioMediaSession,
    track_index: u32,
    output: *mut StremioMediaTrackInfo,
) -> i32 {
    if session.is_null() || output.is_null() {
        return 0;
    }
    // SAFETY: Pointers were checked and the ABI requires live storage.
    let session = unsafe { &*session };
    let Some(track) = session.session.tracks().get(track_index as usize) else {
        return 0;
    };
    unsafe { output.write(track_info(track)) };
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_track_video_color_info(
    session: *const StremioMediaSession,
    track_index: u32,
    output: *mut StremioMediaVideoColorInfo,
) -> i32 {
    if session.is_null() || output.is_null() {
        return 0;
    }
    // SAFETY: Pointers were checked and the ABI requires live storage.
    let session = unsafe { &*session };
    let Some(track) = session.session.tracks().get(track_index as usize) else {
        return 0;
    };
    unsafe { output.write(video_color_info(track)) };
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_track_block_addition_mapping_count(
    session: *const StremioMediaSession,
    track_index: u32,
) -> u32 {
    if session.is_null() {
        return 0;
    }
    // SAFETY: Null was checked and the ABI requires a live session pointer.
    let session = unsafe { &*session };
    session
        .session
        .tracks()
        .get(track_index as usize)
        .map(|track| u32::try_from(track.block_addition_mappings.len()).unwrap_or(u32::MAX))
        .unwrap_or(0)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_track_block_addition_mapping_info(
    session: *const StremioMediaSession,
    track_index: u32,
    mapping_index: u32,
    output: *mut StremioMediaBlockAdditionMappingInfo,
) -> i32 {
    if session.is_null() || output.is_null() {
        return 0;
    }
    // SAFETY: Pointers were checked and the ABI requires live storage.
    let session = unsafe { &*session };
    let Some(mapping) = session
        .session
        .tracks()
        .get(track_index as usize)
        .and_then(|track| track.block_addition_mappings.get(mapping_index as usize))
    else {
        return 0;
    };
    unsafe {
        output.write(StremioMediaBlockAdditionMappingInfo {
            abi_version: ABI_VERSION,
            reserved: 0,
            id_value: mapping.id_value,
            id_type: mapping.id_type,
            extra_data: if mapping.extra_data.is_empty() {
                ptr::null()
            } else {
                mapping.extra_data.as_ptr()
            },
            extra_data_size: mapping.extra_data.len(),
        })
    };
    1
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_track_text(
    session: *const StremioMediaSession,
    track_index: u32,
    field: u32,
    output: *mut c_char,
    capacity: usize,
) -> usize {
    if session.is_null() {
        write_message(output, capacity, "");
        return 0;
    }
    // SAFETY: Null was checked and the ABI requires a live session pointer.
    let session = unsafe { &*session };
    let Some(track) = session.session.tracks().get(track_index as usize) else {
        write_message(output, capacity, "");
        return 0;
    };
    let value = match field {
        1 => &track.codec_id,
        2 => &track.name,
        3 => &track.language,
        _ => "",
    };
    write_text(output, capacity, value)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_track_codec_private(
    session: *const StremioMediaSession,
    track_index: u32,
    length: *mut usize,
) -> *const u8 {
    if !length.is_null() {
        unsafe { length.write(0) };
    }
    if session.is_null() {
        return ptr::null();
    }
    // SAFETY: Null was checked and the ABI requires a live session pointer.
    let session = unsafe { &*session };
    let Some(track) = session.session.tracks().get(track_index as usize) else {
        return ptr::null();
    };
    if !length.is_null() {
        unsafe { length.write(track.codec_private.len()) };
    }
    if track.codec_private.is_empty() {
        ptr::null()
    } else {
        track.codec_private.as_ptr()
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_select_track(
    session: *mut StremioMediaSession,
    track_kind: u32,
    track_index: i32,
) -> i32 {
    if session.is_null() {
        return 0;
    }
    let Some(kind) = requested_kind(track_kind) else {
        return 0;
    };
    // SAFETY: Null was checked and the ABI requires exclusive access for this
    // mutating call.
    let session = unsafe { &mut *session };
    session.last_packet = None;
    if track_index < 0 {
        session.session.set_kind_selected(kind, false);
        return 1;
    }
    let index = track_index as usize;
    if session.session.tracks().get(index).map(|track| track.kind) != Some(kind) {
        return 0;
    }
    if session.session.select_track(index).is_ok() {
        1
    } else {
        0
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_seek(
    session: *mut StremioMediaSession,
    presentation_time_ns: u64,
    error_message: *mut c_char,
    error_capacity: usize,
) -> i32 {
    if session.is_null() {
        write_message(error_message, error_capacity, "media session is null");
        return 0;
    }
    // SAFETY: Null was checked and the ABI requires exclusive access for this
    // mutating call.
    let session = unsafe { &mut *session };
    session.last_packet = None;
    match session.session.seek(presentation_time_ns) {
        Ok(()) => 1,
        Err(error) => {
            write_message(error_message, error_capacity, &error.to_string());
            0
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_rewind(
    session: *mut StremioMediaSession,
    error_message: *mut c_char,
    error_capacity: usize,
) -> i32 {
    if session.is_null() {
        write_message(error_message, error_capacity, "media session is null");
        return 0;
    }
    // SAFETY: Null was checked and the ABI requires exclusive access for this
    // mutating call.
    let session = unsafe { &mut *session };
    session.last_packet = None;
    match session.session.rewind() {
        Ok(()) => 1,
        Err(error) => {
            write_message(error_message, error_capacity, &error.to_string());
            0
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_prepare_seek_index(
    session: *mut StremioMediaSession,
    error_message: *mut c_char,
    error_capacity: usize,
) -> i32 {
    if session.is_null() {
        write_message(error_message, error_capacity, "media session is null");
        return 0;
    }
    // SAFETY: Null was checked and the ABI requires exclusive access for this
    // mutating call.
    let session = unsafe { &mut *session };
    match session.session.prepare_seek_index() {
        Ok(()) => 1,
        Err(error) => {
            write_message(error_message, error_capacity, &error.to_string());
            0
        }
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_media_next_packet(
    session: *mut StremioMediaSession,
    output: *mut StremioMediaPacket,
    error_message: *mut c_char,
    error_capacity: usize,
) -> i32 {
    if session.is_null() || output.is_null() {
        write_message(
            error_message,
            error_capacity,
            "media session or packet output is null",
        );
        return -1;
    }
    // SAFETY: Pointers were checked and the ABI requires exclusive access for
    // this mutating call.
    let session = unsafe { &mut *session };
    session.last_packet = None;
    match session.session.next_packet() {
        Ok(Some(packet)) => {
            session.last_packet = Some(packet);
            let packet = session
                .last_packet
                .as_ref()
                .expect("packet was just stored");
            let hdr10_plus = session
                .session
                .tracks()
                .get(packet.track_index as usize)
                .and_then(|track| hdr10_plus_data(packet, track));
            unsafe {
                output.write(StremioMediaPacket {
                    abi_version: MEDIA_PACKET_ABI_VERSION,
                    track_index: packet.track_index,
                    presentation_time_ns: packet.timestamp_ns,
                    decode_time_ns: packet.decode_timestamp_ns,
                    duration_ns: packet.duration_ns,
                    flags: packet.flags.0,
                    data: packet.payload.as_ptr(),
                    data_size: packet.payload.len(),
                    hdr10_plus_data: hdr10_plus.map_or(ptr::null(), <[u8]>::as_ptr),
                    hdr10_plus_data_size: hdr10_plus.map_or(0, <[u8]>::len),
                })
            };
            1
        }
        Ok(None) => 0,
        Err(error) => {
            write_message(error_message, error_capacity, &error.to_string());
            -1
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn stremio_pgs_decoder_create() -> *mut StremioPgsDecoder {
    Box::into_raw(Box::new(StremioPgsDecoder {
        decoder: PgsDecoder::new(),
        presentation: None,
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_pgs_decoder_destroy(decoder: *mut StremioPgsDecoder) {
    if !decoder.is_null() {
        // SAFETY: The caller passes the unique pointer returned by create and
        // destroys it no more than once.
        drop(unsafe { Box::from_raw(decoder) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_pgs_decoder_reset(decoder: *mut StremioPgsDecoder) {
    if decoder.is_null() {
        return;
    }
    // SAFETY: Null was checked and the ABI requires exclusive access.
    let decoder = unsafe { &mut *decoder };
    decoder.decoder.reset();
    decoder.presentation = None;
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_pgs_push_matroska_packet(
    decoder: *mut StremioPgsDecoder,
    presentation_time_ns: i64,
    bytes: *const u8,
    length: usize,
    error_message: *mut c_char,
    error_capacity: usize,
) -> i32 {
    if decoder.is_null() || (bytes.is_null() && length != 0) {
        write_message(
            error_message,
            error_capacity,
            "PGS decoder or packet is null",
        );
        return -1;
    }
    // SAFETY: Non-empty packet pointers were checked; the packet is borrowed
    // only for this call. Empty packets avoid constructing a slice from null.
    let packet = if length == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(bytes, length) }
    };
    let decoder = unsafe { &mut *decoder };
    decoder.presentation = None;
    let timestamp_ns = presentation_time_ns.max(0) as u64;
    let pts_90khz =
        ((u128::from(timestamp_ns) * 90_000) / 1_000_000_000).min(u128::from(u64::MAX)) as u64;
    let mut offset = 0_usize;
    while offset < packet.len() {
        if packet.len().saturating_sub(offset) < 3 {
            write_message(
                error_message,
                error_capacity,
                "truncated Matroska PGS segment header",
            );
            return -1;
        }
        let segment_type = packet[offset];
        let payload_length =
            usize::from(u16::from_be_bytes([packet[offset + 1], packet[offset + 2]]));
        let payload_start = offset + 3;
        let Some(end) = payload_start.checked_add(payload_length) else {
            write_message(error_message, error_capacity, "PGS segment length overflow");
            return -1;
        };
        if end > packet.len() {
            write_message(
                error_message,
                error_capacity,
                "truncated Matroska PGS segment",
            );
            return -1;
        }
        match decoder
            .decoder
            .push_segment(pts_90khz, segment_type, &packet[payload_start..end])
        {
            Ok(Some(presentation)) => decoder.presentation = Some(presentation),
            Ok(None) => {}
            Err(error) => {
                write_message(error_message, error_capacity, &error.to_string());
                return -1;
            }
        }
        offset = end;
    }
    if decoder.presentation.is_some() { 1 } else { 0 }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_pgs_presentation(
    decoder: *const StremioPgsDecoder,
) -> StremioPgsPresentationInfo {
    if decoder.is_null() {
        return StremioPgsPresentationInfo {
            abi_version: ABI_VERSION,
            ..StremioPgsPresentationInfo::default()
        };
    }
    // SAFETY: Null was checked and the ABI requires a live decoder pointer.
    let decoder = unsafe { &*decoder };
    let Some(presentation) = decoder.presentation.as_ref() else {
        return StremioPgsPresentationInfo {
            abi_version: ABI_VERSION,
            ..StremioPgsPresentationInfo::default()
        };
    };
    StremioPgsPresentationInfo {
        abi_version: ABI_VERSION,
        presentation_time_ns: presentation.pts_us.saturating_mul(1_000),
        canvas_width: u32::from(presentation.canvas_width),
        canvas_height: u32::from(presentation.canvas_height),
        part_count: u32::try_from(presentation.parts.len()).unwrap_or(u32::MAX),
        is_clear: u8::from(presentation.is_clear()),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn stremio_pgs_part(
    decoder: *const StremioPgsDecoder,
    part_index: u32,
    output: *mut StremioPgsPartInfo,
) -> i32 {
    if decoder.is_null() || output.is_null() {
        return 0;
    }
    // SAFETY: Pointers were checked and the ABI requires live storage.
    let decoder = unsafe { &*decoder };
    let Some(part) = decoder
        .presentation
        .as_ref()
        .and_then(|presentation| presentation.parts.get(part_index as usize))
    else {
        return 0;
    };
    unsafe {
        output.write(StremioPgsPartInfo {
            abi_version: ABI_VERSION,
            x: u32::from(part.x),
            y: u32::from(part.y),
            width: u32::from(part.width),
            height: u32::from(part.height),
            forced: u8::from(part.forced),
            rgba: part.rgba.as_ptr(),
            rgba_size: part.rgba.len(),
        })
    };
    1
}
