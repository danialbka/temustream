use std::collections::{HashSet, VecDeque};

use super::ebml::{
    ElementHeader, MAX_METADATA_ELEMENT_LENGTH, MediaError, ReadAt, parse_id, parse_signed_vint,
    parse_vint_value, read_bytes, read_float, read_header, read_string, read_uint,
};

const ID_EBML: u64 = 0x1a45dfa3;
const ID_SEGMENT: u64 = 0x18538067;
const ID_SEEK_HEAD: u64 = 0x114d9b74;
const ID_SEEK: u64 = 0x4dbb;
const ID_SEEK_ID: u64 = 0x53ab;
const ID_SEEK_POSITION: u64 = 0x53ac;
const ID_INFO: u64 = 0x1549a966;
const ID_TRACKS: u64 = 0x1654ae6b;
const ID_CUES: u64 = 0x1c53bb6b;
const ID_CLUSTER: u64 = 0x1f43b675;
const ID_ATTACHMENTS: u64 = 0x1941a469;
const ID_CHAPTERS: u64 = 0x1043a770;
const ID_TAGS: u64 = 0x1254c367;

const ID_DOC_TYPE: u64 = 0x4282;
const ID_DOC_TYPE_VERSION: u64 = 0x4287;
const ID_DOC_TYPE_READ_VERSION: u64 = 0x4285;

const ID_TIMESTAMP_SCALE: u64 = 0x2ad7b1;
const ID_DURATION: u64 = 0x4489;
const ID_TITLE: u64 = 0x7ba9;
const ID_MUXING_APP: u64 = 0x4d80;
const ID_WRITING_APP: u64 = 0x5741;

const ID_TRACK_ENTRY: u64 = 0xae;
const ID_TRACK_NUMBER: u64 = 0xd7;
const ID_TRACK_UID: u64 = 0x73c5;
const ID_TRACK_TYPE: u64 = 0x83;
const ID_FLAG_ENABLED: u64 = 0xb9;
const ID_FLAG_DEFAULT: u64 = 0x88;
const ID_FLAG_FORCED: u64 = 0x55aa;
const ID_FLAG_LACING: u64 = 0x9c;
const ID_DEFAULT_DURATION: u64 = 0x23e383;
const ID_TRACK_TIMESTAMP_SCALE: u64 = 0x23314f;
const ID_NAME: u64 = 0x536e;
const ID_LANGUAGE: u64 = 0x22b59c;
const ID_LANGUAGE_IETF: u64 = 0x22b59d;
const ID_CODEC_ID: u64 = 0x86;
const ID_CODEC_PRIVATE: u64 = 0x63a2;
const ID_CODEC_NAME: u64 = 0x258688;
const ID_CODEC_DELAY: u64 = 0x56aa;
const ID_SEEK_PRE_ROLL: u64 = 0x56bb;
const ID_VIDEO: u64 = 0xe0;
const ID_AUDIO: u64 = 0xe1;
const ID_PIXEL_WIDTH: u64 = 0xb0;
const ID_PIXEL_HEIGHT: u64 = 0xba;
const ID_DISPLAY_WIDTH: u64 = 0x54b0;
const ID_DISPLAY_HEIGHT: u64 = 0x54ba;
const ID_FRAME_RATE: u64 = 0x2383e3;
const ID_SAMPLING_FREQUENCY: u64 = 0xb5;
const ID_OUTPUT_SAMPLING_FREQUENCY: u64 = 0x78b5;
const ID_CHANNELS: u64 = 0x9f;
const ID_BIT_DEPTH: u64 = 0x6264;

const ID_CUE_POINT: u64 = 0xbb;
const ID_CUE_TIME: u64 = 0xb3;
const ID_CUE_TRACK_POSITIONS: u64 = 0xb7;
const ID_CUE_TRACK: u64 = 0xf7;
const ID_CUE_CLUSTER_POSITION: u64 = 0xf1;
const ID_CUE_RELATIVE_POSITION: u64 = 0xf0;
const ID_CUE_DURATION: u64 = 0xb2;
const ID_CUE_BLOCK_NUMBER: u64 = 0x5378;

const ID_CLUSTER_TIMESTAMP: u64 = 0xe7;
const ID_SIMPLE_BLOCK: u64 = 0xa3;
const ID_BLOCK_GROUP: u64 = 0xa0;
const ID_BLOCK: u64 = 0xa1;
const ID_BLOCK_DURATION: u64 = 0x9b;
const ID_REFERENCE_BLOCK: u64 = 0xfb;
const ID_DISCARD_PADDING: u64 = 0x75a2;

const DEFAULT_TIMESTAMP_SCALE_NS: u64 = 1_000_000;
const MAX_BLOCK_ELEMENT_LENGTH: u64 = 16 * 1024 * 1024;
const MAX_TRACKS: usize = 256;
const MAX_CUES: usize = 200_000;
const MAX_CUE_TRACK_POSITIONS: usize = 64;
const MAX_DEFERRED_SEEK_TARGETS: usize = 1_024;
const MAX_CLUSTERS: usize = 250_000;
const MAX_SEGMENT_ELEMENTS: usize = 500_000;
const MAX_UNKNOWN_CLUSTER_SCAN_BYTES: u64 = 64 * 1024 * 1024;
const MAX_AGGREGATE_TRACK_METADATA_BYTES: usize = 32 * 1024 * 1024;
const MAX_VIDEO_DIMENSION: u64 = 16_384;
const MAX_VIDEO_FRAME_RATE: f64 = 1_000.0;
const MAX_AUDIO_CHANNELS: u64 = 32;
const MAX_AUDIO_BIT_DEPTH: u64 = 64;
const MAX_AUDIO_SAMPLE_RATE: f64 = 768_000.0;
const SUPPORTED_DOCUMENT_READ_VERSION: u64 = 4;

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrackKind {
    Other = 0,
    Video = 1,
    Audio = 2,
    Subtitle = 3,
}

#[repr(u32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Codec {
    Unknown = 0,
    H264 = 1,
    Hevc = 2,
    Av1 = 3,
    Vp8 = 4,
    Vp9 = 5,
    Mpeg2Video = 6,
    Theora = 7,
    Aac = 100,
    Opus = 101,
    Vorbis = 102,
    Flac = 103,
    Ac3 = 104,
    Eac3 = 105,
    TrueHd = 106,
    Dts = 107,
    Pcm = 108,
    Mp3 = 109,
    Mp2 = 110,
    Utf8Subtitle = 200,
    Ass = 201,
    Ssa = 202,
    WebVtt = 203,
    Pgs = 204,
    VobSub = 205,
}

impl Codec {
    fn from_matroska_id(codec_id: &str) -> Self {
        match codec_id {
            "V_MPEG4/ISO/AVC" => Self::H264,
            "V_MPEGH/ISO/HEVC" => Self::Hevc,
            "V_AV1" => Self::Av1,
            "V_VP8" => Self::Vp8,
            "V_VP9" => Self::Vp9,
            "V_MPEG2" => Self::Mpeg2Video,
            "V_THEORA" => Self::Theora,
            id if id.starts_with("A_AAC") => Self::Aac,
            "A_OPUS" => Self::Opus,
            "A_VORBIS" => Self::Vorbis,
            "A_FLAC" => Self::Flac,
            "A_AC3" => Self::Ac3,
            "A_EAC3" => Self::Eac3,
            "A_TRUEHD" => Self::TrueHd,
            id if id.starts_with("A_DTS") => Self::Dts,
            id if id.starts_with("A_PCM/") => Self::Pcm,
            "A_MPEG/L3" => Self::Mp3,
            "A_MPEG/L2" => Self::Mp2,
            "S_TEXT/UTF8" => Self::Utf8Subtitle,
            "S_TEXT/ASS" => Self::Ass,
            "S_TEXT/SSA" => Self::Ssa,
            id if id.starts_with("S_TEXT/WEBVTT") => Self::WebVtt,
            "S_HDMV/PGS" => Self::Pgs,
            "S_VOBSUB" => Self::VobSub,
            _ => Self::Unknown,
        }
    }
}

#[repr(transparent)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PacketFlags(pub u32);

impl PacketFlags {
    pub const KEYFRAME: Self = Self(1 << 0);
    pub const INVISIBLE: Self = Self(1 << 1);
    pub const DISCARDABLE: Self = Self(1 << 2);
    pub const LACED: Self = Self(1 << 3);

    pub const fn empty() -> Self {
        Self(0)
    }

    pub const fn contains(self, flag: Self) -> bool {
        self.0 & flag.0 == flag.0
    }

