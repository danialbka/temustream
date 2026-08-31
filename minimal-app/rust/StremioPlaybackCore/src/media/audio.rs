//! Small, clean-room parsers for compressed-audio framing metadata.
//!
//! Apple still performs codec decompression. Bunny only reads the Dolby sync
//! frame fields needed to describe the decoded speaker order accurately.

use super::Codec;

pub(crate) const DOLBY_CHANNEL_CONFIGURATION_VALID: u32 = 1 << 8;
pub(crate) const DOLBY_CHANNEL_CONFIGURATION_LFE: u32 = 1 << 3;
pub(crate) const MAX_AAC_AUDIO_SPECIFIC_CONFIG_BYTES: usize = 512;

pub(crate) fn dolby_channel_configuration(codec: Codec, packet: &[u8]) -> Option<u32> {
    let info = dolby_frame_info(codec, packet)?;
    Some(
        DOLBY_CHANNEL_CONFIGURATION_VALID
            | u32::from(info.audio_coding_mode)
            | if info.has_lfe {
                DOLBY_CHANNEL_CONFIGURATION_LFE
            } else {
                0
            },
    )
}

pub(crate) fn dolby_sample_frames(codec: Codec, packet: &[u8]) -> Option<u32> {
    dolby_frame_info(codec, packet).map(|info| info.sample_frames)
}

/// Returns the decoded sample-frame count carried by one compressed packet.
///
/// Matroska permits laced audio blocks without `BlockDuration` or
/// `DefaultDuration`. In that case each lace still needs its own timestamp.
/// These small framing parsers recover timing only; Apple remains responsible
/// for decoding the compressed payload.
pub(crate) fn compressed_audio_sample_frames(
    codec: Codec,
    packet: &[u8],
    aac_frames_per_access_unit: u32,
) -> Option<u32> {
    match codec {
        Codec::Aac => aac_sample_frames(packet, aac_frames_per_access_unit),
        Codec::Opus => opus_sample_frames(packet),
        Codec::Flac => flac_sample_frames(packet),
        Codec::Ac3 | Codec::Eac3 => dolby_sample_frames(codec, packet),
        _ => None,
    }
}

/// Returns the decoded output frames represented by one raw AAC access unit.
///
/// Matroska stores AAC's AudioSpecificConfig in `CodecPrivate`. The
/// `frameLengthFlag` changes ordinary AAC from 1024 to 960 samples and AAC-LD
/// or AAC-ELD from 512 to 480. HE-AAC/HE-AACv2 double the decoded output frame
/// count, including when SBR/PS is declared through a sync extension rather
/// than as the leading audio object type.
pub(crate) fn aac_frames_per_access_unit(codec_private: &[u8]) -> Option<u32> {
    if codec_private.len() > MAX_AAC_AUDIO_SPECIFIC_CONFIG_BYTES {
        return None;
    }
    let mut bits = BitReader::new(codec_private);
    let mut audio_object_type = read_aac_audio_object_type(&mut bits)?;
    skip_aac_sampling_frequency(&mut bits)?;
    let _channel_configuration = bits.read(4)?;

    let mut has_sbr_or_ps = matches!(audio_object_type, 5 | 29);
    if has_sbr_or_ps {
        skip_aac_sampling_frequency(&mut bits)?;
        audio_object_type = read_aac_audio_object_type(&mut bits)?;
        if audio_object_type == 22 {
            bits.skip(4)?; // extensionChannelConfiguration
        }
    }

    let frame_length_flag = bits.read(1)? != 0;
    let core_frames: u32 = match audio_object_type {
        // AAC Main, LC, SSR, LTP, scalable and ER general-audio profiles.
        1..=4 | 6 | 7 | 17 | 19..=23 => {
            if matches!(audio_object_type, 23) {
                if frame_length_flag { 480 } else { 512 }
            } else if frame_length_flag {
                960
            } else {
                1_024
            }
        }
        // ER AAC ELD.
        39 => {
            if frame_length_flag {
                480
            } else {
                512
            }
        }
        _ => return None,
    };

    if !has_sbr_or_ps {
        has_sbr_or_ps = aac_sync_extension_enables_sbr(codec_private, bits.bit_offset);
    }
    core_frames.checked_mul(if has_sbr_or_ps { 2 } else { 1 })
}

fn aac_sample_frames(packet: &[u8], configured_frames: u32) -> Option<u32> {
    if packet.is_empty() {
        return None;
    }
    let configured_frames = if configured_frames == 0 {
        1_024
    } else {
        configured_frames
    };
    // Matroska A_AAC packets normally contain one raw AAC access unit. When
    // an ADTS header is present, its final two bits declare any additional
    // raw-data blocks carried by the frame.
    if packet.len() >= 7 && packet[0] == 0xff && packet[1] & 0xf6 == 0xf0 {
        return configured_frames.checked_mul(u32::from(packet[6] & 0x03) + 1);
    }
    Some(configured_frames)
}

