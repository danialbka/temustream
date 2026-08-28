//! Clean-room media container support for Bunny.
//!
//! This module intentionally depends only on Rust's standard library. It
//! parses container metadata and compressed packets; Apple system frameworks
//! remain responsible for codec decompression and presentation.

mod audio;
mod ebml;
mod ffi;
mod matroska;
mod pgs;
mod subtitles;

pub use ebml::{CallbackSource, MediaError, ReadAt, SliceSource, SourceCallbacks};
pub use matroska::{
    Codec, ContainerSummary, CuePoint, MatroskaSession, MediaPacket, MediaTrack, PacketFlags,
    TrackKind,
};
pub use pgs::{
    CompositionState, PGS_CLOCK_HZ, PGS_SEGMENT_COMPOSITION, PGS_SEGMENT_END, PGS_SEGMENT_OBJECT,
    PGS_SEGMENT_PALETTE, PGS_SEGMENT_WINDOW, PgsBitmapPart, PgsDecoder, PgsError, PgsPresentation,
    Rgba, decode_pgs_rle_indices, decode_pgs_sup, pgs_ycrcb_to_rgba,
};
pub use subtitles::{
    SubtitleCue, SubtitleError, SubtitleFormat, parse_subtitle_bytes, parse_subtitle_document,
};