    fn insert(&mut self, flag: Self) {
        self.0 |= flag.0;
    }
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct ContainerSummary {
    pub document_type: String,
    pub document_type_version: u64,
    pub document_type_read_version: u64,
    pub timestamp_scale_ns: u64,
    pub duration_ns: u64,
    pub title: String,
    pub muxing_app: String,
    pub writing_app: String,
    pub segment_data_offset: u64,
    pub segment_data_size: u64,
    pub track_count: u32,
    pub cue_count: u32,
    pub cluster_count: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MediaTrack {
    pub index: u32,
    pub number: u64,
    pub uid: u64,
    pub kind: TrackKind,
    pub codec: Codec,
    pub codec_id: String,
    pub codec_name: String,
    pub name: String,
    pub language: String,
    pub enabled: bool,
    pub default: bool,
    pub forced: bool,
    pub lacing: bool,
    pub timestamp_scale: f64,
    pub default_duration_ns: u64,
    pub codec_delay_ns: u64,
    pub seek_pre_roll_ns: u64,
    pub codec_private: Vec<u8>,
    pub pixel_width: u64,
    pub pixel_height: u64,
    pub display_width: u64,
    pub display_height: u64,
    pub frame_rate: f64,
    pub sampling_frequency: f64,
    pub output_sampling_frequency: f64,
    pub channels: u64,
    pub bit_depth: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CuePoint {
    pub time_ns: u64,
    pub track_number: u64,
    pub cluster_offset: u64,
    pub relative_position: u64,
    pub duration_ns: u64,
    pub block_number: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MediaPacket {
    pub track_index: u32,
    pub track_number: u64,
    pub timestamp_ns: i64,
    pub duration_ns: u64,
    pub discard_padding_ns: i64,
    pub flags: PacketFlags,
    pub payload: Vec<u8>,
}

#[derive(Clone, Copy, Debug)]
struct ClusterIndex {
    offset: u64,
    data_offset: u64,
    end: u64,
    timestamp_units: u64,
}

#[derive(Clone, Debug)]
struct RawCuePoint {
    time_units: u64,
    track_number: u64,
    cluster_position: u64,
    relative_position: u64,
    duration_units: u64,
    block_number: u64,
}

#[derive(Clone, Debug)]
struct TrackBuilder {
    number: u64,
    uid: u64,
    kind: TrackKind,
    codec_id: String,
    codec_name: String,
    name: String,
    language: String,
    enabled: bool,
    default: bool,
    forced: bool,
    lacing: bool,
    timestamp_scale: f64,
    default_duration_ns: u64,
    codec_delay_ns: u64,
    seek_pre_roll_ns: u64,
    codec_private: Vec<u8>,
    pixel_width: u64,
    pixel_height: u64,
    display_width: u64,
    display_height: u64,
    frame_rate: f64,
    sampling_frequency: f64,
    output_sampling_frequency: f64,
    channels: u64,
    bit_depth: u64,
}

impl Default for TrackBuilder {
    fn default() -> Self {
        Self {
            number: 0,
            uid: 0,
            kind: TrackKind::Other,
            codec_id: String::new(),
            codec_name: String::new(),
            name: String::new(),
            language: "eng".to_owned(),
            enabled: true,
            default: true,
            forced: false,
            lacing: true,
            timestamp_scale: 1.0,
            default_duration_ns: 0,
            codec_delay_ns: 0,
            seek_pre_roll_ns: 0,
            codec_private: Vec::new(),
            pixel_width: 0,
            pixel_height: 0,
            display_width: 0,
            display_height: 0,
            frame_rate: 0.0,
            sampling_frequency: 8_000.0,
            output_sampling_frequency: 0.0,
            channels: 1,
            bit_depth: 0,
        }
    }
}

impl TrackBuilder {
    fn finish(mut self, index: usize) -> Result<MediaTrack, MediaError> {
        if self.number == 0 {
            return Err(MediaError::InvalidData("track number is zero"));
        }
        if self.codec_id.is_empty() {
            return Err(MediaError::InvalidData("track codec id is missing"));
        }
        if !self.timestamp_scale.is_finite() || self.timestamp_scale <= 0.0 {
            return Err(MediaError::InvalidData("invalid track timestamp scale"));
        }
        if self.display_width == 0 {
            self.display_width = self.pixel_width;
        }
        if self.display_height == 0 {
            self.display_height = self.pixel_height;
        }
        if self.output_sampling_frequency == 0.0 {
            self.output_sampling_frequency = self.sampling_frequency;
        }
        if self.kind == TrackKind::Video {
            if self.pixel_width == 0
                || self.pixel_height == 0
                || self.pixel_width > MAX_VIDEO_DIMENSION
                || self.pixel_height > MAX_VIDEO_DIMENSION
                || self.display_width > MAX_VIDEO_DIMENSION
                || self.display_height > MAX_VIDEO_DIMENSION
            {
                return Err(MediaError::InvalidData(
                    "video dimensions exceed safety limit",
                ));
            }
            if !self.frame_rate.is_finite()
                || self.frame_rate < 0.0
                || self.frame_rate > MAX_VIDEO_FRAME_RATE
            {
                return Err(MediaError::InvalidData("invalid video frame rate"));
            }
        }
        if self.kind == TrackKind::Audio {
            if !self.sampling_frequency.is_finite()
                || self.sampling_frequency <= 0.0
                || self.sampling_frequency > MAX_AUDIO_SAMPLE_RATE
                || !self.output_sampling_frequency.is_finite()
                || self.output_sampling_frequency <= 0.0
                || self.output_sampling_frequency > MAX_AUDIO_SAMPLE_RATE
            {
                return Err(MediaError::InvalidData("invalid audio sample rate"));
            }
            if self.channels == 0 || self.channels > MAX_AUDIO_CHANNELS {
                return Err(MediaError::InvalidData(
                    "audio channel count exceeds safety limit",
                ));
            }
            if self.bit_depth > MAX_AUDIO_BIT_DEPTH {
                return Err(MediaError::InvalidData(
                    "audio bit depth exceeds safety limit",
                ));
            }
        }
        Ok(MediaTrack {
            index: u32::try_from(index).map_err(|_| MediaError::ArithmeticOverflow)?,
            number: self.number,
            uid: self.uid,
            kind: self.kind,
            codec: Codec::from_matroska_id(&self.codec_id),
            codec_id: self.codec_id,
            codec_name: self.codec_name,
            name: self.name,
            language: self.language,
            enabled: self.enabled,
            default: self.default,
            forced: self.forced,
            lacing: self.lacing,
            timestamp_scale: self.timestamp_scale,
            default_duration_ns: self.default_duration_ns,
            codec_delay_ns: self.codec_delay_ns,
            seek_pre_roll_ns: self.seek_pre_roll_ns,
            codec_private: self.codec_private,
            pixel_width: self.pixel_width,
            pixel_height: self.pixel_height,
            display_width: self.display_width,
            display_height: self.display_height,
            frame_rate: self.frame_rate,
            sampling_frequency: self.sampling_frequency,
            output_sampling_frequency: self.output_sampling_frequency,
            channels: self.channels,
            bit_depth: self.bit_depth,
        })
    }
}

#[derive(Clone, Debug)]
struct ParsedBlock {
    track_number: u64,
    relative_timestamp: i16,
    flags: u8,
    frames: Vec<(usize, usize)>,
}

pub struct MatroskaSession {
    source: Box<dyn ReadAt>,
    summary: ContainerSummary,
    tracks: Vec<MediaTrack>,
    cues: Vec<CuePoint>,
    deferred_seek_targets: Vec<(u64, u64)>,
    clusters: Vec<ClusterIndex>,
    segment_end: u64,
    next_segment_offset: u64,
    streaming_index: bool,
    selected_tracks: Vec<bool>,
    cluster_index: usize,
    cluster_cursor: u64,
    pending_packets: VecDeque<MediaPacket>,
}

impl MatroskaSession {
    pub fn open(source: Box<dyn ReadAt>) -> Result<Self, MediaError> {
        Self::open_with_index_mode(source, false)
    }

    /// Opens a range-backed source after indexing only enough metadata to
    /// decode its first cluster. Later clusters are discovered as playback or
    /// seeking reaches them, avoiding one HTTP range transaction per cluster
    /// before the first frame can be shown.
    pub fn open_streaming(source: Box<dyn ReadAt>) -> Result<Self, MediaError> {
        Self::open_with_index_mode(source, true)
    }

    fn open_with_index_mode(
        mut source: Box<dyn ReadAt>,
        streaming_index: bool,
    ) -> Result<Self, MediaError> {
        let source_length = source.len();
        if source_length < 8 {
            return Err(MediaError::UnexpectedEnd);
        }

        let (mut summary, mut cursor) = parse_ebml_header(source.as_mut())?;
        let segment_header = loop {
            if cursor >= source_length {
                return Err(MediaError::InvalidData("segment element is missing"));
            }
            let header = read_header(source.as_mut(), cursor)?;
            if header.id == ID_SEGMENT {
                break header;
            }
            cursor = element_end(header, source_length)?;
        };

        let segment_end = match segment_header.size {
            Some(_) => element_end(segment_header, source_length)?,
            None => source_length,
        };
        summary.segment_data_offset = segment_header.data_offset;
        summary.segment_data_size = segment_end
            .checked_sub(segment_header.data_offset)
            .ok_or(MediaError::ArithmeticOverflow)?;
        summary.timestamp_scale_ns = DEFAULT_TIMESTAMP_SCALE_NS;

        let mut duration_units = None;
        let mut tracks = Vec::new();
        let mut raw_cues = Vec::new();
        let mut deferred_seek_targets = Vec::new();
        let mut clusters = Vec::new();
        let mut segment_element_count = 0_usize;
        let mut next_segment_offset = segment_end;
        cursor = segment_header.data_offset;

        while cursor < segment_end {
            segment_element_count = segment_element_count
                .checked_add(1)
                .ok_or(MediaError::ArithmeticOverflow)?;
            if segment_element_count > MAX_SEGMENT_ELEMENTS {
                return Err(MediaError::ElementTooLarge);
            }
            let header = read_header(source.as_mut(), cursor)?;
            match header.id {
                ID_SEEK_HEAD => {
                    let end = element_end(header, segment_end)?;
                    if streaming_index {
                        parse_seek_head(
                            source.as_mut(),
                            header.data_offset,
                            end,
                            &mut deferred_seek_targets,
                        )?;
                    }
                    cursor = end;
                }
                ID_INFO => {
                    let end = element_end(header, segment_end)?;
                    parse_info(
                        source.as_mut(),
                        header.data_offset,
                        end,
                        &mut summary,
                        &mut duration_units,
                    )?;
                    cursor = end;
                }
                ID_TRACKS => {
                    let end = element_end(header, segment_end)?;
                    parse_tracks(source.as_mut(), header.data_offset, end, &mut tracks)?;
                    cursor = end;
                }
                ID_CUES => {
                    let end = element_end(header, segment_end)?;
                    parse_cues(source.as_mut(), header.data_offset, end, &mut raw_cues)?;
                    cursor = end;
                }
                ID_CLUSTER => {
                    if clusters.len() >= MAX_CLUSTERS {
                        return Err(MediaError::ElementTooLarge);
                    }
                    let (cluster, next) = index_cluster(source.as_mut(), header, segment_end)?;
                    clusters.push(cluster);
                    cursor = next;
                    if streaming_index && !tracks.is_empty() {
                        next_segment_offset = next;
                        break;
                    }
                }
                _ => {
                    cursor = element_end(header, segment_end)?;
                }
            }
        }

        if summary.document_type != "matroska" && summary.document_type != "webm" {
            return Err(MediaError::Unsupported(
                "EBML document is not Matroska or WebM",
            ));
        }
        if summary.document_type_read_version > SUPPORTED_DOCUMENT_READ_VERSION {
            return Err(MediaError::Unsupported(
                "Matroska document requires a newer reader version",
            ));
        }
        if summary.timestamp_scale_ns == 0 {
            return Err(MediaError::InvalidData("timestamp scale is zero"));
        }
        if let Some(units) = duration_units {
            summary.duration_ns = scaled_float_to_u64(units, summary.timestamp_scale_ns)?;
        }

        let mut aggregate_track_metadata_bytes = summary
            .title
            .len()
            .checked_add(summary.muxing_app.len())
            .and_then(|value| value.checked_add(summary.writing_app.len()))
            .ok_or(MediaError::ArithmeticOverflow)?;
        for track in &tracks {
            aggregate_track_metadata_bytes = aggregate_track_metadata_bytes
                .checked_add(track.codec_id.len())
                .and_then(|value| value.checked_add(track.codec_name.len()))
                .and_then(|value| value.checked_add(track.name.len()))
                .and_then(|value| value.checked_add(track.language.len()))
                .and_then(|value| value.checked_add(track.codec_private.len()))
                .ok_or(MediaError::ArithmeticOverflow)?;
            if aggregate_track_metadata_bytes > MAX_AGGREGATE_TRACK_METADATA_BYTES {
                return Err(MediaError::ElementTooLarge);
            }
        }

        for (index, track) in tracks.iter_mut().enumerate() {
            track.index = u32::try_from(index).map_err(|_| MediaError::ArithmeticOverflow)?;
        }
        let mut track_numbers = HashSet::with_capacity(tracks.len());
        for track in &tracks {
            if !track_numbers.insert(track.number) {
                return Err(MediaError::InvalidData("duplicate track number"));
            }
        }

        let cues = resolve_cues(raw_cues, &summary, segment_end)?;

        summary.track_count = saturating_u32(tracks.len());
        summary.cue_count = saturating_u32(cues.len());
        summary.cluster_count = saturating_u32(clusters.len());
        let selected_tracks = tracks.iter().map(|track| track.enabled).collect();
        let cluster_cursor = clusters
            .first()
            .map_or(segment_end, |cluster| cluster.data_offset);

        Ok(Self {
            source,
            summary,
            tracks,
            cues,
            deferred_seek_targets,
            clusters,
            segment_end,
            next_segment_offset,
            streaming_index,
            selected_tracks,
            cluster_index: 0,
            cluster_cursor,
            pending_packets: VecDeque::new(),
        })
    }

    pub fn summary(&self) -> ContainerSummary {
        self.summary.clone()
    }

    pub fn tracks(&self) -> &[MediaTrack] {
        &self.tracks
    }

    pub fn cues(&self) -> &[CuePoint] {
        &self.cues
    }

    pub fn is_track_selected(&self, index: usize) -> bool {
        self.selected_tracks.get(index).copied().unwrap_or(false)
    }

    pub fn set_track_selected(&mut self, index: usize, selected: bool) -> Result<(), MediaError> {
        let value = self
            .selected_tracks
            .get_mut(index)
            .ok_or(MediaError::InvalidData("track index is out of range"))?;
        *value = selected;
        self.pending_packets.clear();
        Ok(())
    }

    /// Selects one track and deselects its siblings of the same kind.
    pub fn select_track(&mut self, index: usize) -> Result<(), MediaError> {
        let kind = self
            .tracks
            .get(index)
            .ok_or(MediaError::InvalidData("track index is out of range"))?
            .kind;
        for (track_index, track) in self.tracks.iter().enumerate() {
            if track.kind == kind {
                self.selected_tracks[track_index] = track_index == index;
            }
        }
        self.pending_packets.clear();
        Ok(())
    }

    pub fn set_kind_selected(&mut self, kind: TrackKind, selected: bool) {
        for (index, track) in self.tracks.iter().enumerate() {
            if track.kind == kind {
                self.selected_tracks[index] = selected;
            }
        }
        self.pending_packets.clear();
    }

    pub fn next_packet(&mut self) -> Result<Option<MediaPacket>, MediaError> {
        loop {
            if let Some(packet) = self.pending_packets.pop_front() {
                return Ok(Some(packet));
            }
            let Some(cluster) = self.clusters.get(self.cluster_index).copied() else {
                if self.streaming_index && self.discover_next_cluster()? {
                    continue;
                }
                return Ok(None);
            };
            if self.cluster_cursor < cluster.data_offset || self.cluster_cursor >= cluster.end {
                if !self.advance_cluster()? {
                    return Ok(None);
                }
                continue;
            }

            let header = read_header(self.source.as_mut(), self.cluster_cursor)?;
            let end = element_end(header, cluster.end)?;
            self.cluster_cursor = end;
            match header.id {
                ID_SIMPLE_BLOCK => {
                    let bytes = read_element_bytes(self.source.as_mut(), header, cluster.end)?;
                    let packets = packets_from_block(
                        bytes,
                        cluster.timestamp_units,
                        self.summary.timestamp_scale_ns,
                        &self.tracks,
                        &self.selected_tracks,
                        true,
                        None,
                        0,
                        true,
                    )?;
                    self.pending_packets.extend(packets);
                }
                ID_BLOCK_GROUP => {
                    let packets = parse_block_group(
                        self.source.as_mut(),
                        header.data_offset,
                        end,
                        cluster.timestamp_units,
                        self.summary.timestamp_scale_ns,
                        &self.tracks,
                        &self.selected_tracks,
                    )?;
                    self.pending_packets.extend(packets);
                }
                _ => {}
            }
        }
    }

    pub fn seek(&mut self, time_ns: u64) -> Result<(), MediaError> {
        self.prepare_seek_index()?;

        let preferred_track = self
            .tracks
            .iter()
            .enumerate()
            .find(|(index, track)| track.kind == TrackKind::Video && self.selected_tracks[*index])
            .or_else(|| {
                self.tracks.iter().enumerate().find(|(index, track)| {
                    track.kind == TrackKind::Audio && self.selected_tracks[*index]
                })
            })
            .or_else(|| {
                self.tracks
                    .iter()
                    .enumerate()
                    .find(|(index, _)| self.selected_tracks[*index])
            })
            .map(|(_, track)| (track.number, track.seek_pre_roll_ns));
        let effective_time_ns =
            preferred_track.map_or(time_ns, |(_, pre_roll)| time_ns.saturating_sub(pre_roll));

        let cue = preferred_track
            .and_then(|(track, _)| choose_cue(&self.cues, effective_time_ns, Some(track)))
            .or_else(|| choose_cue(&self.cues, effective_time_ns, None))
            .cloned();

        if let Some(cue) = cue {
            if let Some(index) = self
                .clusters
                .iter()
                .position(|cluster| cluster.offset == cue.cluster_offset)
            {
                self.select_cued_cluster(index, &cue)?;
                return Ok(());
            }
            if self.streaming_index {
                // A SeekHead commonly points to Cues stored at the end of a
                // multi-gigabyte file. Index only the referenced cluster, then
                // continue discovery from there instead of issuing one range
                // request for every earlier cluster.
                let header = read_header(self.source.as_mut(), cue.cluster_offset)?;
                if header.id != ID_CLUSTER {
                    return Err(MediaError::InvalidData("cue does not reference a cluster"));
                }
                let (cluster, next) =
                    index_cluster(self.source.as_mut(), header, self.segment_end)?;
                self.clusters.clear();
                self.clusters.push(cluster);
                self.next_segment_offset = next;
                self.summary.cluster_count = 1;
                self.select_cued_cluster(0, &cue)?;
                return Ok(());
            }
        }

        if self.streaming_index {
            self.index_clusters_through(time_ns)?;
        }
        if self.clusters.is_empty() {
            return Err(MediaError::InvalidData("media has no clusters"));
        }

        let mut selected_index = 0;
        for (index, cluster) in self.clusters.iter().enumerate() {
            let cluster_time =
                scale_timestamp(cluster.timestamp_units, self.summary.timestamp_scale_ns)?;
            if cluster_time > effective_time_ns {
                break;
            }
            selected_index = index;
        }
        self.cluster_index = selected_index;
        self.cluster_cursor = self.clusters[selected_index].data_offset;
        self.pending_packets.clear();
        Ok(())
    }

    /// Resolves SeekHead references without moving the playback cursor.
    /// Large remote files can call this during startup so the first user seek
    /// does not pay the full tail-index network cost.
    pub fn prepare_seek_index(&mut self) -> Result<(), MediaError> {
        if self.streaming_index && !self.deferred_seek_targets.is_empty() {
            self.load_deferred_cues()?;
        }
        Ok(())
    }

    fn select_cued_cluster(&mut self, index: usize, cue: &CuePoint) -> Result<(), MediaError> {
        let cluster = self.clusters[index];
        let relative_cursor = cluster
            .data_offset
            .checked_add(cue.relative_position)
            .ok_or(MediaError::ArithmeticOverflow)?;
        self.cluster_index = index;
        self.cluster_cursor = if relative_cursor < cluster.end {
            relative_cursor
        } else {
            cluster.data_offset
        };
        self.pending_packets.clear();
        Ok(())
    }

    fn load_deferred_cues(&mut self) -> Result<(), MediaError> {
        // Keep the original references until the complete index has parsed.
        // A superseding remote seek may cancel a range read; retaining these
        // targets makes the next attempt safe instead of silently losing cues.
        let mut targets = VecDeque::from(self.deferred_seek_targets.clone());
        let mut visited = HashSet::new();
        let mut processed = 0_usize;

        while let Some((target_id, relative_position)) = targets.pop_front() {
            processed = processed
                .checked_add(1)
                .ok_or(MediaError::ArithmeticOverflow)?;
            if processed > MAX_DEFERRED_SEEK_TARGETS {
                return Err(MediaError::ElementTooLarge);
            }
            let offset = self
                .summary
                .segment_data_offset
                .checked_add(relative_position)
                .ok_or(MediaError::ArithmeticOverflow)?;
            if offset >= self.segment_end || !visited.insert(offset) {
                continue;
            }
            let header = read_header(self.source.as_mut(), offset)?;
            if header.id != target_id {
                continue;
            }
            let end = element_end(header, self.segment_end)?;
            match target_id {
                ID_CUES => {
                    let mut raw_cues = Vec::new();
                    parse_cues(self.source.as_mut(), header.data_offset, end, &mut raw_cues)?;
                    self.cues
                        .extend(resolve_cues(raw_cues, &self.summary, self.segment_end)?);
                }
                ID_SEEK_HEAD => {
                    let mut nested = Vec::new();
                    parse_seek_head(self.source.as_mut(), header.data_offset, end, &mut nested)?;
                    targets.extend(nested);
                }
                _ => {}
            }
        }

        self.cues
            .sort_by_key(|cue| (cue.time_ns, cue.track_number, cue.cluster_offset));
        self.cues
            .dedup_by_key(|cue| (cue.time_ns, cue.track_number, cue.cluster_offset));
        self.summary.cue_count = saturating_u32(self.cues.len());
        self.deferred_seek_targets.clear();
        Ok(())
    }

    fn advance_cluster(&mut self) -> Result<bool, MediaError> {
        let next_index = self.cluster_index.saturating_add(1);
        if let Some(cluster) = self.clusters.get(next_index) {
            self.cluster_index = next_index;
            self.cluster_cursor = cluster.data_offset;
            return Ok(true);
        }
        if self.streaming_index && self.discover_next_cluster()? {
            self.cluster_index = next_index;
            self.cluster_cursor = self.clusters[next_index].data_offset;
            return Ok(true);
        }
        self.cluster_index = self.clusters.len();
        self.cluster_cursor = self.segment_end;
        Ok(false)
    }

    fn discover_next_cluster(&mut self) -> Result<bool, MediaError> {
        while self.next_segment_offset < self.segment_end {
            let header = read_header(self.source.as_mut(), self.next_segment_offset)?;
            match header.id {
                ID_CLUSTER => {
                    if self.clusters.len() >= MAX_CLUSTERS {
                        return Err(MediaError::ElementTooLarge);
                    }
                    let (cluster, next) =
                        index_cluster(self.source.as_mut(), header, self.segment_end)?;
                    self.clusters.push(cluster);
                    self.next_segment_offset = next;
                    self.summary.cluster_count = saturating_u32(self.clusters.len());
                    return Ok(true);
                }
                ID_CUES => {
                    let end = element_end(header, self.segment_end)?;
                    let mut raw_cues = Vec::new();
                    parse_cues(self.source.as_mut(), header.data_offset, end, &mut raw_cues)?;
                    self.cues
                        .extend(resolve_cues(raw_cues, &self.summary, self.segment_end)?);
                    self.cues
                        .sort_by_key(|cue| (cue.time_ns, cue.track_number, cue.cluster_offset));
                    self.cues
                        .dedup_by_key(|cue| (cue.time_ns, cue.track_number, cue.cluster_offset));
                    self.summary.cue_count = saturating_u32(self.cues.len());
                    self.next_segment_offset = end;
                }
                _ => {
                    self.next_segment_offset = element_end(header, self.segment_end)?;
                }
            }
        }
        Ok(false)
    }

    fn index_clusters_through(&mut self, time_ns: u64) -> Result<(), MediaError> {
        loop {
            let covered = self
                .clusters
                .last()
                .map(|cluster| {
                    scale_timestamp(cluster.timestamp_units, self.summary.timestamp_scale_ns)
                })
                .transpose()?
                .is_some_and(|timestamp| timestamp > time_ns);
            if covered || !self.discover_next_cluster()? {
                return Ok(());
            }
        }
    }
}

fn parse_ebml_header(source: &mut dyn ReadAt) -> Result<(ContainerSummary, u64), MediaError> {
    let header = read_header(source, 0)?;
    if header.id != ID_EBML {
        return Err(MediaError::InvalidData("EBML header is missing"));
    }
    let end = element_end(header, source.len())?;
    let mut summary = ContainerSummary {
        document_type_version: 1,
        document_type_read_version: 1,
        ..ContainerSummary::default()
    };
    let mut cursor = header.data_offset;
    while cursor < end {
        let child = read_header(source, cursor)?;
        let child_end = element_end(child, end)?;
        match child.id {
            ID_DOC_TYPE => summary.document_type = read_string(source, child)?.to_ascii_lowercase(),
            ID_DOC_TYPE_VERSION => summary.document_type_version = read_uint(source, child)?,
            ID_DOC_TYPE_READ_VERSION => {
                summary.document_type_read_version = read_uint(source, child)?;
            }
            _ => {}
        }
        cursor = child_end;
    }
    if summary.document_type.is_empty() {
        return Err(MediaError::InvalidData("EBML document type is missing"));
    }
    Ok((summary, end))
}

fn parse_info(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
    summary: &mut ContainerSummary,
    duration_units: &mut Option<f64>,
) -> Result<(), MediaError> {
    let mut cursor = start;
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        match header.id {
            ID_TIMESTAMP_SCALE => summary.timestamp_scale_ns = read_uint(source, header)?,
            ID_DURATION => *duration_units = Some(read_float(source, header)?),
            ID_TITLE => summary.title = read_string(source, header)?,
            ID_MUXING_APP => summary.muxing_app = read_string(source, header)?,
            ID_WRITING_APP => summary.writing_app = read_string(source, header)?,
            _ => {}
        }
        cursor = child_end;
    }
    Ok(())
}

fn parse_seek_head(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
    targets: &mut Vec<(u64, u64)>,
) -> Result<(), MediaError> {
    let mut cursor = start;
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        if header.id == ID_SEEK {
            if let Some((target_id, position)) =
                parse_seek_entry(source, header.data_offset, child_end)?
            {
                if matches!(target_id, ID_CUES | ID_SEEK_HEAD) {
                    if targets.len() >= MAX_DEFERRED_SEEK_TARGETS {
                        return Err(MediaError::ElementTooLarge);
                    }
                    targets.push((target_id, position));
                }
            }
        }
        cursor = child_end;
    }
    Ok(())
}

fn parse_seek_entry(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
) -> Result<Option<(u64, u64)>, MediaError> {
    let mut cursor = start;
    let mut target_id = None;
    let mut position = None;
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        match header.id {
            ID_SEEK_ID => {
                let size = header
                    .size
                    .ok_or(MediaError::InvalidData("unknown seek ID size"))?;
                if !(1..=4).contains(&size) {
                    return Err(MediaError::InvalidData("invalid seek ID size"));
                }
                let bytes = read_bytes(source, header.data_offset, size, 4)?;
                let (parsed, consumed) = parse_id(&bytes)?;
                if consumed != bytes.len() {
                    return Err(MediaError::InvalidData("invalid seek ID payload"));
                }
                target_id = Some(parsed);
            }
            ID_SEEK_POSITION => position = Some(read_uint(source, header)?),
            _ => {}
        }
        cursor = child_end;
    }
    Ok(target_id.zip(position))
}

fn parse_tracks(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
    tracks: &mut Vec<MediaTrack>,
) -> Result<(), MediaError> {
    let mut cursor = start;
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        if header.id == ID_TRACK_ENTRY {
            if tracks.len() >= MAX_TRACKS {
                return Err(MediaError::ElementTooLarge);
            }
            let builder = parse_track_entry(source, header.data_offset, child_end)?;
            tracks.push(builder.finish(tracks.len())?);
        }
        cursor = child_end;
    }
    Ok(())
}

