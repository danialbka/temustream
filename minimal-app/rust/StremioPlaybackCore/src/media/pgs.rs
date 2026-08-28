//! Blu-ray Presentation Graphic Stream (PGS) parsing.
//!
//! This is a clean-room, bounded implementation of the public PGS segment
//! format. It assembles fragmented objects, decodes the palette-index RLE, and
//! emits straight-alpha RGBA parts positioned in the composition canvas.

use std::{collections::HashMap, error::Error, fmt};

pub const PGS_CLOCK_HZ: u64 = 90_000;
pub const PGS_SEGMENT_PALETTE: u8 = 0x14;
pub const PGS_SEGMENT_OBJECT: u8 = 0x15;
pub const PGS_SEGMENT_COMPOSITION: u8 = 0x16;
pub const PGS_SEGMENT_WINDOW: u8 = 0x17;
pub const PGS_SEGMENT_END: u8 = 0x80;

const MAX_SUP_BYTES: usize = 128 * 1024 * 1024;
const MAX_CANVAS_DIMENSION: usize = 16_384;
const MAX_OBJECT_PIXELS: usize = 8 * 1024 * 1024;
const MAX_OBJECT_RLE_BYTES: usize = 8 * 1024 * 1024;
const MAX_PRESENTATION_RGBA_BYTES: usize = 32 * 1024 * 1024;
const MAX_COMPOSITION_OBJECTS: usize = 64;
const MAX_CACHED_OBJECTS: usize = 64;
const MAX_INCOMPLETE_OBJECTS: usize = 64;
const MAX_CACHED_OBJECT_BYTES: usize = 64 * 1024 * 1024;
const MAX_ASSEMBLY_BYTES: usize = 32 * 1024 * 1024;
const MAX_PRESENTATIONS: usize = 200_000;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Rgba {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub alpha: u8,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompositionState {
    Normal,
    AcquisitionPoint,
    EpochStart,
    Unknown(u8),
}

impl From<u8> for CompositionState {
    fn from(value: u8) -> Self {
        match value {
            0x00 => Self::Normal,
            0x40 => Self::AcquisitionPoint,
            0x80 => Self::EpochStart,
            other => Self::Unknown(other),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PgsBitmapPart {
    pub object_id: u16,
    pub window_id: u8,
    pub forced: bool,
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
    /// Straight-alpha RGBA pixels, tightly packed in row-major order.
    pub rgba: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PgsPresentation {
    pub pts_90khz: u64,
    pub pts_us: u64,
    pub canvas_width: u16,
    pub canvas_height: u16,
    pub composition_number: u16,
    pub composition_state: CompositionState,
    pub palette_id: u8,
    pub palette_update: bool,
    pub parts: Vec<PgsBitmapPart>,
}

impl PgsPresentation {
    /// An empty composition explicitly clears the previous PGS overlay.
    pub fn is_clear(&self) -> bool {
        self.parts.is_empty()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PgsError {
    InputTooLarge {
        bytes: usize,
        limit: usize,
    },
    InvalidSupHeader {
        offset: usize,
    },
    TruncatedSegment {
        offset: usize,
        needed: usize,
    },
    MalformedSegment {
        segment_type: u8,
        reason: &'static str,
    },
    LimitExceeded {
        resource: &'static str,
        limit: usize,
    },
    MissingPalette(u8),
    MissingObject(u16),
    IncompleteObject(u16),
    RleMalformed(&'static str),
}

impl fmt::Display for PgsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InputTooLarge { bytes, limit } => {
                write!(formatter, "PGS input is {bytes} bytes; limit is {limit}")
            }
            Self::InvalidSupHeader { offset } => {
                write!(formatter, "invalid PGS SUP header at byte {offset}")
            }
            Self::TruncatedSegment { offset, needed } => {
                write!(
                    formatter,
                    "truncated PGS segment at byte {offset}; needs {needed} bytes"
                )
            }
            Self::MalformedSegment {
                segment_type,
                reason,
            } => write!(
                formatter,
                "malformed PGS segment 0x{segment_type:02x}: {reason}"
            ),
            Self::LimitExceeded { resource, limit } => {
                write!(formatter, "PGS {resource} exceeds limit {limit}")
            }
            Self::MissingPalette(id) => write!(formatter, "PGS palette {id} is not available"),
            Self::MissingObject(id) => write!(formatter, "PGS object {id} is not available"),
            Self::IncompleteObject(id) => write!(formatter, "PGS object {id} is incomplete"),
            Self::RleMalformed(reason) => write!(formatter, "malformed PGS RLE: {reason}"),
        }
    }
}

impl Error for PgsError {}

#[derive(Clone)]
struct Palette {
    entries: [Rgba; 256],
}

impl Default for Palette {
    fn default() -> Self {
        Self {
            entries: [Rgba::default(); 256],
        }
    }
}

#[derive(Clone, Debug)]
struct ObjectDefinition {
    version: u8,
    width: u16,
    height: u16,
    indices: Vec<u8>,
}

#[derive(Debug)]
struct ObjectAssembly {
    version: u8,
    width: u16,
    height: u16,
    expected_bytes: usize,
    rle: Vec<u8>,
}

#[derive(Clone, Copy, Debug)]
struct WindowDefinition {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
}

#[derive(Clone, Copy, Debug)]
struct Crop {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
}

#[derive(Clone, Copy, Debug)]
struct CompositionObject {
    object_id: u16,
    window_id: u8,
    forced: bool,
    x: u16,
    y: u16,
    crop: Option<Crop>,
}

#[derive(Clone, Debug)]
struct PendingComposition {
    pts_90khz: u64,
    canvas_width: u16,
    canvas_height: u16,
    composition_number: u16,
    composition_state: CompositionState,
    palette_update: bool,
    palette_id: u8,
    objects: Vec<CompositionObject>,
}

#[derive(Default)]
pub struct PgsDecoder {
    palettes: HashMap<u8, Palette>,
    objects: HashMap<u16, ObjectDefinition>,
    object_bytes: usize,
    assembling: HashMap<u16, ObjectAssembly>,
    assembly_bytes: usize,
    windows: HashMap<u8, WindowDefinition>,
    pending: Option<PendingComposition>,
}

impl PgsDecoder {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }

    /// Pushes one raw PGS segment. This entry point is suitable for Matroska
    /// `S_HDMV/PGS` packets; [`decode_pgs_sup`] handles `.sup` packet headers.
    pub fn push_segment(
        &mut self,
        pts_90khz: u64,
        segment_type: u8,
        payload: &[u8],
    ) -> Result<Option<PgsPresentation>, PgsError> {
        match segment_type {
            PGS_SEGMENT_PALETTE => self.parse_palette(payload)?,
            PGS_SEGMENT_OBJECT => self.parse_object(payload)?,
            PGS_SEGMENT_COMPOSITION => self.parse_composition(pts_90khz, payload)?,
            PGS_SEGMENT_WINDOW => self.parse_windows(payload)?,
            PGS_SEGMENT_END => return self.finish_presentation(),
            _ => {
                // Reserved/unknown segments are length-delimited by their
                // container, so safely ignoring them preserves forward
                // compatibility without guessing their structure.
            }
        }
        Ok(None)
    }

    fn parse_palette(&mut self, payload: &[u8]) -> Result<(), PgsError> {
        if payload.len() < 2 || !(payload.len() - 2).is_multiple_of(5) {
            return Err(malformed(
                PGS_SEGMENT_PALETTE,
                "invalid palette payload length",
            ));
        }
        let palette_id = payload[0];
        let palette = self.palettes.entry(palette_id).or_default();
        for entry in payload[2..].chunks_exact(5) {
            palette.entries[usize::from(entry[0])] =
                pgs_ycrcb_to_rgba(entry[1], entry[2], entry[3], entry[4]);
        }
        Ok(())
    }

    fn parse_object(&mut self, payload: &[u8]) -> Result<(), PgsError> {
        if payload.len() < 4 {
            return Err(malformed(PGS_SEGMENT_OBJECT, "object header is truncated"));
        }
        let object_id = be_u16(payload, 0).expect("length checked");
        let version = payload[2];
        let sequence = payload[3];
        let first = sequence & 0x80 != 0;
        let last = sequence & 0x40 != 0;

        if first {
            if payload.len() < 11 {
                return Err(malformed(
                    PGS_SEGMENT_OBJECT,
                    "first object fragment is truncated",
                ));
            }
            let object_data_length = be_u24(payload, 4).expect("length checked") as usize;
            if object_data_length < 4 {
                return Err(malformed(
                    PGS_SEGMENT_OBJECT,
                    "object data length excludes dimensions",
                ));
            }
            let expected_bytes = object_data_length - 4;
            if expected_bytes > MAX_OBJECT_RLE_BYTES {
                return Err(PgsError::LimitExceeded {
                    resource: "object RLE bytes",
                    limit: MAX_OBJECT_RLE_BYTES,
                });
            }
            let width = be_u16(payload, 7).expect("length checked");
            let height = be_u16(payload, 9).expect("length checked");
            checked_pixel_count(width, height)?;
            let initial = &payload[11..];
            if initial.len() > expected_bytes {
                return Err(malformed(
                    PGS_SEGMENT_OBJECT,
                    "object data exceeds declared length",
                ));
            }
            if let Some(previous) = self.assembling.remove(&object_id) {
                self.assembly_bytes = self.assembly_bytes.saturating_sub(previous.rle.len());
            } else if self.assembling.len() >= MAX_INCOMPLETE_OBJECTS {
                return Err(PgsError::LimitExceeded {
                    resource: "incomplete objects",
                    limit: MAX_INCOMPLETE_OBJECTS,
                });
            }
            self.assembly_bytes =
                self.assembly_bytes
                    .checked_add(initial.len())
                    .ok_or(PgsError::LimitExceeded {
                        resource: "object assembly bytes",
                        limit: MAX_ASSEMBLY_BYTES,
                    })?;
            if self.assembly_bytes > MAX_ASSEMBLY_BYTES {
                return Err(PgsError::LimitExceeded {
                    resource: "object assembly bytes",
                    limit: MAX_ASSEMBLY_BYTES,
                });
            }
            self.assembling.insert(
                object_id,
                ObjectAssembly {
                    version,
                    width,
                    height,
                    expected_bytes,
                    rle: initial.to_vec(),
                },
            );
        } else {
            let Some(assembly) = self.assembling.get_mut(&object_id) else {
                return Err(PgsError::IncompleteObject(object_id));
            };
            if assembly.version != version {
                return Err(malformed(PGS_SEGMENT_OBJECT, "fragment version changed"));
            }
            let fragment = &payload[4..];
            if fragment.len() > assembly.expected_bytes.saturating_sub(assembly.rle.len()) {
                return Err(malformed(
                    PGS_SEGMENT_OBJECT,
                    "object fragments exceed declared length",
                ));
            }
            self.assembly_bytes =
                self.assembly_bytes
                    .checked_add(fragment.len())
                    .ok_or(PgsError::LimitExceeded {
                        resource: "object assembly bytes",
                        limit: MAX_ASSEMBLY_BYTES,
                    })?;
            if self.assembly_bytes > MAX_ASSEMBLY_BYTES {
                return Err(PgsError::LimitExceeded {
                    resource: "object assembly bytes",
                    limit: MAX_ASSEMBLY_BYTES,
                });
            }
            assembly.rle.extend_from_slice(fragment);
        }

        if last {
            let Some(assembly) = self.assembling.remove(&object_id) else {
                return Err(PgsError::IncompleteObject(object_id));
            };
            self.assembly_bytes = self.assembly_bytes.saturating_sub(assembly.rle.len());
            if assembly.rle.len() != assembly.expected_bytes {
                return Err(PgsError::IncompleteObject(object_id));
            }
            let indices = decode_pgs_rle_indices(assembly.width, assembly.height, &assembly.rle)?;
            if !self.objects.contains_key(&object_id) && self.objects.len() >= MAX_CACHED_OBJECTS {
                return Err(PgsError::LimitExceeded {
                    resource: "cached objects",
                    limit: MAX_CACHED_OBJECTS,
                });
            }
            let previous_bytes = self
                .objects
                .get(&object_id)
                .map_or(0, |object| object.indices.len());
            let next_object_bytes = self
                .object_bytes
                .saturating_sub(previous_bytes)
                .checked_add(indices.len())
                .ok_or(PgsError::LimitExceeded {
                    resource: "cached object bytes",
                    limit: MAX_CACHED_OBJECT_BYTES,
                })?;
            if next_object_bytes > MAX_CACHED_OBJECT_BYTES {
                return Err(PgsError::LimitExceeded {
                    resource: "cached object bytes",
                    limit: MAX_CACHED_OBJECT_BYTES,
                });
            }
            self.objects.insert(
                object_id,
                ObjectDefinition {
                    version: assembly.version,
                    width: assembly.width,
                    height: assembly.height,
                    indices,
                },
            );
            self.object_bytes = next_object_bytes;
        }
        Ok(())
    }

    fn parse_composition(&mut self, pts_90khz: u64, payload: &[u8]) -> Result<(), PgsError> {
        if payload.len() < 11 {
            return Err(malformed(
                PGS_SEGMENT_COMPOSITION,
                "composition header is truncated",
            ));
        }
        let canvas_width = be_u16(payload, 0).expect("length checked");
        let canvas_height = be_u16(payload, 2).expect("length checked");
        checked_canvas(canvas_width, canvas_height)?;
        let composition_number = be_u16(payload, 5).expect("length checked");
        let composition_state = CompositionState::from(payload[7]);
        if composition_state == CompositionState::EpochStart {
            self.palettes.clear();
            self.objects.clear();
            self.object_bytes = 0;
            self.assembling.clear();
            self.assembly_bytes = 0;
            self.windows.clear();
        }
        let object_count = usize::from(payload[10]);
        if object_count > MAX_COMPOSITION_OBJECTS {
            return Err(PgsError::LimitExceeded {
                resource: "composition objects",
                limit: MAX_COMPOSITION_OBJECTS,
            });
        }
        let mut offset = 11;
        let mut objects = Vec::with_capacity(object_count);
        for _ in 0..object_count {
            if payload.len().saturating_sub(offset) < 8 {
                return Err(malformed(
                    PGS_SEGMENT_COMPOSITION,
                    "composition object is truncated",
                ));
            }
            let object_id = be_u16(payload, offset).expect("length checked");
            let window_id = payload[offset + 2];
            let flags = payload[offset + 3];
            let x = be_u16(payload, offset + 4).expect("length checked");
            let y = be_u16(payload, offset + 6).expect("length checked");
            offset += 8;
            let crop = if flags & 0x80 != 0 {
                if payload.len().saturating_sub(offset) < 8 {
                    return Err(malformed(
                        PGS_SEGMENT_COMPOSITION,
                        "object crop is truncated",
                    ));
                }
                let crop = Crop {
                    x: be_u16(payload, offset).expect("length checked"),
                    y: be_u16(payload, offset + 2).expect("length checked"),
                    width: be_u16(payload, offset + 4).expect("length checked"),
                    height: be_u16(payload, offset + 6).expect("length checked"),
                };
                offset += 8;
                Some(crop)
            } else {
                None
            };
            objects.push(CompositionObject {
                object_id,
                window_id,
                forced: flags & 0x40 != 0,
                x,
                y,
                crop,
            });
        }
        if offset != payload.len() {
            return Err(malformed(
                PGS_SEGMENT_COMPOSITION,
                "composition has trailing bytes",
            ));
        }
        self.pending = Some(PendingComposition {
            pts_90khz,
            canvas_width,
            canvas_height,
            composition_number,
            composition_state,
            palette_update: payload[8] & 0x80 != 0,
            palette_id: payload[9],
            objects,
        });
        Ok(())
    }

    fn parse_windows(&mut self, payload: &[u8]) -> Result<(), PgsError> {
        let Some(&count) = payload.first() else {
            return Err(malformed(PGS_SEGMENT_WINDOW, "window header is truncated"));
        };
        let count = usize::from(count);
        let expected = 1_usize
            .checked_add(count.checked_mul(9).ok_or(PgsError::LimitExceeded {
                resource: "windows",
                limit: 256,
            })?)
            .ok_or(PgsError::LimitExceeded {
                resource: "windows",
                limit: 256,
            })?;
        if payload.len() != expected {
            return Err(malformed(
                PGS_SEGMENT_WINDOW,
                "invalid window payload length",
            ));
        }
        self.windows.clear();
        for window in payload[1..].chunks_exact(9) {
            let definition = WindowDefinition {
                x: be_u16(window, 1).expect("chunk length checked"),
                y: be_u16(window, 3).expect("chunk length checked"),
                width: be_u16(window, 5).expect("chunk length checked"),
                height: be_u16(window, 7).expect("chunk length checked"),
            };
            if definition.width == 0 || definition.height == 0 {
                return Err(malformed(PGS_SEGMENT_WINDOW, "window has zero area"));
            }
            self.windows.insert(window[0], definition);
        }
        Ok(())
    }

    fn finish_presentation(&mut self) -> Result<Option<PgsPresentation>, PgsError> {
        let Some(composition) = self.pending.take() else {
            return Ok(None);
        };
        let mut parts = Vec::with_capacity(composition.objects.len());
        let mut rgba_bytes = 0_usize;
        if !composition.objects.is_empty() {
            let palette = self
                .palettes
                .get(&composition.palette_id)
                .ok_or(PgsError::MissingPalette(composition.palette_id))?;
            for reference in &composition.objects {
                let object = self
                    .objects
                    .get(&reference.object_id)
                    .ok_or(PgsError::MissingObject(reference.object_id))?;
                let _version = object.version;
                let Some(region) = visible_region(
                    reference,
                    object,
                    self.windows.get(&reference.window_id).copied(),
                    composition.canvas_width,
                    composition.canvas_height,
                )?
                else {
                    continue;
                };
                let pixel_count = usize::from(region.width)
                    .checked_mul(usize::from(region.height))
                    .ok_or(PgsError::LimitExceeded {
                        resource: "presentation pixels",
                        limit: MAX_PRESENTATION_RGBA_BYTES / 4,
                    })?;
                let part_bytes = pixel_count.checked_mul(4).ok_or(PgsError::LimitExceeded {
                    resource: "presentation RGBA bytes",
                    limit: MAX_PRESENTATION_RGBA_BYTES,
                })?;
                rgba_bytes = rgba_bytes
                    .checked_add(part_bytes)
                    .ok_or(PgsError::LimitExceeded {
                        resource: "presentation RGBA bytes",
                        limit: MAX_PRESENTATION_RGBA_BYTES,
                    })?;
                if rgba_bytes > MAX_PRESENTATION_RGBA_BYTES {
                    return Err(PgsError::LimitExceeded {
                        resource: "presentation RGBA bytes",
                        limit: MAX_PRESENTATION_RGBA_BYTES,
                    });
                }
                let mut rgba = Vec::with_capacity(part_bytes);
                let object_width = usize::from(object.width);
                for row in 0..usize::from(region.height) {
                    let source_offset = (usize::from(region.source_y) + row)
                        .checked_mul(object_width)
                        .and_then(|offset| offset.checked_add(usize::from(region.source_x)))
                        .ok_or(PgsError::RleMalformed("object pixel offset overflow"))?;
                    let source_end = source_offset
                        .checked_add(usize::from(region.width))
                        .ok_or(PgsError::RleMalformed("object row overflow"))?;
                    let source = object
                        .indices
                        .get(source_offset..source_end)
                        .ok_or(PgsError::RleMalformed("object row is out of bounds"))?;
                    for &index in source {
                        let color = palette.entries[usize::from(index)];
                        rgba.extend_from_slice(&[color.red, color.green, color.blue, color.alpha]);
                    }
                }
                parts.push(PgsBitmapPart {
                    object_id: reference.object_id,
                    window_id: reference.window_id,
                    forced: reference.forced,
                    x: region.destination_x,
                    y: region.destination_y,
                    width: region.width,
                    height: region.height,
                    rgba,
                });
            }
        }
        let pts_us = ((u128::from(composition.pts_90khz) * 1_000_000) / u128::from(PGS_CLOCK_HZ))
            .min(u128::from(u64::MAX)) as u64;
        Ok(Some(PgsPresentation {
            pts_90khz: composition.pts_90khz,
            pts_us,
            canvas_width: composition.canvas_width,
            canvas_height: composition.canvas_height,
            composition_number: composition.composition_number,
            composition_state: composition.composition_state,
            palette_id: composition.palette_id,
            palette_update: composition.palette_update,
            parts,
        }))
    }
}

#[derive(Clone, Copy)]
struct VisibleRegion {
    source_x: u16,
    source_y: u16,
    destination_x: u16,
    destination_y: u16,
    width: u16,
    height: u16,
}

fn visible_region(
    reference: &CompositionObject,
    object: &ObjectDefinition,
    window: Option<WindowDefinition>,
    canvas_width: u16,
    canvas_height: u16,
) -> Result<Option<VisibleRegion>, PgsError> {
    let (mut source_x, mut source_y, mut width, mut height) = if let Some(crop) = reference.crop {
        let crop_end_x = u32::from(crop.x) + u32::from(crop.width);
        let crop_end_y = u32::from(crop.y) + u32::from(crop.height);
        if crop.width == 0
            || crop.height == 0
            || crop_end_x > u32::from(object.width)
            || crop_end_y > u32::from(object.height)
        {
            return Err(malformed(
                PGS_SEGMENT_COMPOSITION,
                "object crop is out of bounds",
            ));
        }
        (crop.x, crop.y, crop.width, crop.height)
    } else {
        (0, 0, object.width, object.height)
    };
    let mut destination_x = reference.x;
    let mut destination_y = reference.y;

    if let Some(window) = window {
        clip_axis(
            &mut source_x,
            &mut destination_x,
            &mut width,
            window.x,
            window.width,
        );
        clip_axis(
            &mut source_y,
            &mut destination_y,
            &mut height,
            window.y,
            window.height,
        );
    }
    clip_axis(
        &mut source_x,
        &mut destination_x,
        &mut width,
        0,
        canvas_width,
    );
    clip_axis(
        &mut source_y,
        &mut destination_y,
        &mut height,
        0,
        canvas_height,
    );
    if width == 0 || height == 0 {
        return Ok(None);
    }
    Ok(Some(VisibleRegion {
        source_x,
        source_y,
        destination_x,
        destination_y,
        width,
        height,
    }))
}

fn clip_axis(
    source: &mut u16,
    destination: &mut u16,
    length: &mut u16,
    clip_start: u16,
    clip_length: u16,
) {
    let mut source_value = u32::from(*source);
    let mut destination_value = u32::from(*destination);
    let mut end = destination_value + u32::from(*length);
    let clip_start = u32::from(clip_start);
    let clip_end = clip_start + u32::from(clip_length);
    if destination_value < clip_start {
        let removed = (clip_start - destination_value).min(u32::from(*length));
        source_value += removed;
        destination_value += removed;
    }
    end = end.min(clip_end);
    let length_value = end.saturating_sub(destination_value);
    *source = source_value.min(u32::from(u16::MAX)) as u16;
    *destination = destination_value.min(u32::from(u16::MAX)) as u16;
    *length = length_value.min(u32::from(u16::MAX)) as u16;
}

/// Parses a complete `.sup` byte stream. PTS wrap-around is normalized into a
/// monotonic 64-bit 90 kHz timeline.
pub fn decode_pgs_sup(bytes: &[u8]) -> Result<Vec<PgsPresentation>, PgsError> {
    if bytes.len() > MAX_SUP_BYTES {
        return Err(PgsError::InputTooLarge {
            bytes: bytes.len(),
            limit: MAX_SUP_BYTES,
        });
    }
    let mut decoder = PgsDecoder::new();
    let mut unwrapper = PtsUnwrapper::default();
    let mut presentations = Vec::new();
    let mut offset = 0;
    while offset < bytes.len() {
        if bytes.len().saturating_sub(offset) < 13 {
            return Err(PgsError::TruncatedSegment { offset, needed: 13 });
        }
        if &bytes[offset..offset + 2] != b"PG" {
            return Err(PgsError::InvalidSupHeader { offset });
        }
        let pts = be_u32(bytes, offset + 2).expect("header length checked");
        let segment_type = bytes[offset + 10];
        let payload_length =
            usize::from(be_u16(bytes, offset + 11).expect("header length checked"));
        let payload_offset = offset + 13;
        let end = payload_offset
            .checked_add(payload_length)
            .ok_or(PgsError::TruncatedSegment {
                offset,
                needed: payload_length,
            })?;
        if end > bytes.len() {
            return Err(PgsError::TruncatedSegment {
                offset,
                needed: end - offset,
            });
        }
        let pts = unwrapper.unwrap(pts);
        if let Some(presentation) =
            decoder.push_segment(pts, segment_type, &bytes[payload_offset..end])?
        {
            if presentations.len() >= MAX_PRESENTATIONS {
                return Err(PgsError::LimitExceeded {
                    resource: "presentations",
                    limit: MAX_PRESENTATIONS,
                });
            }
            presentations.push(presentation);
        }
        offset = end;
    }
    Ok(presentations)
}

/// Decodes one PGS object into palette indices. The decoder validates every
/// run and line boundary before writing to the destination.
pub fn decode_pgs_rle_indices(
    width: u16,
    height: u16,
    encoded: &[u8],
) -> Result<Vec<u8>, PgsError> {
    let pixel_count = checked_pixel_count(width, height)?;
    let mut output = vec![0_u8; pixel_count];
    let width = usize::from(width);
    let height = usize::from(height);
    let mut input = 0;
    let mut x = 0;
    let mut y = 0;

    while y < height {
        let byte = *encoded
            .get(input)
            .ok_or(PgsError::RleMalformed("bitmap ended before all rows"))?;
        input += 1;
        if byte != 0 {
            write_run(&mut output, width, height, &mut x, y, 1, byte)?;
            continue;
        }
        let control = *encoded
            .get(input)
            .ok_or(PgsError::RleMalformed("escape code is truncated"))?;
        input += 1;
        if control == 0 {
            x = 0;
            y += 1;
            continue;
        }
        let mut run = usize::from(control & 0x3f);
        if control & 0x40 != 0 {
            let low = *encoded
                .get(input)
                .ok_or(PgsError::RleMalformed("long run is truncated"))?;
            input += 1;
            run = (run << 8) | usize::from(low);
        }
        if run == 0 {
            return Err(PgsError::RleMalformed("zero-length run"));
        }
        let color = if control & 0x80 != 0 {
            let color = *encoded
                .get(input)
                .ok_or(PgsError::RleMalformed("colored run is truncated"))?;
            input += 1;
            color
        } else {
            0
        };
        write_run(&mut output, width, height, &mut x, y, run, color)?;
    }
    if encoded[input..].iter().any(|byte| *byte != 0) {
        return Err(PgsError::RleMalformed("non-zero data follows final row"));
    }
    Ok(output)
}

fn write_run(
    output: &mut [u8],
    width: usize,
    height: usize,
    x: &mut usize,
    y: usize,
    run: usize,
    color: u8,
) -> Result<(), PgsError> {
    if y >= height || run > width.saturating_sub(*x) {
        return Err(PgsError::RleMalformed("run crosses a row boundary"));
    }
    let start = y
        .checked_mul(width)
        .and_then(|offset| offset.checked_add(*x))
        .ok_or(PgsError::RleMalformed("pixel offset overflow"))?;
    let end = start
        .checked_add(run)
        .ok_or(PgsError::RleMalformed("run offset overflow"))?;
    output
        .get_mut(start..end)
        .ok_or(PgsError::RleMalformed("run is out of bounds"))?
        .fill(color);
    *x += run;
    Ok(())
}

/// Converts the PGS `Y, Cr, Cb, Alpha` palette representation to full-range
/// RGB using integer BT.601 coefficients. Alpha remains straight/unmodified.
pub fn pgs_ycrcb_to_rgba(y: u8, cr: u8, cb: u8, alpha: u8) -> Rgba {
    let y = i32::from(y);
    let cr = i32::from(cr) - 128;
    let cb = i32::from(cb) - 128;
    let red = y + ((359 * cr + 128) >> 8);
    let green = y - ((88 * cb + 183 * cr + 128) >> 8);
    let blue = y + ((454 * cb + 128) >> 8);
    Rgba {
        red: clamp_u8(red),
        green: clamp_u8(green),
        blue: clamp_u8(blue),
        alpha,
    }
}

fn clamp_u8(value: i32) -> u8 {
    value.clamp(0, 255) as u8
}

fn checked_pixel_count(width: u16, height: u16) -> Result<usize, PgsError> {
    if width == 0 || height == 0 {
        return Err(PgsError::RleMalformed("bitmap has zero area"));
    }
    let pixels =
        usize::from(width)
            .checked_mul(usize::from(height))
            .ok_or(PgsError::LimitExceeded {
                resource: "object pixels",
                limit: MAX_OBJECT_PIXELS,
            })?;
    if pixels > MAX_OBJECT_PIXELS {
        return Err(PgsError::LimitExceeded {
            resource: "object pixels",
            limit: MAX_OBJECT_PIXELS,
        });
    }
    Ok(pixels)
}

fn checked_canvas(width: u16, height: u16) -> Result<(), PgsError> {
    if width == 0 || height == 0 {
        return Err(malformed(PGS_SEGMENT_COMPOSITION, "canvas has zero area"));
    }
    if usize::from(width) > MAX_CANVAS_DIMENSION || usize::from(height) > MAX_CANVAS_DIMENSION {
        return Err(PgsError::LimitExceeded {
            resource: "canvas dimension",
            limit: MAX_CANVAS_DIMENSION,
        });
    }
    Ok(())
}

fn malformed(segment_type: u8, reason: &'static str) -> PgsError {
    PgsError::MalformedSegment {
        segment_type,
        reason,
    }
}

fn be_u16(bytes: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_be_bytes([
        *bytes.get(offset)?,
        *bytes.get(offset + 1)?,
    ]))
}

fn be_u24(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(
        (u32::from(*bytes.get(offset)?) << 16)
            | (u32::from(*bytes.get(offset + 1)?) << 8)
            | u32::from(*bytes.get(offset + 2)?),
    )
}

fn be_u32(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_be_bytes([
        *bytes.get(offset)?,
        *bytes.get(offset + 1)?,
        *bytes.get(offset + 2)?,
        *bytes.get(offset + 3)?,
    ]))
}

#[derive(Default)]
struct PtsUnwrapper {
    epoch: u64,
    previous: Option<u32>,
}

impl PtsUnwrapper {
    fn unwrap(&mut self, value: u32) -> u64 {
        if let Some(previous) = self.previous
            && value < previous
            && previous.wrapping_sub(value) > (1_u32 << 31)
        {
            self.epoch = self.epoch.saturating_add(1_u64 << 32);
        }
        self.previous = Some(value);
        self.epoch + u64::from(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_literal_short_transparent_and_colored_runs() {
        let encoded = [1, 0, 0x82, 2, 3, 0, 0, 0, 4, 0, 0];
        let indices = decode_pgs_rle_indices(4, 2, &encoded).unwrap();
        assert_eq!(indices, [1, 2, 2, 3, 0, 0, 0, 0]);
    }

    #[test]
    fn decodes_long_colored_run() {
        let encoded = [0, 0xc1, 0x2c, 7, 0, 0];
        let indices = decode_pgs_rle_indices(300, 1, &encoded).unwrap();
        assert_eq!(indices.len(), 300);
        assert!(indices.iter().all(|index| *index == 7));
    }

    #[test]
    fn rejects_rle_crossing_row_or_missing_eol() {
        assert!(matches!(
            decode_pgs_rle_indices(3, 1, &[0, 4, 0, 0]),
            Err(PgsError::RleMalformed("run crosses a row boundary"))
        ));
        assert!(matches!(
            decode_pgs_rle_indices(1, 1, &[1]),
            Err(PgsError::RleMalformed("bitmap ended before all rows"))
        ));
    }

    #[test]
    fn assembles_sup_palette_object_window_and_composition() {
        let mut bytes = Vec::new();
        push_sup_segment(
            &mut bytes,
            90_000,
            PGS_SEGMENT_COMPOSITION,
            &pcs(4, 2, 1, 0x80, &[(7, 0, 0, 1, 1, None)]),
        );
        push_sup_segment(
            &mut bytes,
            90_000,
            PGS_SEGMENT_WINDOW,
            &[1, 0, 0, 0, 0, 0, 0, 4, 0, 2],
        );
        push_sup_segment(
            &mut bytes,
            90_000,
            PGS_SEGMENT_PALETTE,
            &[0, 0, 1, 76, 255, 85, 255],
        );
        push_sup_segment(
            &mut bytes,
            90_000,
            PGS_SEGMENT_OBJECT,
            &object_first(7, 0xc0, 2, 1, &[1, 1, 0, 0]),
        );
        push_sup_segment(&mut bytes, 90_000, PGS_SEGMENT_END, &[]);

        let presentations = decode_pgs_sup(&bytes).unwrap();
        assert_eq!(presentations.len(), 1);
        let presentation = &presentations[0];
        assert_eq!(presentation.pts_us, 1_000_000);
        assert_eq!(
            (presentation.canvas_width, presentation.canvas_height),
            (4, 2)
        );
        assert_eq!(presentation.parts.len(), 1);
        let part = &presentation.parts[0];
        assert_eq!((part.x, part.y, part.width, part.height), (1, 1, 2, 1));
        assert_eq!(part.rgba.len(), 8);
        assert_eq!(&part.rgba[..4], &[254, 0, 0, 255]);
    }

    #[test]
    fn assembles_fragmented_object_and_emits_clear_composition() {
        let mut decoder = PgsDecoder::new();
        decoder
            .push_segment(
                0,
                PGS_SEGMENT_COMPOSITION,
                &pcs(2, 1, 1, 0x80, &[(1, 0, 0, 0, 0, None)]),
            )
            .unwrap();
        decoder
            .push_segment(0, PGS_SEGMENT_PALETTE, &[0, 0, 1, 128, 128, 128, 255])
            .unwrap();
        let mut first_fragment = object_first(1, 0x80, 2, 1, &[1, 1, 0, 0]);
        first_fragment.truncate(12);
        decoder
            .push_segment(0, PGS_SEGMENT_OBJECT, &first_fragment)
            .unwrap();
        decoder
            .push_segment(0, PGS_SEGMENT_OBJECT, &[0, 1, 0, 0x40, 1, 0, 0])
            .unwrap();
        assert!(
            !decoder
                .push_segment(0, PGS_SEGMENT_END, &[])
                .unwrap()
                .unwrap()
                .is_clear()
        );

        decoder
            .push_segment(90_000, PGS_SEGMENT_COMPOSITION, &pcs(2, 1, 2, 0, &[]))
            .unwrap();
        assert!(
            decoder
                .push_segment(90_000, PGS_SEGMENT_END, &[])
                .unwrap()
                .unwrap()
                .is_clear()
        );
    }

    #[test]
    fn applies_source_crop_and_window_clipping() {
        let mut decoder = PgsDecoder::new();
        decoder
            .push_segment(
                0,
                PGS_SEGMENT_COMPOSITION,
                &pcs(4, 2, 1, 0x80, &[(1, 0, 0xc0, 0, 0, Some((1, 0, 2, 2)))]),
            )
            .unwrap();
        decoder
            .push_segment(0, PGS_SEGMENT_WINDOW, &[1, 0, 0, 1, 0, 0, 0, 1, 0, 2])
            .unwrap();
        decoder
            .push_segment(0, PGS_SEGMENT_PALETTE, &[0, 0, 2, 80, 128, 128, 255])
            .unwrap();
        decoder
            .push_segment(
                0,
                PGS_SEGMENT_OBJECT,
                &object_first(1, 0xc0, 4, 2, &[1, 2, 2, 1, 0, 0, 1, 2, 2, 1, 0, 0]),
            )
            .unwrap();
        let presentation = decoder
            .push_segment(0, PGS_SEGMENT_END, &[])
            .unwrap()
            .unwrap();
        let part = &presentation.parts[0];
        assert!(part.forced);
        assert_eq!((part.x, part.y, part.width, part.height), (1, 0, 1, 2));
        assert_eq!(part.rgba.len(), 8);
    }

    #[test]
    fn unwraps_32_bit_sup_pts() {
        let mut bytes = Vec::new();
        push_sup_segment(
            &mut bytes,
            u32::MAX - 10,
            PGS_SEGMENT_COMPOSITION,
            &pcs(1, 1, 1, 0x80, &[]),
        );
        push_sup_segment(&mut bytes, u32::MAX - 10, PGS_SEGMENT_END, &[]);
        push_sup_segment(
            &mut bytes,
            5,
            PGS_SEGMENT_COMPOSITION,
            &pcs(1, 1, 2, 0, &[]),
        );
        push_sup_segment(&mut bytes, 5, PGS_SEGMENT_END, &[]);
        let presentations = decode_pgs_sup(&bytes).unwrap();
        assert!(presentations[1].pts_90khz > presentations[0].pts_90khz);
    }

    #[test]
    fn rejects_truncated_sup_and_oversized_object_dimensions() {
        assert!(matches!(
            decode_pgs_sup(b"PG"),
            Err(PgsError::TruncatedSegment { .. })
        ));
        assert!(matches!(
            decode_pgs_rle_indices(u16::MAX, u16::MAX, &[]),
            Err(PgsError::LimitExceeded {
                resource: "object pixels",
                ..
            })
        ));
    }

    #[test]
    fn bounds_incomplete_and_cached_object_cardinality() {
        let mut incomplete = PgsDecoder::new();
        for id in 0..MAX_INCOMPLETE_OBJECTS {
            incomplete
                .push_segment(
                    0,
                    PGS_SEGMENT_OBJECT,
                    &object_first(id as u16, 0x80, 1, 1, &[1, 0, 0]),
                )
                .unwrap();
        }
        assert!(matches!(
            incomplete.push_segment(
                0,
                PGS_SEGMENT_OBJECT,
                &object_first(MAX_INCOMPLETE_OBJECTS as u16, 0x80, 1, 1, &[1, 0, 0]),
            ),
            Err(PgsError::LimitExceeded {
                resource: "incomplete objects",
                ..
            })
        ));

        let mut cached = PgsDecoder::new();
        for id in 0..MAX_CACHED_OBJECTS {
            cached
                .push_segment(
                    0,
                    PGS_SEGMENT_OBJECT,
                    &object_first(id as u16, 0xc0, 1, 1, &[1, 0, 0]),
                )
                .unwrap();
        }
        assert!(matches!(
            cached.push_segment(
                0,
                PGS_SEGMENT_OBJECT,
                &object_first(MAX_CACHED_OBJECTS as u16, 0xc0, 1, 1, &[1, 0, 0]),
            ),
            Err(PgsError::LimitExceeded {
                resource: "cached objects",
                ..
            })
        ));
    }

    fn push_sup_segment(output: &mut Vec<u8>, pts: u32, segment_type: u8, payload: &[u8]) {
        output.extend_from_slice(b"PG");
        output.extend_from_slice(&pts.to_be_bytes());
        output.extend_from_slice(&pts.to_be_bytes());
        output.push(segment_type);
        output.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        output.extend_from_slice(payload);
    }

    fn pcs(
        width: u16,
        height: u16,
        number: u16,
        state: u8,
        objects: &[(u16, u8, u8, u16, u16, Option<(u16, u16, u16, u16)>)],
    ) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&width.to_be_bytes());
        payload.extend_from_slice(&height.to_be_bytes());
        payload.push(0x10);
        payload.extend_from_slice(&number.to_be_bytes());
        payload.push(state);
        payload.push(0);
        payload.push(0);
        payload.push(objects.len() as u8);
        for &(id, window, flags, x, y, crop) in objects {
            payload.extend_from_slice(&id.to_be_bytes());
            payload.push(window);
            payload.push(flags);
            payload.extend_from_slice(&x.to_be_bytes());
            payload.extend_from_slice(&y.to_be_bytes());
            if let Some((crop_x, crop_y, crop_width, crop_height)) = crop {
                payload.extend_from_slice(&crop_x.to_be_bytes());
                payload.extend_from_slice(&crop_y.to_be_bytes());
                payload.extend_from_slice(&crop_width.to_be_bytes());
                payload.extend_from_slice(&crop_height.to_be_bytes());
            }
        }
        payload
    }

    fn object_first(id: u16, sequence: u8, width: u16, height: u16, rle: &[u8]) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&id.to_be_bytes());
        payload.push(0);
        payload.push(sequence);
        let length = (rle.len() + 4) as u32;
        payload.extend_from_slice(&length.to_be_bytes()[1..]);
        payload.extend_from_slice(&width.to_be_bytes());
        payload.extend_from_slice(&height.to_be_bytes());
        payload.extend_from_slice(rle);
        payload
    }
}