fn read_aac_audio_object_type(bits: &mut BitReader<'_>) -> Option<u32> {
    let value = bits.read(5)?;
    if value == 31 {
        bits.read(6)?.checked_add(32)
    } else {
        Some(value)
    }
}

fn skip_aac_sampling_frequency(bits: &mut BitReader<'_>) -> Option<()> {
    let index = bits.read(4)?;
    if index == 15 {
        bits.skip(24)?;
    } else if index >= 13 {
        return None;
    }
    Some(())
}

fn aac_sync_extension_enables_sbr(bytes: &[u8], start_bit: usize) -> bool {
    let bit_count = bytes.len().saturating_mul(8);
    for offset in start_bit..=bit_count.saturating_sub(17) {
        let Some(sync_type) = read_bits_at(bytes, offset, 11) else {
            continue;
        };
        if sync_type != 0x2b7
            || read_bits_at(bytes, offset + 11, 5) != Some(5)
            || read_bits_at(bytes, offset + 16, 1) != Some(1)
        {
            continue;
        }
        let Some(frequency_index) = read_bits_at(bytes, offset + 17, 4) else {
            continue;
        };
        if frequency_index <= 12
            || (frequency_index == 15 && read_bits_at(bytes, offset + 21, 24).is_some())
        {
            return true;
        }
    }
    false
}

fn read_bits_at(bytes: &[u8], offset: usize, count: usize) -> Option<u32> {
    if count > u32::BITS as usize || offset.checked_add(count)? > bytes.len().checked_mul(8)? {
        return None;
    }
    let mut value = 0_u32;
    for bit_index in offset..offset + count {
        let byte = *bytes.get(bit_index / 8)?;
        let shift = 7 - (bit_index % 8);
        value = (value << 1) | u32::from((byte >> shift) & 1);
    }
    Some(value)
}

fn opus_sample_frames(packet: &[u8]) -> Option<u32> {
    let toc = *packet.first()?;
    let configuration = toc >> 3;
    let frames_per_packet = match toc & 0x03 {
        0 => 1,
        1 | 2 => 2,
        3 => {
            let count = u32::from(*packet.get(1)? & 0x3f);
            if !(1..=48).contains(&count) {
                return None;
            }
            count
        }
        _ => unreachable!(),
    };
    let samples_per_frame = match configuration {
        0..=11 => [480_u32, 960, 1_920, 2_880][usize::from(configuration & 0x03)],
        12..=15 => [480_u32, 960][usize::from(configuration & 0x01)],
        16..=31 => [120_u32, 240, 480, 960][usize::from(configuration & 0x03)],
        _ => return None,
    };
    let total = samples_per_frame.checked_mul(frames_per_packet)?;
    // RFC 6716 limits a packet to 120 ms at the fixed 48 kHz Opus clock.
    (total <= 5_760).then_some(total)
}

fn flac_sample_frames(packet: &[u8]) -> Option<u32> {
    if packet.len() < 5 || packet[0] != 0xff || packet[1] & 0xfe != 0xf8 {
        return None;
    }
    let block_size_code = packet[2] >> 4;
    let utf8_length = utf8_integer_length(*packet.get(4)?)?;
    let extra_offset = 4_usize.checked_add(utf8_length)?;
    match block_size_code {
        0 => None,
        1 => Some(192),
        2..=5 => 576_u32.checked_shl(u32::from(block_size_code - 2)),
        6 => Some(u32::from(*packet.get(extra_offset)?) + 1),
        7 => {
            let high = u32::from(*packet.get(extra_offset)?);
            let low = u32::from(*packet.get(extra_offset + 1)?);
            Some((high << 8 | low) + 1)
        }
        8..=15 => 256_u32.checked_shl(u32::from(block_size_code - 8)),
        _ => None,
    }
}