fn parse_track_entry(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
) -> Result<TrackBuilder, MediaError> {
    let mut track = TrackBuilder::default();
    let mut language_ietf = None;
    let mut cursor = start;
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        match header.id {
            ID_TRACK_NUMBER => track.number = read_uint(source, header)?,
            ID_TRACK_UID => track.uid = read_uint(source, header)?,
            ID_TRACK_TYPE => {
                track.kind = match read_uint(source, header)? {
                    1 => TrackKind::Video,
                    2 => TrackKind::Audio,
                    17 => TrackKind::Subtitle,
                    _ => TrackKind::Other,
                };
            }
            ID_FLAG_ENABLED => track.enabled = read_uint(source, header)? != 0,
            ID_FLAG_DEFAULT => track.default = read_uint(source, header)? != 0,
            ID_FLAG_FORCED => track.forced = read_uint(source, header)? != 0,
            ID_FLAG_LACING => track.lacing = read_uint(source, header)? != 0,
            ID_DEFAULT_DURATION => track.default_duration_ns = read_uint(source, header)?,
            ID_TRACK_TIMESTAMP_SCALE => track.timestamp_scale = read_float(source, header)?,
            ID_NAME => track.name = read_string(source, header)?,
            ID_LANGUAGE => track.language = read_string(source, header)?,
            ID_LANGUAGE_IETF => language_ietf = Some(read_string(source, header)?),
            ID_CODEC_ID => track.codec_id = read_string(source, header)?,
            ID_CODEC_PRIVATE => {
                let size = header
                    .size
                    .ok_or(MediaError::InvalidData("unknown codec private size"))?;
                track.codec_private = read_bytes(
                    source,
                    header.data_offset,
                    size,
                    MAX_METADATA_ELEMENT_LENGTH,
                )?;
            }
            ID_CODEC_NAME => track.codec_name = read_string(source, header)?,
            ID_CODEC_DELAY => track.codec_delay_ns = read_uint(source, header)?,
            ID_SEEK_PRE_ROLL => track.seek_pre_roll_ns = read_uint(source, header)?,
            ID_VIDEO => parse_video(source, header.data_offset, child_end, &mut track)?,
            ID_AUDIO => parse_audio(source, header.data_offset, child_end, &mut track)?,
            _ => {}
        }
        cursor = child_end;
    }
    if let Some(language) = language_ietf {
        track.language = language;
    }
    Ok(track)
}

fn parse_video(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
    track: &mut TrackBuilder,
) -> Result<(), MediaError> {
    let mut cursor = start;
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        match header.id {
            ID_PIXEL_WIDTH => track.pixel_width = read_uint(source, header)?,
            ID_PIXEL_HEIGHT => track.pixel_height = read_uint(source, header)?,
            ID_DISPLAY_WIDTH => track.display_width = read_uint(source, header)?,
            ID_DISPLAY_HEIGHT => track.display_height = read_uint(source, header)?,
            ID_FRAME_RATE => track.frame_rate = read_float(source, header)?,
            _ => {}
        }
        cursor = child_end;
    }
    Ok(())
}

fn parse_audio(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
    track: &mut TrackBuilder,
) -> Result<(), MediaError> {
    let mut cursor = start;
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        match header.id {
            ID_SAMPLING_FREQUENCY => track.sampling_frequency = read_float(source, header)?,
            ID_OUTPUT_SAMPLING_FREQUENCY => {
                track.output_sampling_frequency = read_float(source, header)?;
            }
            ID_CHANNELS => track.channels = read_uint(source, header)?,
            ID_BIT_DEPTH => track.bit_depth = read_uint(source, header)?,
            _ => {}
        }
        cursor = child_end;
    }
    Ok(())
}

fn parse_cues(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
    cues: &mut Vec<RawCuePoint>,
) -> Result<(), MediaError> {
    let mut cursor = start;
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        if header.id == ID_CUE_POINT {
            parse_cue_point(source, header.data_offset, child_end, cues)?;
        }
        cursor = child_end;
    }
    Ok(())
}

fn parse_cue_point(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
    cues: &mut Vec<RawCuePoint>,
) -> Result<(), MediaError> {
    let mut cursor = start;
    let mut time_units = None;
    let mut positions = Vec::new();
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        match header.id {
            ID_CUE_TIME => time_units = Some(read_uint(source, header)?),
            ID_CUE_TRACK_POSITIONS => {
                if positions.len() >= MAX_CUE_TRACK_POSITIONS {
                    return Err(MediaError::ElementTooLarge);
                }
                positions.push(parse_cue_track_position(
                    source,
                    header.data_offset,
                    child_end,
                )?);
            }
            _ => {}
        }
        cursor = child_end;
    }
    let time_units = time_units.ok_or(MediaError::InvalidData("cue time is missing"))?;
    for mut position in positions {
        if cues.len() >= MAX_CUES {
            return Err(MediaError::ElementTooLarge);
        }
        position.time_units = time_units;
        cues.push(position);
    }
    Ok(())
}

fn parse_cue_track_position(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
) -> Result<RawCuePoint, MediaError> {
    let mut cue = RawCuePoint {
        time_units: 0,
        track_number: 0,
        cluster_position: u64::MAX,
        relative_position: 0,
        duration_units: 0,
        block_number: 1,
    };
    let mut cursor = start;
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        match header.id {
            ID_CUE_TRACK => cue.track_number = read_uint(source, header)?,
            ID_CUE_CLUSTER_POSITION => cue.cluster_position = read_uint(source, header)?,
            ID_CUE_RELATIVE_POSITION => cue.relative_position = read_uint(source, header)?,
            ID_CUE_DURATION => cue.duration_units = read_uint(source, header)?,
            ID_CUE_BLOCK_NUMBER => cue.block_number = read_uint(source, header)?,
            _ => {}
        }
        cursor = child_end;
    }
    if cue.track_number == 0 || cue.cluster_position == u64::MAX {
        return Err(MediaError::InvalidData("cue track position is incomplete"));
    }
    Ok(cue)
}

fn index_cluster(
    source: &mut dyn ReadAt,
    header: ElementHeader,
    segment_end: u64,
) -> Result<(ClusterIndex, u64), MediaError> {
    let declared_end = match header.size {
        Some(_) => Some(element_end(header, segment_end)?),
        None => None,
    };
    let scan_end = declared_end.unwrap_or(segment_end);
    let mut cursor = header.data_offset;
    let mut timestamp_units = 0;
    let mut resolved_end = scan_end;
    while cursor < scan_end {
        if declared_end.is_none()
            && cursor.saturating_sub(header.data_offset) > MAX_UNKNOWN_CLUSTER_SCAN_BYTES
        {
            return Err(MediaError::ElementTooLarge);
        }
        let child = read_header(source, cursor)?;
        if declared_end.is_none() && cursor > header.data_offset && is_segment_level(child.id) {
            resolved_end = cursor;
            break;
        }
        let child_end = match child.size {
            Some(_) => element_end(child, scan_end)?,
            None => {
                return Err(MediaError::Unsupported(
                    "unknown-sized cluster child element",
                ));
            }
        };
        if child.id == ID_CLUSTER_TIMESTAMP {
            timestamp_units = read_uint(source, child)?;
            if declared_end.is_some() {
                break;
            }
        }
        cursor = child_end;
    }
    Ok((
        ClusterIndex {
            offset: header.offset,
            data_offset: header.data_offset,
            end: resolved_end,
            timestamp_units,
        },
        resolved_end,
    ))
}

fn is_segment_level(id: u64) -> bool {
    matches!(
        id,
        ID_SEEK_HEAD
            | ID_INFO
            | ID_TRACKS
            | ID_CUES
            | ID_CLUSTER
            | ID_ATTACHMENTS
            | ID_CHAPTERS
            | ID_TAGS
    )
}

#[allow(clippy::too_many_arguments)]
fn parse_block_group(
    source: &mut dyn ReadAt,
    start: u64,
    end: u64,
    cluster_timestamp_units: u64,
    timestamp_scale_ns: u64,
    tracks: &[MediaTrack],
    selected_tracks: &[bool],
) -> Result<Vec<MediaPacket>, MediaError> {
    let mut cursor = start;
    let mut block_header = None;
    let mut duration_units = None;
    let mut discard_padding_ns = 0;
    let mut has_reference = false;
    while cursor < end {
        let header = read_header(source, cursor)?;
        let child_end = element_end(header, end)?;
        match header.id {
            ID_BLOCK => match block_header {
                Some(_) => {
                    return Err(MediaError::InvalidData(
                        "block group has multiple block elements",
                    ));
                }
                None => block_header = Some(header),
            },
            ID_BLOCK_DURATION => duration_units = Some(read_uint(source, header)?),
            ID_REFERENCE_BLOCK => {
                let _ = read_signed_integer(source, header)?;
                has_reference = true;
            }
            ID_DISCARD_PADDING => discard_padding_ns = read_signed_integer(source, header)?,
            _ => {}
        }
        cursor = child_end;
    }
    let block_header = block_header.ok_or(MediaError::InvalidData("block group has no block"))?;
    let bytes = read_element_bytes(source, block_header, end)?;
    packets_from_block(
        bytes,
        cluster_timestamp_units,
        timestamp_scale_ns,
        tracks,
        selected_tracks,
        false,
        duration_units,
        discard_padding_ns,
        !has_reference,
    )
}