fn utf8_integer_length(first: u8) -> Option<usize> {
    match first {
        0x00..=0x7f => Some(1),
        0xc0..=0xdf => Some(2),
        0xe0..=0xef => Some(3),
        0xf0..=0xf7 => Some(4),
        0xf8..=0xfb => Some(5),
        0xfc..=0xfd => Some(6),
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DolbyFrameInfo {
    audio_coding_mode: u8,
    has_lfe: bool,
    sample_frames: u32,
}

fn dolby_frame_info(codec: Codec, packet: &[u8]) -> Option<DolbyFrameInfo> {
    match codec {
        Codec::Ac3 => parse_ac3_frame_info(packet),
        Codec::Eac3 => parse_eac3_frame_info(packet),
        _ => None,
    }
}

fn parse_eac3_frame_info(packet: &[u8]) -> Option<DolbyFrameInfo> {
    let mut bits = BitReader::new(packet);
    if bits.read(16)? != 0x0b77 {
        return None;
    }
    bits.skip(2 + 3 + 11)?; // strmtyp, substreamid, frmsiz
    let sample_rate_code = bits.read(2)?;
    let audio_blocks = if sample_rate_code == 3 {
        bits.skip(2)?; // fscod2; six blocks are implicit
        6
    } else {
        // ATSC A/52 Annex E: 00, 01, 10, 11 represent 1, 2, 3,
        // and 6 blocks. Each block carries 256 decoded sample frames.
        [1_u32, 2, 3, 6][usize::try_from(bits.read(2)?).ok()?]
    };
    let audio_coding_mode = u8::try_from(bits.read(3)?).ok()?;
    let has_lfe = bits.read(1)? != 0;
    Some(DolbyFrameInfo {
        audio_coding_mode,
        has_lfe,
        sample_frames: audio_blocks * 256,
    })
}

fn parse_ac3_frame_info(packet: &[u8]) -> Option<DolbyFrameInfo> {
    let mut bits = BitReader::new(packet);
    if bits.read(16)? != 0x0b77 {
        return None;
    }
    bits.skip(16 + 2 + 6 + 5 + 3)?; // crc1, fscod, frmsizecod, bsid, bsmod
    let audio_coding_mode = u8::try_from(bits.read(3)?).ok()?;
    if audio_coding_mode & 0x1 != 0 && audio_coding_mode != 0x1 {
        bits.skip(2)?; // cmixlev
    }
    if audio_coding_mode & 0x4 != 0 {
        bits.skip(2)?; // surmixlev
    }
    if audio_coding_mode == 0x2 {
        bits.skip(2)?; // dsurmod
    }
    let has_lfe = bits.read(1)? != 0;
    Some(DolbyFrameInfo {
        audio_coding_mode,
        has_lfe,
        sample_frames: 1_536,
    })
}

struct BitReader<'a> {
    bytes: &'a [u8],
    bit_offset: usize,
}

impl<'a> BitReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self {
            bytes,
            bit_offset: 0,
        }
    }

    fn read(&mut self, count: usize) -> Option<u32> {
        if count > u32::BITS as usize
            || self
                .bit_offset
                .checked_add(count)?
                .gt(&self.bytes.len().checked_mul(8)?)
        {
            return None;
        }
        let mut value = 0_u32;
        for _ in 0..count {
            let byte = *self.bytes.get(self.bit_offset / 8)?;
            let shift = 7 - (self.bit_offset % 8);
            value = (value << 1) | u32::from((byte >> shift) & 1);
            self.bit_offset += 1;
        }
        Some(value)
    }

    fn skip(&mut self, count: usize) -> Option<()> {
        self.read(count).map(|_| ())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ffmpeg_eac3_five_point_one_header() {
        let packet = [
            0x0b, 0x77, 0x05, 0xff, 0x3f, 0x87, 0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x00,
            0x00, 0x00,
        ];
        assert_eq!(
            dolby_channel_configuration(Codec::Eac3, &packet),
            Some(DOLBY_CHANNEL_CONFIGURATION_VALID | DOLBY_CHANNEL_CONFIGURATION_LFE | 0x7)
        );
        assert_eq!(dolby_sample_frames(Codec::Eac3, &packet), Some(1_536));
    }

    #[test]
    fn parses_ffmpeg_ac3_five_point_one_header() {
        let packet = [
            0x0b, 0x77, 0xbe, 0xaa, 0x24, 0x40, 0xeb, 0xf8, 0x40, 0x3e, 0x95, 0x5e, 0x18, 0x61,
            0x86, 0x1f,
        ];
        assert_eq!(
            dolby_channel_configuration(Codec::Ac3, &packet),
            Some(DOLBY_CHANNEL_CONFIGURATION_VALID | DOLBY_CHANNEL_CONFIGURATION_LFE | 0x7)
        );
        assert_eq!(dolby_sample_frames(Codec::Ac3, &packet), Some(1_536));
    }

    #[test]
    fn parses_each_eac3_variable_frame_duration() {
        for (code, expected_frames) in [(0_u8, 256), (1, 512), (2, 768), (3, 1_536)] {
            // After the sync word and 16 bits of stream/frame size fields,
            // byte four holds fscod=00, numblkscod, acmod=111, and lfeon=1.
            let packet = [0x0b, 0x77, 0x00, 0x00, (code << 4) | 0x0f];
            assert_eq!(
                dolby_sample_frames(Codec::Eac3, &packet),
                Some(expected_frames)
            );
            assert_eq!(
                dolby_channel_configuration(Codec::Eac3, &packet),
                Some(DOLBY_CHANNEL_CONFIGURATION_VALID | DOLBY_CHANNEL_CONFIGURATION_LFE | 0x7)
            );
        }
    }

    #[test]
    fn rejects_truncated_and_non_dolby_packets() {
        assert_eq!(dolby_channel_configuration(Codec::Eac3, &[0x0b]), None);
        assert_eq!(
            dolby_channel_configuration(Codec::Ac3, &[0x00, 0x00, 0x00, 0x00]),
            None
        );
        assert_eq!(dolby_channel_configuration(Codec::Aac, &[0x0b, 0x77]), None);
    }

    #[test]
    fn derives_aac_access_unit_sample_frames() {
        assert_eq!(
            compressed_audio_sample_frames(Codec::Aac, &[0x12], 1_024),
            Some(1_024)
        );
        assert_eq!(
            compressed_audio_sample_frames(
                Codec::Aac,
                &[0xff, 0xf1, 0x50, 0x80, 0x00, 0x1f, 0x02],
                1_024,
            ),
            Some(3_072)
        );
        assert_eq!(compressed_audio_sample_frames(Codec::Aac, &[], 1_024), None);
    }

    #[test]
    fn derives_opus_packet_sample_frames_and_rejects_oversized_packets() {
        assert_eq!(
            compressed_audio_sample_frames(Codec::Opus, &[0x80], 0),
            Some(120)
        );
        assert_eq!(
            compressed_audio_sample_frames(Codec::Opus, &[0x98], 0),
            Some(960)
        );
        assert_eq!(
            compressed_audio_sample_frames(Codec::Opus, &[0x83, 0x30], 0),
            Some(5_760)
        );
        assert_eq!(
            compressed_audio_sample_frames(Codec::Opus, &[0x83, 0x31], 0),
            None
        );
    }

    #[test]
    fn derives_flac_block_sizes_from_fixed_and_explicit_headers() {
        assert_eq!(
            compressed_audio_sample_frames(Codec::Flac, &[0xff, 0xf8, 0x80, 0x00, 0x00], 0,),
            Some(256)
        );
        assert_eq!(
            compressed_audio_sample_frames(
                Codec::Flac,
                &[0xff, 0xf8, 0x70, 0x00, 0x00, 0x03, 0xff],
                0,
            ),
            Some(1_024)
        );
        assert_eq!(
            compressed_audio_sample_frames(Codec::Flac, &[0xff], 0),
            None
        );
    }

    #[test]
    fn derives_aac_asc_frame_lengths_and_sbr_output_multiplier() {
        // AAC-LC, 44.1 kHz, stereo, frameLengthFlag=0/1.
        assert_eq!(aac_frames_per_access_unit(&[0x12, 0x10]), Some(1_024));
        assert_eq!(aac_frames_per_access_unit(&[0x12, 0x14]), Some(960));

        // AAC-LD and AAC-ELD use 512/480 core samples.
        assert_eq!(aac_frames_per_access_unit(&[0xba, 0x10, 0x00]), Some(512));
        assert_eq!(aac_frames_per_access_unit(&[0xba, 0x14, 0x00]), Some(480));
        assert_eq!(
            aac_frames_per_access_unit(&[0xf8, 0xe8, 0x40, 0x00]),
            Some(512)
        );

        // Explicit HE-AAC (AOT 5 wrapping AAC-LC) doubles decoded output.
        assert_eq!(
            aac_frames_per_access_unit(&[0x2a, 0x11, 0x88, 0x00]),
            Some(2_048)
        );

        // AAC-LC followed by syncExtensionType 0x2b7/AOT 5/SBR-present.
        assert_eq!(
            aac_frames_per_access_unit(&[0x12, 0x10, 0x56, 0xe5, 0x80]),
            Some(2_048)
        );
        // A standalone Parametric Stereo marker does not establish SBR. PS is
        // only valid after a complete 0x2b7/AOT5/SBR extension chain.
        assert_eq!(
            aac_frames_per_access_unit(&[0x12, 0x10, 0xa9, 0x10, 0x00]),
            Some(1_024)
        );
        // A fully nested PS marker remains HE-AAC output, without multiplying
        // the already doubled SBR frame count a second time.
        assert_eq!(
            aac_frames_per_access_unit(&[0x12, 0x10, 0x56, 0xe5, 0xa5, 0x48, 0x80]),
            Some(2_048)
        );

        let mut oversized = vec![0_u8; MAX_AAC_AUDIO_SPECIFIC_CONFIG_BYTES + 1];
        oversized[..2].copy_from_slice(&[0x12, 0x10]);
        assert_eq!(aac_frames_per_access_unit(&oversized), None);
    }
}