#[allow(clippy::too_many_arguments)]
fn packets_from_block(
    mut bytes: Vec<u8>,
    cluster_timestamp_units: u64,
    timestamp_scale_ns: u64,
    tracks: &[MediaTrack],
    selected_tracks: &[bool],
    simple_block: bool,
    block_duration_units: Option<u64>,
    discard_padding_ns: i64,
    group_keyframe: bool,
) -> Result<Vec<MediaPacket>, MediaError> {
    let parsed = parse_block_layout(&bytes)?;
    let track_index = tracks
        .iter()
        .position(|track| track.number == parsed.track_number)
        .ok_or(MediaError::InvalidData("block references an unknown track"))?;
    if !selected_tracks.get(track_index).copied().unwrap_or(false) {
        return Ok(Vec::new());
    }
    let track = &tracks[track_index];
    if parsed.frames.len() > 1 && !track.lacing {
        return Err(MediaError::InvalidData("track forbids block lacing"));
    }

    let base_timestamp_ns = block_timestamp_ns(
        cluster_timestamp_units,
        parsed.relative_timestamp,
        track.timestamp_scale,
        timestamp_scale_ns,
        track.codec_delay_ns,
    )?;
    let frame_count = parsed.frames.len() as u64;
    let total_block_duration_ns = block_duration_units
        .map(|units| scale_track_ticks(units, track.timestamp_scale, timestamp_scale_ns))
        .transpose()?;
    let payloads = if parsed.frames.len() == 1 {
        let (start, end) = parsed.frames[0];
        let length = end - start;
        bytes.copy_within(start..end, 0);
        bytes.truncate(length);
        vec![bytes]
    } else {
        parsed
            .frames
            .iter()
            .map(|(start, end)| bytes[*start..*end].to_vec())
            .collect()
    };
    let payload_count = payloads.len();
    let mut packets = Vec::with_capacity(payload_count);
    let mut elapsed_ns = 0_u64;
    for (frame_index, payload) in payloads.into_iter().enumerate() {
        let mut flags = PacketFlags::empty();
        if (simple_block && parsed.flags & 0x80 != 0) || (!simple_block && group_keyframe) {
            flags.insert(PacketFlags::KEYFRAME);
        }
        if parsed.flags & 0x08 != 0 {
            flags.insert(PacketFlags::INVISIBLE);
        }
        if simple_block && parsed.flags & 0x01 != 0 {
            flags.insert(PacketFlags::DISCARDABLE);
        }
        if payload_count > 1 {
            flags.insert(PacketFlags::LACED);
        }

        let is_last = frame_index + 1 == payload_count;
        let duration_ns = total_block_duration_ns.map_or_else(
            || {
                if track.default_duration_ns > 0 {
                    track.default_duration_ns
                } else {
                    inferred_audio_packet_duration_ns(track, &payload).unwrap_or(0)
                }
            },
            |total| {
                let base = total / frame_count;
                let remainder = total % frame_count;
                base + u64::from((frame_index as u64) < remainder)
            },
        );
        let elapsed_ns_i64 =
            i64::try_from(elapsed_ns).map_err(|_| MediaError::ArithmeticOverflow)?;
        let timestamp_ns = base_timestamp_ns
            .checked_add(elapsed_ns_i64)
            .ok_or(MediaError::ArithmeticOverflow)?;
        packets.push(MediaPacket {
            track_index: u32::try_from(track_index).map_err(|_| MediaError::ArithmeticOverflow)?,
            track_number: parsed.track_number,
            timestamp_ns,
            duration_ns,
            discard_padding_ns: if is_last { discard_padding_ns } else { 0 },
            flags,
            payload,
        });
        elapsed_ns = elapsed_ns
            .checked_add(duration_ns)
            .ok_or(MediaError::ArithmeticOverflow)?;
    }
    Ok(packets)
}

fn inferred_audio_packet_duration_ns(track: &MediaTrack, payload: &[u8]) -> Option<u64> {
    if track.kind != TrackKind::Audio
        || !track.output_sampling_frequency.is_finite()
        || track.output_sampling_frequency <= 0.0
    {
        return None;
    }
    let sample_frames = super::audio::compressed_audio_sample_frames(track.codec, payload)?;
    let duration = f64::from(sample_frames) * 1_000_000_000.0
        / track.output_sampling_frequency;
    if !duration.is_finite() || duration <= 0.0 || duration > u64::MAX as f64 {
        return None;
    }
    Some(duration.round() as u64)
}

fn parse_block_layout(bytes: &[u8]) -> Result<ParsedBlock, MediaError> {
    let (track_number, track_length) = parse_vint_value(bytes)?;
    if track_number == 0 {
        return Err(MediaError::InvalidData("block track number is zero"));
    }
    let header_end = track_length
        .checked_add(3)
        .ok_or(MediaError::ArithmeticOverflow)?;
    if bytes.len() < header_end {
        return Err(MediaError::UnexpectedEnd);
    }
    let relative_timestamp = i16::from_be_bytes([bytes[track_length], bytes[track_length + 1]]);
    let flags = bytes[track_length + 2];
    let lacing = (flags >> 1) & 0x03;
    let mut payload_start = header_end;
    let mut sizes = Vec::new();

    if lacing == 0 {
        sizes.push(bytes.len() - payload_start);
    } else {
        let lace_count = *bytes.get(payload_start).ok_or(MediaError::UnexpectedEnd)?;
        payload_start += 1;
        let frame_count = usize::from(lace_count) + 1;
        if frame_count == 1 {
            return Err(MediaError::InvalidData(
                "lacing cannot contain a single frame",
            ));
        }
        match lacing {
            1 => {
                let mut declared = 0_usize;
                for _ in 0..frame_count - 1 {
                    let mut size = 0_usize;
                    loop {
                        let value = *bytes.get(payload_start).ok_or(MediaError::UnexpectedEnd)?;
                        payload_start += 1;
                        size = size
                            .checked_add(usize::from(value))
                            .ok_or(MediaError::ArithmeticOverflow)?;
                        if value != 0xff {
                            break;
                        }
                    }
                    declared = declared
                        .checked_add(size)
                        .ok_or(MediaError::ArithmeticOverflow)?;
                    sizes.push(size);
                }
                let available = bytes.len().saturating_sub(payload_start);
                if declared > available {
                    return Err(MediaError::InvalidData("Xiph lace sizes exceed block"));
                }
                sizes.push(available - declared);
            }
            2 => {
                let available = bytes.len().saturating_sub(payload_start);
                if available % frame_count != 0 {
                    return Err(MediaError::InvalidData("fixed lace has uneven frame sizes"));
                }
                sizes.resize(frame_count, available / frame_count);
            }
            3 => {
                if frame_count == 1 {
                    sizes.push(bytes.len().saturating_sub(payload_start));
                } else {
                    let (first_size, length) = parse_vint_value(&bytes[payload_start..])?;
                    payload_start = payload_start
                        .checked_add(length)
                        .ok_or(MediaError::ArithmeticOverflow)?;
                    let first_size =
                        usize::try_from(first_size).map_err(|_| MediaError::ArithmeticOverflow)?;
                    sizes.push(first_size);
                    let mut previous =
                        i128::try_from(first_size).map_err(|_| MediaError::ArithmeticOverflow)?;
                    for _ in 1..frame_count - 1 {
                        let (difference, length) = parse_signed_vint(&bytes[payload_start..])?;
                        payload_start = payload_start
                            .checked_add(length)
                            .ok_or(MediaError::ArithmeticOverflow)?;
                        let size = previous + i128::from(difference);
                        if size < 0 {
                            return Err(MediaError::InvalidData("negative EBML lace size"));
                        }
                        let size =
                            usize::try_from(size).map_err(|_| MediaError::ArithmeticOverflow)?;
                        sizes.push(size);
                        previous =
                            i128::try_from(size).map_err(|_| MediaError::ArithmeticOverflow)?;
                    }
                    let declared = sizes.iter().try_fold(0_usize, |total, size| {
                        total
                            .checked_add(*size)
                            .ok_or(MediaError::ArithmeticOverflow)
                    })?;
                    let available = bytes.len().saturating_sub(payload_start);
                    if declared > available {
                        return Err(MediaError::InvalidData("EBML lace sizes exceed block"));
                    }
                    sizes.push(available - declared);
                }
            }
            _ => unreachable!(),
        }
    }

    let mut frames = Vec::with_capacity(sizes.len());
    let mut cursor = payload_start;
    for size in sizes {
        let end = cursor
            .checked_add(size)
            .ok_or(MediaError::ArithmeticOverflow)?;
        if end > bytes.len() {
            return Err(MediaError::InvalidData("lace frame exceeds block"));
        }
        frames.push((cursor, end));
        cursor = end;
    }
    if cursor != bytes.len() {
        return Err(MediaError::InvalidData("unconsumed block payload"));
    }

    Ok(ParsedBlock {
        track_number,
        relative_timestamp,
        flags,
        frames,
    })
}

fn resolve_cues(
    raw_cues: Vec<RawCuePoint>,
    summary: &ContainerSummary,
    segment_end: u64,
) -> Result<Vec<CuePoint>, MediaError> {
    let mut cues = Vec::with_capacity(raw_cues.len());
    for raw in raw_cues {
        let cluster_offset = summary
            .segment_data_offset
            .checked_add(raw.cluster_position)
            .ok_or(MediaError::ArithmeticOverflow)?;
        if cluster_offset >= segment_end {
            return Err(MediaError::InvalidData(
                "cue cluster offset is out of range",
            ));
        }
        cues.push(CuePoint {
            time_ns: scale_timestamp(raw.time_units, summary.timestamp_scale_ns)?,
            track_number: raw.track_number,
            cluster_offset,
            relative_position: raw.relative_position,
            duration_ns: scale_timestamp(raw.duration_units, summary.timestamp_scale_ns)?,
            block_number: raw.block_number,
        });
    }
    cues.sort_by_key(|cue| (cue.time_ns, cue.track_number, cue.cluster_offset));
    Ok(cues)
}

fn choose_cue(cues: &[CuePoint], time_ns: u64, track: Option<u64>) -> Option<&CuePoint> {
    let matching = |cue: &&CuePoint| track.is_none_or(|number| cue.track_number == number);
    cues.iter()
        .filter(matching)
        .take_while(|cue| cue.time_ns <= time_ns)
        .last()
        .or_else(|| cues.iter().find(matching))
}

fn element_end(header: ElementHeader, parent_end: u64) -> Result<u64, MediaError> {
    let size = header
        .size
        .ok_or(MediaError::Unsupported("unknown-sized non-segment element"))?;
    let end = header
        .data_offset
        .checked_add(size)
        .ok_or(MediaError::ArithmeticOverflow)?;
    if end > parent_end {
        return Err(MediaError::UnexpectedEnd);
    }
    Ok(end)
}

fn read_element_bytes(
    source: &mut dyn ReadAt,
    header: ElementHeader,
    parent_end: u64,
) -> Result<Vec<u8>, MediaError> {
    let end = element_end(header, parent_end)?;
    let size = end
        .checked_sub(header.data_offset)
        .ok_or(MediaError::ArithmeticOverflow)?;
    read_bytes(
        source,
        header.data_offset,
        size,
        MAX_BLOCK_ELEMENT_LENGTH.max(MAX_METADATA_ELEMENT_LENGTH),
    )
}

fn read_signed_integer(source: &mut dyn ReadAt, header: ElementHeader) -> Result<i64, MediaError> {
    let size = header
        .size
        .ok_or(MediaError::InvalidData("unknown signed integer size"))?;
    if !(1..=8).contains(&size) {
        return Err(MediaError::InvalidData("invalid signed integer size"));
    }
    let mut bytes = if size > 0 {
        let mut first = [0_u8; 1];
        source.read_exact_at(header.data_offset, &mut first)?;
        if first[0] & 0x80 != 0 {
            [0xff_u8; 8]
        } else {
            [0_u8; 8]
        }
    } else {
        [0_u8; 8]
    };
    let start = 8 - size as usize;
    source.read_exact_at(header.data_offset, &mut bytes[start..])?;
    Ok(i64::from_be_bytes(bytes))
}

fn scale_timestamp(units: u64, scale_ns: u64) -> Result<u64, MediaError> {
    units
        .checked_mul(scale_ns)
        .ok_or(MediaError::ArithmeticOverflow)
}

fn scale_track_ticks(
    units: u64,
    track_scale: f64,
    timestamp_scale_ns: u64,
) -> Result<u64, MediaError> {
    if !track_scale.is_finite() || track_scale <= 0.0 {
        return Err(MediaError::InvalidData("invalid track timestamp scale"));
    }
    if track_scale == 1.0 {
        return scale_timestamp(units, timestamp_scale_ns);
    }
    scaled_float_to_u64(units as f64 * track_scale, timestamp_scale_ns)
}

fn block_timestamp_ns(
    cluster_timestamp_units: u64,
    relative_timestamp: i16,
    track_scale: f64,
    timestamp_scale_ns: u64,
    codec_delay_ns: u64,
) -> Result<i64, MediaError> {
    if !track_scale.is_finite() || track_scale <= 0.0 {
        return Err(MediaError::InvalidData("invalid track timestamp scale"));
    }
    let cluster_ns = i128::from(cluster_timestamp_units)
        .checked_mul(i128::from(timestamp_scale_ns))
        .ok_or(MediaError::ArithmeticOverflow)?;
    let relative_ns = f64::from(relative_timestamp) * track_scale * timestamp_scale_ns as f64;
    if !relative_ns.is_finite() || relative_ns < i128::MIN as f64 || relative_ns > i128::MAX as f64
    {
        return Err(MediaError::ArithmeticOverflow);
    }
    let timestamp_ns = cluster_ns
        .checked_add(relative_ns.round() as i128)
        .and_then(|value| value.checked_sub(i128::from(codec_delay_ns)))
        .ok_or(MediaError::ArithmeticOverflow)?;
    i64::try_from(timestamp_ns).map_err(|_| MediaError::ArithmeticOverflow)
}

fn scaled_float_to_u64(units: f64, scale_ns: u64) -> Result<u64, MediaError> {
    let scaled = units * scale_ns as f64;
    if !scaled.is_finite() || scaled < 0.0 || scaled > u64::MAX as f64 {
        return Err(MediaError::InvalidData("invalid duration"));
    }
    Ok(scaled.round() as u64)
}

fn saturating_u32(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct OwnedSource {
        bytes: Vec<u8>,
    }

    impl ReadAt for OwnedSource {
        fn len(&self) -> u64 {
            self.bytes.len() as u64
        }

        fn read_at(&mut self, offset: u64, output: &mut [u8]) -> Result<usize, MediaError> {
            let offset = usize::try_from(offset).map_err(|_| MediaError::ArithmeticOverflow)?;
            if offset >= self.bytes.len() {
                return Ok(0);
            }
            let count = output.len().min(self.bytes.len() - offset);
            output[..count].copy_from_slice(&self.bytes[offset..offset + count]);
            Ok(count)
        }
    }

    struct SparseTailSource {
        bytes: Vec<u8>,
        logical_len: u64,
    }

    impl ReadAt for SparseTailSource {
        fn len(&self) -> u64 {
            self.logical_len
        }

        fn read_at(&mut self, offset: u64, output: &mut [u8]) -> Result<usize, MediaError> {
            let offset = usize::try_from(offset).map_err(|_| MediaError::ArithmeticOverflow)?;
            if offset >= self.bytes.len() {
                return Ok(0);
            }
            let count = output.len().min(self.bytes.len() - offset);
            output[..count].copy_from_slice(&self.bytes[offset..offset + count]);
            Ok(count)
        }
    }

    fn size_vint(value: usize) -> Vec<u8> {
        for length in 1..=8 {
            let maximum = (1_u128 << (7 * length)) - 1;
            if (value as u128) < maximum {
                let encoded = (1_u128 << (7 * length)) | value as u128;
                let bytes = encoded.to_be_bytes();
                return bytes[16 - length..].to_vec();
            }
        }
        panic!("test element is too large");
    }

    fn element(id: &[u8], payload: Vec<u8>) -> Vec<u8> {
        let mut result = Vec::with_capacity(id.len() + 8 + payload.len());
        result.extend_from_slice(id);
        result.extend_from_slice(&size_vint(payload.len()));
        result.extend(payload);
        result
    }

    fn unknown_sized_element(id: &[u8], payload: Vec<u8>) -> Vec<u8> {
        let mut result = Vec::with_capacity(id.len() + 1 + payload.len());
        result.extend_from_slice(id);
        result.push(0xff);
        result.extend(payload);
        result
    }

    fn uint_element(id: &[u8], value: u64) -> Vec<u8> {
        let bytes = value.to_be_bytes();
        let first = bytes
            .iter()
            .position(|byte| *byte != 0)
            .unwrap_or(bytes.len() - 1);
        element(id, bytes[first..].to_vec())
    }

    fn signed_element(id: &[u8], value: i8) -> Vec<u8> {
        element(id, vec![value as u8])
    }

    fn string_element(id: &[u8], value: &str) -> Vec<u8> {
        element(id, value.as_bytes().to_vec())
    }

    fn float_element(id: &[u8], value: f64) -> Vec<u8> {
        element(id, value.to_be_bytes().to_vec())
    }

    fn append(target: &mut Vec<u8>, value: Vec<u8>) {
        target.extend(value);
    }

    fn ebml_header() -> Vec<u8> {
        let mut payload = Vec::new();
        append(&mut payload, string_element(&[0x42, 0x82], "matroska"));
        append(&mut payload, uint_element(&[0x42, 0x87], 4));
        append(&mut payload, uint_element(&[0x42, 0x85], 2));
        element(&[0x1a, 0x45, 0xdf, 0xa3], payload)
    }

    fn info() -> Vec<u8> {
        let mut payload = Vec::new();
        append(
            &mut payload,
            uint_element(&[0x2a, 0xd7, 0xb1], DEFAULT_TIMESTAMP_SCALE_NS),
        );
        append(&mut payload, float_element(&[0x44, 0x89], 2_000.0));
        append(&mut payload, string_element(&[0x7b, 0xa9], "Bunny fixture"));
        append(&mut payload, string_element(&[0x4d, 0x80], "Bunny mux"));
        append(&mut payload, string_element(&[0x57, 0x41], "Bunny writer"));
        element(&[0x15, 0x49, 0xa9, 0x66], payload)
    }

    fn video_track(number: u64) -> Vec<u8> {
        let mut video = Vec::new();
        append(&mut video, uint_element(&[0xb0], 1920));
        append(&mut video, uint_element(&[0xba], 1080));
        append(&mut video, uint_element(&[0x54, 0xb0], 1920));
        append(&mut video, uint_element(&[0x54, 0xba], 1080));

        let mut entry = Vec::new();
        append(&mut entry, uint_element(&[0xd7], number));
        append(&mut entry, uint_element(&[0x73, 0xc5], number + 100));
        append(&mut entry, uint_element(&[0x83], 1));
        append(&mut entry, uint_element(&[0x23, 0xe3, 0x83], 40_000_000));
        append(&mut entry, string_element(&[0x86], "V_MPEG4/ISO/AVC"));
        append(&mut entry, string_element(&[0x53, 0x6e], "Main video"));
        append(&mut entry, element(&[0xe0], video));
        element(&[0xae], entry)
    }

    fn audio_track(number: u64, name: &str) -> Vec<u8> {
        let mut audio = Vec::new();
        append(&mut audio, float_element(&[0xb5], 48_000.0));
        append(&mut audio, uint_element(&[0x9f], 2));

        let mut entry = Vec::new();
        append(&mut entry, uint_element(&[0xd7], number));
        append(&mut entry, uint_element(&[0x73, 0xc5], number + 100));
        append(&mut entry, uint_element(&[0x83], 2));
        append(&mut entry, uint_element(&[0x23, 0xe3, 0x83], 20_000_000));
        append(&mut entry, string_element(&[0x86], "A_OPUS"));
        append(&mut entry, string_element(&[0x53, 0x6e], name));
        append(&mut entry, element(&[0xe1], audio));
        element(&[0xae], entry)
    }

    fn scaled_video_track(number: u64, timestamp_scale: f64, codec_delay_ns: u64) -> Vec<u8> {
        let mut video = Vec::new();
        append(&mut video, uint_element(&[0xb0], 1920));
        append(&mut video, uint_element(&[0xba], 1080));
        let mut entry = Vec::new();
        append(&mut entry, uint_element(&[0xd7], number));
        append(&mut entry, uint_element(&[0x73, 0xc5], number + 100));
        append(&mut entry, uint_element(&[0x83], 1));
        append(&mut entry, string_element(&[0x86], "V_MPEG4/ISO/AVC"));
        append(
            &mut entry,
            float_element(&[0x23, 0x31, 0x4f], timestamp_scale),
        );
        append(&mut entry, uint_element(&[0x56, 0xaa], codec_delay_ns));
        append(&mut entry, element(&[0xe0], video));
        element(&[0xae], entry)
    }

    fn tracks(entries: Vec<Vec<u8>>) -> Vec<u8> {
        let mut payload = Vec::new();
        for entry in entries {
            append(&mut payload, entry);
        }
        element(&[0x16, 0x54, 0xae, 0x6b], payload)
    }

    fn track_vint(number: u64) -> Vec<u8> {
        assert!((1..=126).contains(&number));
        vec![0x80 | number as u8]
    }

    fn raw_block(track: u64, relative_time: i16, flags: u8, payload: &[u8]) -> Vec<u8> {
        let mut result = track_vint(track);
        result.extend_from_slice(&relative_time.to_be_bytes());
        result.push(flags);
        result.extend_from_slice(payload);
        result
    }

    fn simple_block(track: u64, relative_time: i16, flags: u8, payload: &[u8]) -> Vec<u8> {
        element(&[0xa3], raw_block(track, relative_time, flags, payload))
    }

    fn cluster(timestamp: u64, children: Vec<Vec<u8>>) -> Vec<u8> {
        let mut payload = Vec::new();
        append(&mut payload, uint_element(&[0xe7], timestamp));
        for child in children {
            append(&mut payload, child);
        }
        element(&[0x1f, 0x43, 0xb6, 0x75], payload)
    }

    fn cue_point(time: u64, track: u64, cluster_position: u64) -> Vec<u8> {
        let mut position = Vec::new();
        append(&mut position, uint_element(&[0xf7], track));
        append(&mut position, uint_element(&[0xf1], cluster_position));
        let mut cue = Vec::new();
        append(&mut cue, uint_element(&[0xb3], time));
        append(&mut cue, element(&[0xb7], position));
        element(&[0xbb], cue)
    }

    fn cue_point_relative(
        time: u64,
        track: u64,
        cluster_position: u64,
        relative_position: u64,
    ) -> Vec<u8> {
        let mut position = Vec::new();
        append(&mut position, uint_element(&[0xf7], track));
        append(&mut position, uint_element(&[0xf1], cluster_position));
        append(&mut position, uint_element(&[0xf0], relative_position));
        let mut cue = Vec::new();
        append(&mut cue, uint_element(&[0xb3], time));
        append(&mut cue, element(&[0xb7], position));
        element(&[0xbb], cue)
    }

    fn seek_head_entry(target_id: &[u8], relative_position: u64) -> Vec<u8> {
        let mut entry = Vec::new();
        append(&mut entry, element(&[0x53, 0xab], target_id.to_vec()));
        append(&mut entry, uint_element(&[0x53, 0xac], relative_position));
        element(&[0x4d, 0xbb], entry)
    }

    fn seek_head_for_cues(relative_position: u64) -> Vec<u8> {
        element(
            &[0x11, 0x4d, 0x9b, 0x74],
            seek_head_entry(&[0x1c, 0x53, 0xbb, 0x6b], relative_position),
        )
    }

    fn make_seek_head_streaming_file(cluster_count: usize) -> Vec<u8> {
        let info = info();
        let tracks = tracks(vec![video_track(1)]);
        let clusters = (0..cluster_count)
            .map(|index| {
                let payload = format!("video-{index}");
                cluster(
                    u64::try_from(index).unwrap() * 1_000,
                    vec![simple_block(1, 0, 0x80, payload.as_bytes())],
                )
            })
            .collect::<Vec<_>>();

        let mut seek_head = seek_head_for_cues(0);
        for _ in 0..16 {
            let cues_position = seek_head.len()
                + info.len()
                + tracks.len()
                + clusters.iter().map(Vec::len).sum::<usize>();
            let next = seek_head_for_cues(u64::try_from(cues_position).unwrap());
            if next == seek_head {
                break;
            }
            seek_head = next;
        }

        let mut cluster_position = seek_head.len() + info.len() + tracks.len();
        let mut cue_payload = Vec::new();
        for (index, media_cluster) in clusters.iter().enumerate() {
            append(
                &mut cue_payload,
                cue_point(
                    u64::try_from(index).unwrap() * 1_000,
                    1,
                    u64::try_from(cluster_position).unwrap(),
                ),
            );
            cluster_position += media_cluster.len();
        }
        let cues = element(&[0x1c, 0x53, 0xbb, 0x6b], cue_payload);
        let expected_cues_position = seek_head.len()
            + info.len()
            + tracks.len()
            + clusters.iter().map(Vec::len).sum::<usize>();
        assert_eq!(
            seek_head,
            seek_head_for_cues(u64::try_from(expected_cues_position).unwrap())
        );

        let mut segment_payload = Vec::new();
        append(&mut segment_payload, seek_head);
        append(&mut segment_payload, info);
        append(&mut segment_payload, tracks);
        for media_cluster in clusters {
            append(&mut segment_payload, media_cluster);
        }
        append(&mut segment_payload, cues);

        let mut file = ebml_header();
        append(
            &mut file,
            element(&[0x18, 0x53, 0x80, 0x67], segment_payload),
        );
        file
    }

    fn make_file(include_cues: bool, two_audio_tracks: bool) -> Vec<u8> {
        let info = info();
        let mut track_entries = vec![video_track(1), audio_track(2, "English")];
        if two_audio_tracks {
            track_entries.push(audio_track(3, "Commentary"));
        }
        let tracks = tracks(track_entries);
        let mut first_blocks = vec![
            simple_block(1, 0, 0x80, b"video-zero"),
            simple_block(2, 0, 0x80, b"audio-zero"),
        ];
        let mut second_blocks = vec![
            simple_block(1, 0, 0x80, b"video-one"),
            simple_block(2, 0, 0x80, b"audio-one"),
        ];
        if two_audio_tracks {
            first_blocks.push(simple_block(3, 0, 0x80, b"commentary-zero"));
            second_blocks.push(simple_block(3, 0, 0x80, b"commentary-one"));
        }
        let first_cluster = cluster(0, first_blocks);
        let second_cluster = cluster(1_000, second_blocks);
        let first_position = info.len() + tracks.len();
        let second_position = first_position + first_cluster.len();

        let mut segment_payload = Vec::new();
        append(&mut segment_payload, info);
        append(&mut segment_payload, tracks);
        append(&mut segment_payload, first_cluster);
        append(&mut segment_payload, second_cluster);
        if include_cues {
            let mut cue_payload = Vec::new();
            append(&mut cue_payload, cue_point(0, 1, first_position as u64));
            append(
                &mut cue_payload,
                cue_point(1_000, 1, second_position as u64),
            );
            append(
                &mut segment_payload,
                element(&[0x1c, 0x53, 0xbb, 0x6b], cue_payload),
            );
        }

        let mut file = ebml_header();
        append(
            &mut file,
            element(&[0x18, 0x53, 0x80, 0x67], segment_payload),
        );
        file
    }

    fn open_file(bytes: Vec<u8>) -> MatroskaSession {
        MatroskaSession::open(Box::new(OwnedSource { bytes })).unwrap()
    }

    fn timing_audio_track(codec: Codec) -> MediaTrack {
        MediaTrack {
            index: 0,
            number: 1,
            uid: 1,
            kind: TrackKind::Audio,
            codec,
            codec_id: String::new(),
            codec_name: String::new(),
            name: String::new(),
            language: String::new(),
            enabled: true,
            default: true,
            forced: false,
            lacing: true,
            timestamp_scale: 1.0,
            default_duration_ns: 0,
            codec_delay_ns: 0,
            seek_pre_roll_ns: 0,
            codec_private: Vec::new(),
            pixel_width: 0,
            pixel_height: 0,
            display_width: 0,
            display_height: 0,
            frame_rate: 0.0,
            sampling_frequency: 48_000.0,
            output_sampling_frequency: 48_000.0,
            channels: 2,
            bit_depth: 0,
        }
    }

    fn frame_bytes<'a>(block: &'a [u8], parsed: &ParsedBlock) -> Vec<&'a [u8]> {
        parsed
            .frames
            .iter()
            .map(|(start, end)| &block[*start..*end])
            .collect()
    }

    #[test]
    fn opens_metadata_tracks_cues_and_reads_owned_packets() {
        let mut session = open_file(make_file(true, false));
        let summary = session.summary();
        assert_eq!(summary.document_type, "matroska");
        assert_eq!(summary.document_type_version, 4);
        assert_eq!(summary.duration_ns, 2_000_000_000);
        assert_eq!(summary.title, "Bunny fixture");
        assert_eq!(summary.track_count, 2);
        assert_eq!(summary.cue_count, 2);
        assert_eq!(summary.cluster_count, 2);

        assert_eq!(session.tracks()[0].kind, TrackKind::Video);
        assert_eq!(session.tracks()[0].codec, Codec::H264);
        assert_eq!(session.tracks()[0].pixel_width, 1920);
        assert_eq!(session.tracks()[1].kind, TrackKind::Audio);
        assert_eq!(session.tracks()[1].codec, Codec::Opus);
        assert_eq!(session.tracks()[1].sampling_frequency, 48_000.0);
        assert_eq!(session.cues()[1].time_ns, 1_000_000_000);

        let video = session.next_packet().unwrap().unwrap();
        assert_eq!(video.track_number, 1);
        assert_eq!(video.timestamp_ns, 0);
        assert_eq!(video.duration_ns, 40_000_000);
        assert_eq!(video.payload, b"video-zero");
        assert!(video.flags.contains(PacketFlags::KEYFRAME));

        let audio = session.next_packet().unwrap().unwrap();
        assert_eq!(audio.track_number, 2);
        assert_eq!(audio.payload, b"audio-zero");
        assert_eq!(audio.duration_ns, 20_000_000);
    }

    #[test]
    fn streaming_open_defers_later_cluster_and_cue_indexing() {
        let mut session = MatroskaSession::open_streaming(Box::new(OwnedSource {
            bytes: make_file(true, false),
        }))
        .unwrap();

        let startup_summary = session.summary();
        assert_eq!(startup_summary.track_count, 2);
        assert_eq!(startup_summary.cluster_count, 1);
        assert_eq!(startup_summary.cue_count, 0);

        let mut payloads = Vec::new();
        while let Some(packet) = session.next_packet().unwrap() {
            payloads.push(packet.payload);
        }
        assert!(payloads.iter().any(|payload| payload == b"video-zero"));
        assert!(payloads.iter().any(|payload| payload == b"video-one"));

        let completed_summary = session.summary();
        assert_eq!(completed_summary.cluster_count, 2);
        assert_eq!(completed_summary.cue_count, 2);
    }

    #[test]
    fn opens_finite_matroska_segment_from_sparse_eighty_gibibyte_source() {
        let bytes = make_file(true, false);
        let logical_len = 80_u64 * 1_024 * 1_024 * 1_024;
        let mut session = MatroskaSession::open_streaming(Box::new(SparseTailSource {
            bytes,
            logical_len,
        }))
        .unwrap();

        assert_eq!(session.summary().track_count, 2);
        let first = session.next_packet().unwrap().unwrap();
        assert_eq!(first.payload, b"video-zero");
    }

    #[test]
    fn infers_distinct_timestamps_for_laced_aac_opus_and_flac() {
        let cases = [
            (
                Codec::Aac,
                vec![1, 0x11, 0x22],
                vec![21_333_333_u64, 21_333_333],
            ),
            (
                Codec::Opus,
                vec![1, 0x80, 0x98],
                vec![2_500_000_u64, 20_000_000],
            ),
            (
                Codec::Flac,
                vec![
                    1, 0xff, 0xf8, 0x80, 0x00, 0x00, 0xff, 0xf8, 0x80, 0x00, 0x00,
                ],
                vec![5_333_333_u64, 5_333_333],
            ),
        ];

        for (codec, lace_payload, expected_durations) in cases {
            let block = raw_block(1, 0, 0x84, &lace_payload);
            let packets = packets_from_block(
                block,
                0,
                DEFAULT_TIMESTAMP_SCALE_NS,
                &[timing_audio_track(codec)],
                &[true],
                true,
                None,
                0,
                true,
            )
            .unwrap();

            assert_eq!(packets.len(), 2);
            assert_eq!(packets[0].duration_ns, expected_durations[0]);
            assert_eq!(packets[1].duration_ns, expected_durations[1]);
            assert_eq!(packets[0].timestamp_ns, 0);
            assert_eq!(packets[1].timestamp_ns, expected_durations[0] as i64);
            assert!(packets.iter().all(|packet| packet.flags.contains(PacketFlags::LACED)));
        }
    }

    #[test]
    fn streaming_seek_discovers_only_the_clusters_needed_for_the_target() {
        let mut session = MatroskaSession::open_streaming(Box::new(OwnedSource {
            bytes: make_file(true, false),
        }))
        .unwrap();
        session.set_kind_selected(TrackKind::Audio, false);
        session.seek(1_500_000_000).unwrap();

        let packet = session.next_packet().unwrap().unwrap();
        assert_eq!(packet.timestamp_ns, 1_000_000_000);
        assert_eq!(packet.payload, b"video-one");
        assert_eq!(session.summary().cluster_count, 2);
    }

    #[test]
    fn streaming_seek_loads_end_cues_and_jumps_directly_to_target_cluster() {
        let mut session = MatroskaSession::open_streaming(Box::new(OwnedSource {
            bytes: make_seek_head_streaming_file(12),
        }))
        .unwrap();
        session.set_kind_selected(TrackKind::Audio, false);

        assert_eq!(session.summary().cluster_count, 1);
        assert_eq!(session.summary().cue_count, 0);
        assert_eq!(session.clusters[0].timestamp_units, 0);

        session.seek(10_500_000_000).unwrap();

        assert_eq!(session.summary().cue_count, 12);
        assert_eq!(session.clusters.len(), 1);
        assert_eq!(session.clusters[0].timestamp_units, 10_000);
        let packet = session.next_packet().unwrap().unwrap();
        assert_eq!(packet.timestamp_ns, 10_000_000_000);
        assert_eq!(packet.payload, b"video-10");
    }

    #[test]
    fn prepares_streaming_seek_index_without_moving_playback_cursor() {
        let mut session = MatroskaSession::open_streaming(Box::new(OwnedSource {
            bytes: make_seek_head_streaming_file(12),
        }))
        .unwrap();
        session.set_kind_selected(TrackKind::Audio, false);

        session.prepare_seek_index().unwrap();
        session.prepare_seek_index().unwrap();

        assert_eq!(session.summary().cue_count, 12);
        assert_eq!(session.summary().cluster_count, 1);
        assert_eq!(session.clusters[0].timestamp_units, 0);
        let first = session.next_packet().unwrap().unwrap();
        assert_eq!(first.timestamp_ns, 0);
        assert_eq!(first.payload, b"video-0");

        session.seek(10_500_000_000).unwrap();
        let sought = session.next_packet().unwrap().unwrap();
        assert_eq!(sought.timestamp_ns, 10_000_000_000);
        assert_eq!(sought.payload, b"video-10");
    }

    #[test]
    fn parses_none_xiph_fixed_and_ebml_lacing() {
        let none = raw_block(1, -2, 0x80, b"single");
        let parsed = parse_block_layout(&none).unwrap();
        assert_eq!(parsed.relative_timestamp, -2);
        assert_eq!(frame_bytes(&none, &parsed), vec![b"single".as_slice()]);

        let mut xiph_payload = vec![2, 0xff, 1, 3];
        xiph_payload.extend(vec![b'a'; 256]);
        xiph_payload.extend_from_slice(b"bbb");
        xiph_payload.extend_from_slice(b"cccc");
        let xiph = raw_block(1, 0, 0x82, &xiph_payload);
        let parsed = parse_block_layout(&xiph).unwrap();
        let frames = frame_bytes(&xiph, &parsed);
        assert_eq!(
            frames.iter().map(|frame| frame.len()).collect::<Vec<_>>(),
            [256, 3, 4]
        );
        assert!(frames[0].iter().all(|byte| *byte == b'a'));

        let mut fixed_payload = vec![2];
        fixed_payload.extend_from_slice(b"aaabbbccc");
        let fixed = raw_block(1, 0, 0x84, &fixed_payload);
        let parsed = parse_block_layout(&fixed).unwrap();
        assert_eq!(
            frame_bytes(&fixed, &parsed),
            vec![b"aaa".as_slice(), b"bbb".as_slice(), b"ccc".as_slice()]
        );

        let mut ebml_payload = vec![2, 0x82, 0xc0];
        ebml_payload.extend_from_slice(b"aabbbcccc");
        let ebml = raw_block(1, 0, 0x86, &ebml_payload);
        let parsed = parse_block_layout(&ebml).unwrap();
        assert_eq!(
            frame_bytes(&ebml, &parsed),
            vec![b"aa".as_slice(), b"bbb".as_slice(), b"cccc".as_slice()]
        );
    }

    #[test]
    fn block_group_applies_duration_padding_and_reference_semantics() {
        let mut keyframe_group = Vec::new();
        append(
            &mut keyframe_group,
            element(&[0xa1], raw_block(1, 5, 0, b"group-key")),
        );
        append(&mut keyframe_group, uint_element(&[0x9b], 40));
        append(&mut keyframe_group, signed_element(&[0x75, 0xa2], -5));

        let mut referenced_group = Vec::new();
        append(
            &mut referenced_group,
            element(&[0xa1], raw_block(1, 45, 0, b"group-delta")),
        );
        append(&mut referenced_group, signed_element(&[0xfb], -1));

        let info = info();
        let tracks = tracks(vec![video_track(1)]);
        let media_cluster = cluster(
            1_000,
            vec![
                element(&[0xa0], keyframe_group),
                element(&[0xa0], referenced_group),
            ],
        );
        let mut segment = Vec::new();
        append(&mut segment, info);
        append(&mut segment, tracks);
        append(&mut segment, media_cluster);
        let mut file = ebml_header();
        append(&mut file, element(&[0x18, 0x53, 0x80, 0x67], segment));

        let mut session = open_file(file);
        let keyframe = session.next_packet().unwrap().unwrap();
        assert_eq!(keyframe.timestamp_ns, 1_005_000_000);
        assert_eq!(keyframe.duration_ns, 40_000_000);
        assert_eq!(keyframe.discard_padding_ns, -5);
        assert!(keyframe.flags.contains(PacketFlags::KEYFRAME));

        let delta = session.next_packet().unwrap().unwrap();
        assert_eq!(delta.timestamp_ns, 1_045_000_000);
        assert!(!delta.flags.contains(PacketFlags::KEYFRAME));
    }

    #[test]
    fn applies_track_timestamp_scale_codec_delay_and_preserves_negative_preroll() {
        let mut duration_group = Vec::new();
        append(
            &mut duration_group,
            element(&[0xa1], raw_block(1, -4, 0, b"scaled")),
        );
        append(&mut duration_group, uint_element(&[0x9b], 4));

        let mut segment = Vec::new();
        append(&mut segment, info());
        append(
            &mut segment,
            tracks(vec![scaled_video_track(1, 0.5, 2_000_000)]),
        );
        append(
            &mut segment,
            cluster(0, vec![simple_block(1, 0, 0x80, b"preroll")]),
        );
        append(
            &mut segment,
            cluster(10, vec![element(&[0xa0], duration_group)]),
        );
        let mut file = ebml_header();
        append(&mut file, element(&[0x18, 0x53, 0x80, 0x67], segment));

        let mut session = open_file(file);
        assert_eq!(session.tracks()[0].timestamp_scale, 0.5);
        let preroll = session.next_packet().unwrap().unwrap();
        assert_eq!(preroll.timestamp_ns, -2_000_000);
        let scaled = session.next_packet().unwrap().unwrap();
        assert_eq!(scaled.timestamp_ns, 6_000_000);
        assert_eq!(scaled.duration_ns, 2_000_000);
    }

    #[test]
    fn supports_selection_by_kind_and_track_index() {
        let mut session = open_file(make_file(false, true));
        session.set_kind_selected(TrackKind::Video, false);
        session.select_track(2).unwrap();
        let packet = session.next_packet().unwrap().unwrap();
        assert_eq!(packet.track_number, 3);
        assert_eq!(packet.payload, b"commentary-zero");
        assert!(!session.is_track_selected(0));
        assert!(!session.is_track_selected(1));
        assert!(session.is_track_selected(2));
    }

    #[test]
    fn seeks_with_cues_and_falls_back_to_cluster_timestamps() {
        let mut cued = open_file(make_file(true, false));
        cued.set_kind_selected(TrackKind::Audio, false);
        cued.seek(1_500_000_000).unwrap();
        let packet = cued.next_packet().unwrap().unwrap();
        assert_eq!(packet.timestamp_ns, 1_000_000_000);
        assert_eq!(packet.payload, b"video-one");

        let mut uncued = open_file(make_file(false, false));
        uncued.set_kind_selected(TrackKind::Audio, false);
        uncued.seek(1_500_000_000).unwrap();
        let packet = uncued.next_packet().unwrap().unwrap();
        assert_eq!(packet.timestamp_ns, 1_000_000_000);
        assert_eq!(packet.payload, b"video-one");
    }

    #[test]
    fn cue_relative_position_starts_at_the_indexed_random_access_block() {
        let timestamp = uint_element(&[0xe7], 0);
        let preroll = simple_block(1, 0, 0, b"not-the-cue");
        let random_access = simple_block(1, 20, 0x80, b"cue-target");
        let relative_position = timestamp.len() + preroll.len();
        let mut cluster_payload = Vec::new();
        append(&mut cluster_payload, timestamp);
        append(&mut cluster_payload, preroll);
        append(&mut cluster_payload, random_access);
        let media_cluster = element(&[0x1f, 0x43, 0xb6, 0x75], cluster_payload);

        let info = info();
        let tracks = tracks(vec![video_track(1)]);
        let cluster_position = info.len() + tracks.len();
        let mut cue_payload = Vec::new();
        append(
            &mut cue_payload,
            cue_point_relative(20, 1, cluster_position as u64, relative_position as u64),
        );

        let mut segment = Vec::new();
        append(&mut segment, info);
        append(&mut segment, tracks);
        append(&mut segment, media_cluster);
        append(
            &mut segment,
            element(&[0x1c, 0x53, 0xbb, 0x6b], cue_payload),
        );
        let mut file = ebml_header();
        append(&mut file, element(&[0x18, 0x53, 0x80, 0x67], segment));

        let mut session = open_file(file);
        session.seek(20_000_000).unwrap();
        let packet = session.next_packet().unwrap().unwrap();
        assert_eq!(packet.payload, b"cue-target");
        assert_eq!(packet.timestamp_ns, 20_000_000);
    }

    #[test]
    fn indexes_and_reads_unknown_sized_segment_and_clusters() {
        let mut first_cluster = Vec::new();
        append(&mut first_cluster, uint_element(&[0xe7], 0));
        append(
            &mut first_cluster,
            simple_block(1, 0, 0x80, b"unknown-zero"),
        );
        let mut second_cluster = Vec::new();
        append(&mut second_cluster, uint_element(&[0xe7], 1_000));
        append(
            &mut second_cluster,
            simple_block(1, 0, 0x80, b"unknown-one"),
        );

        let mut segment = Vec::new();
        append(&mut segment, info());
        append(&mut segment, tracks(vec![video_track(1)]));
        append(
            &mut segment,
            unknown_sized_element(&[0x1f, 0x43, 0xb6, 0x75], first_cluster),
        );
        append(
            &mut segment,
            unknown_sized_element(&[0x1f, 0x43, 0xb6, 0x75], second_cluster),
        );
        let mut file = ebml_header();
        append(
            &mut file,
            unknown_sized_element(&[0x18, 0x53, 0x80, 0x67], segment),
        );

        let mut session = open_file(file);
        assert_eq!(session.summary().cluster_count, 2);
        assert_eq!(
            session.next_packet().unwrap().unwrap().payload,
            b"unknown-zero"
        );
        assert_eq!(
            session.next_packet().unwrap().unwrap().payload,
            b"unknown-one"
        );
        assert!(session.next_packet().unwrap().is_none());
    }

    #[test]
    fn rejects_malformed_lace_sizes_without_allocating_frames() {
        let malformed_xiph = raw_block(1, 0, 0x82, &[1, 10, 1, 2]);
        assert_eq!(
            parse_block_layout(&malformed_xiph).unwrap_err(),
            MediaError::InvalidData("Xiph lace sizes exceed block")
        );

        let malformed_fixed = raw_block(1, 0, 0x84, &[2, 1, 2, 3, 4]);
        assert_eq!(
            parse_block_layout(&malformed_fixed).unwrap_err(),
            MediaError::InvalidData("fixed lace has uneven frame sizes")
        );

        let single_frame_lace = raw_block(1, 0, 0x82, &[0, 1]);
        assert_eq!(
            parse_block_layout(&single_frame_lace).unwrap_err(),
            MediaError::InvalidData("lacing cannot contain a single frame")
        );
    }

    #[test]
    fn rejects_unsafe_track_dimensions_and_audio_fields() {
        let mut oversized_video = Vec::new();
        append(
            &mut oversized_video,
            uint_element(&[0xb0], MAX_VIDEO_DIMENSION + 1),
        );
        append(&mut oversized_video, uint_element(&[0xba], 1080));
        let mut video_entry = Vec::new();
        append(&mut video_entry, uint_element(&[0xd7], 1));
        append(&mut video_entry, uint_element(&[0x83], 1));
        append(&mut video_entry, string_element(&[0x86], "V_MPEG4/ISO/AVC"));
        append(&mut video_entry, element(&[0xe0], oversized_video));

        let mut segment = Vec::new();
        append(&mut segment, info());
        append(&mut segment, tracks(vec![element(&[0xae], video_entry)]));
        let mut file = ebml_header();
        append(&mut file, element(&[0x18, 0x53, 0x80, 0x67], segment));
        assert_eq!(
            MatroskaSession::open(Box::new(OwnedSource { bytes: file }))
                .err()
                .unwrap(),
            MediaError::InvalidData("video dimensions exceed safety limit")
        );

        let mut unsafe_audio = Vec::new();
        append(&mut unsafe_audio, float_element(&[0xb5], 48_000.0));
        append(
            &mut unsafe_audio,
            uint_element(&[0x9f], MAX_AUDIO_CHANNELS + 1),
        );
        let mut audio_entry = Vec::new();
        append(&mut audio_entry, uint_element(&[0xd7], 1));
        append(&mut audio_entry, uint_element(&[0x83], 2));
        append(&mut audio_entry, string_element(&[0x86], "A_PCM/INT/LIT"));
        append(&mut audio_entry, element(&[0xe1], unsafe_audio));

        let mut segment = Vec::new();
        append(&mut segment, info());
        append(&mut segment, tracks(vec![element(&[0xae], audio_entry)]));
        let mut file = ebml_header();
        append(&mut file, element(&[0x18, 0x53, 0x80, 0x67], segment));
        assert_eq!(
            MatroskaSession::open(Box::new(OwnedSource { bytes: file }))
                .err()
                .unwrap(),
            MediaError::InvalidData("audio channel count exceeds safety limit")
        );
    }

    #[test]
    fn rejects_excessive_track_cardinality() {
        let entries = (1..=MAX_TRACKS + 1)
            .map(|number| audio_track(number as u64, "bounded"))
            .collect();
        let mut segment = Vec::new();
        append(&mut segment, info());
        append(&mut segment, tracks(entries));
        let mut file = ebml_header();
        append(&mut file, element(&[0x18, 0x53, 0x80, 0x67], segment));
        assert_eq!(
            MatroskaSession::open(Box::new(OwnedSource { bytes: file }))
                .err()
                .unwrap(),
            MediaError::ElementTooLarge
        );
    }
}
