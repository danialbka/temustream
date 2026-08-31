//! Dependency-free text subtitle parsing and normalization.
//!
//! The parser deliberately returns presentation text rather than retaining
//! format-specific markup. Rendering and styling belong to the Apple-facing
//! layer; this module owns bounded parsing, timestamps, and cue ordering.

use std::{error::Error, fmt};

const MAX_DOCUMENT_BYTES: usize = 16 * 1024 * 1024;
const MAX_CUES: usize = 200_000;
const MAX_CUE_TEXT_BYTES: usize = 256 * 1024;
const MICROS_PER_SECOND: u64 = 1_000_000;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum SubtitleFormat {
    #[default]
    Auto,
    Srt,
    WebVtt,
    Ass,
    Ssa,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubtitleCue {
    pub identifier: Option<String>,
    pub start_us: u64,
    pub end_us: u64,
    pub text: String,
    /// Format-specific positioning/settings retained for a future renderer.
    /// SRT leaves this empty, WebVTT stores cue settings, and ASS/SSA stores
    /// the style name.
    pub settings: Option<String>,
}

impl SubtitleCue {
    pub fn duration_us(&self) -> u64 {
        self.end_us.saturating_sub(self.start_us)
    }

    pub fn is_active_at(&self, time_us: u64) -> bool {
        self.start_us <= time_us && time_us < self.end_us
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SubtitleError {
    DocumentTooLarge { bytes: usize, limit: usize },
    TooManyCues { limit: usize },
    CueTextTooLarge { bytes: usize, limit: usize },
    InvalidUtf8,
}

impl fmt::Display for SubtitleError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DocumentTooLarge { bytes, limit } => {
                write!(
                    formatter,
                    "subtitle document is {bytes} bytes; limit is {limit}"
                )
            }
            Self::TooManyCues { limit } => {
                write!(formatter, "subtitle document exceeds {limit} cues")
            }
            Self::CueTextTooLarge { bytes, limit } => {
                write!(formatter, "subtitle cue is {bytes} bytes; limit is {limit}")
            }
            Self::InvalidUtf8 => formatter.write_str("subtitle document is not valid UTF-8"),
        }
    }
}

impl Error for SubtitleError {}

pub fn parse_subtitle_bytes(
    bytes: &[u8],
    format: SubtitleFormat,
) -> Result<Vec<SubtitleCue>, SubtitleError> {
    if bytes.len() > MAX_DOCUMENT_BYTES {
        return Err(SubtitleError::DocumentTooLarge {
            bytes: bytes.len(),
            limit: MAX_DOCUMENT_BYTES,
        });
    }
    let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(bytes);
    let document = std::str::from_utf8(bytes).map_err(|_| SubtitleError::InvalidUtf8)?;
    parse_subtitle_document(document, format)
}

pub fn parse_subtitle_document(
    document: &str,
    format: SubtitleFormat,
) -> Result<Vec<SubtitleCue>, SubtitleError> {
    if document.len() > MAX_DOCUMENT_BYTES {
        return Err(SubtitleError::DocumentTooLarge {
            bytes: document.len(),
            limit: MAX_DOCUMENT_BYTES,
        });
    }
    let document = document.strip_prefix('\u{feff}').unwrap_or(document);
    let format = match format {
        SubtitleFormat::Auto => detect_format(document),
        explicit => explicit,
    };
    let mut cues = match format {
        SubtitleFormat::Auto | SubtitleFormat::Srt => parse_srt(document)?,
        SubtitleFormat::WebVtt => parse_webvtt(document)?,
        SubtitleFormat::Ass => parse_ass_like(document, false)?,
        SubtitleFormat::Ssa => parse_ass_like(document, true)?,
    };
    // Stable ordering makes seeking deterministic while retaining source order
    // for simultaneous dialogue.
    cues.sort_by_key(|cue| (cue.start_us, cue.end_us));
    Ok(cues)
}

fn detect_format(document: &str) -> SubtitleFormat {
    let head = document.trim_start_matches(['\u{feff}', ' ', '\t', '\r', '\n']);
    if head
        .get(..6)
        .is_some_and(|value| value.eq_ignore_ascii_case("WEBVTT"))
    {
        return SubtitleFormat::WebVtt;
    }
    let mut has_events = false;
    let mut has_dialogue = false;
    let mut ssa = false;
    for line in head.lines().take(256) {
        let line = line.trim();
        has_events |= line.eq_ignore_ascii_case("[events]");
        has_dialogue |= line
            .get(..9)
            .is_some_and(|prefix| prefix.eq_ignore_ascii_case("dialogue:"));
        if let Some((key, value)) = line.split_once(':')
            && key.trim().eq_ignore_ascii_case("scripttype")
        {
            ssa |= value.trim().eq_ignore_ascii_case("v4.00");
        }
    }
    if has_events || has_dialogue {
        if ssa {
            SubtitleFormat::Ssa
        } else {
            SubtitleFormat::Ass
        }
    } else {
        SubtitleFormat::Srt
    }
}

fn parse_srt(document: &str) -> Result<Vec<SubtitleCue>, SubtitleError> {
    let lines = normalized_lines(document);
    let mut cues = Vec::new();
    let mut index = 0;
    while index < lines.len() {
        while index < lines.len() && lines[index].trim().is_empty() {
            index += 1;
        }
        if index >= lines.len() {
            break;
        }

        let mut identifier = None;
        let mut timing_index = index;
        if !lines[timing_index].contains("-->") {
            identifier = nonempty_owned(lines[timing_index].trim());
            timing_index += 1;
        }
        let Some(timing_line) = lines.get(timing_index) else {
            break;
        };
        let Some((start_us, end_us, _)) = parse_timing_line(timing_line, false) else {
            index = skip_to_blank(&lines, index + 1);
            continue;
        };

        index = timing_index + 1;
        let text_start = index;
        index = skip_to_blank(&lines, index);
        let raw_text = lines[text_start..index].join("\n");
        let text = normalize_markup_text(&raw_text);
        push_cue(
            &mut cues,
            SubtitleCue {
                identifier,
                start_us,
                end_us,
                text,
                settings: None,
            },
        )?;
    }
    Ok(cues)
}

fn parse_webvtt(document: &str) -> Result<Vec<SubtitleCue>, SubtitleError> {
    let lines = normalized_lines(document);
    let mut cues = Vec::new();
    let mut index = 0;

    while index < lines.len() && lines[index].trim().is_empty() {
        index += 1;
    }
    if lines.get(index).is_some_and(|line| {
        line.trim_start()
            .get(..6)
            .is_some_and(|value| value.eq_ignore_ascii_case("WEBVTT"))
    }) {
        index += 1;
        // Header metadata ends at the first empty line.
        index = skip_to_blank(&lines, index);
    }

    while index < lines.len() {
        while index < lines.len() && lines[index].trim().is_empty() {
            index += 1;
        }
        if index >= lines.len() {
            break;
        }
        let trimmed = lines[index].trim();
        if starts_ascii_word(trimmed, "NOTE")
            || trimmed.eq_ignore_ascii_case("STYLE")
            || trimmed.eq_ignore_ascii_case("REGION")
        {
            index = skip_to_blank(&lines, index + 1);
            continue;
        }

        let mut identifier = None;
        let mut timing_index = index;
        if !lines[timing_index].contains("-->") {
            identifier = nonempty_owned(lines[timing_index].trim());
            timing_index += 1;
        }
        let Some(timing_line) = lines.get(timing_index) else {
            break;
        };
        let Some((start_us, end_us, settings)) = parse_timing_line(timing_line, true) else {
            index = skip_to_blank(&lines, index + 1);
            continue;
        };
        index = timing_index + 1;
        let text_start = index;
        index = skip_to_blank(&lines, index);
        let raw_text = lines[text_start..index].join("\n");
        let text = normalize_markup_text(&raw_text);
        push_cue(
            &mut cues,
            SubtitleCue {
                identifier,
                start_us,
                end_us,
                text,
                settings: nonempty_owned(settings.trim()),
            },
        )?;
    }
    Ok(cues)
}

fn parse_ass_like(document: &str, mut ssa: bool) -> Result<Vec<SubtitleCue>, SubtitleError> {
    let mut cues = Vec::new();
    let mut in_events = false;
    let mut fields: Vec<String> = Vec::new();

    for source_line in document.lines() {
        let line = source_line.trim_end_matches('\r').trim();
        if line.starts_with('[') && line.ends_with(']') {
            in_events = line.eq_ignore_ascii_case("[events]");
            continue;
        }
        if let Some((key, value)) = line.split_once(':')
            && key.trim().eq_ignore_ascii_case("scripttype")
        {
            ssa = value.trim().eq_ignore_ascii_case("v4.00");
        }
        if !in_events
            && !line.get(..9).is_some_and(|prefix| {
                prefix.eq_ignore_ascii_case("dialogue:") || prefix.eq_ignore_ascii_case("comment: ")
            })
        {
            continue;
        }

        if let Some((key, value)) = line.split_once(':')
            && key.trim().eq_ignore_ascii_case("format")
        {
            fields = value
                .split(',')
                .map(|field| field.trim().to_ascii_lowercase())
                .collect();
            continue;
        }
        let Some((kind, payload)) = line.split_once(':') else {
            continue;
        };
        if !kind.trim().eq_ignore_ascii_case("dialogue") {
            continue;
        }

        if fields.is_empty() {
            fields = if ssa {
                [
                    "marked", "start", "end", "style", "name", "marginl", "marginr", "marginv",
                    "effect", "text",
                ]
                .into_iter()
                .map(str::to_owned)
                .collect()
            } else {
                [
                    "layer", "start", "end", "style", "name", "marginl", "marginr", "marginv",
                    "effect", "text",
                ]
                .into_iter()
                .map(str::to_owned)
                .collect()
            };
        }

        let values: Vec<&str> = payload.splitn(fields.len(), ',').collect();
        if values.len() != fields.len() {
            continue;
        }
        let Some(start_index) = fields.iter().position(|field| field == "start") else {
            continue;
        };
        let Some(end_index) = fields.iter().position(|field| field == "end") else {
            continue;
        };
        let Some(text_index) = fields.iter().position(|field| field == "text") else {
            continue;
        };
        let Some(start_us) = parse_timestamp(values[start_index].trim(), false) else {
            continue;
        };
        let Some(end_us) = parse_timestamp(values[end_index].trim(), false) else {
            continue;
        };
        if end_us <= start_us {
            continue;
        }
        let text = normalize_ass_text(values[text_index]);
        let settings = fields
            .iter()
            .position(|field| field == "style")
            .and_then(|style_index| nonempty_owned(values[style_index].trim()));
        push_cue(
            &mut cues,
            SubtitleCue {
                identifier: None,
                start_us,
                end_us,
                text,
                settings,
            },
        )?;
    }
    Ok(cues)
}

fn parse_timing_line(line: &str, allow_short: bool) -> Option<(u64, u64, &str)> {
    let (start, remainder) = line.split_once("-->")?;
    let remainder = remainder.trim();
    let end_length = remainder
        .find(char::is_whitespace)
        .unwrap_or(remainder.len());
    let end = &remainder[..end_length];
    let settings = remainder[end_length..].trim();
    let start_us = parse_timestamp(start.trim(), allow_short)?;
    let end_us = parse_timestamp(end.trim(), allow_short)?;
    (end_us > start_us).then_some((start_us, end_us, settings))
}

fn parse_timestamp(value: &str, allow_short: bool) -> Option<u64> {
    let mut components = value.split(':');
    let first = components.next()?;
    let second = components.next()?;
    let third = components.next();
    if components.next().is_some() {
        return None;
    }
    let (hours, minutes, seconds) = match third {
        Some(third) => (parse_digits(first)?, parse_digits(second)?, third),
        None if allow_short => (0, parse_digits(first)?, second),
        None => return None,
    };
    if minutes >= 60 {
        return None;
    }
    let (seconds, fraction) = split_seconds(seconds)?;
    if seconds >= 60 {
        return None;
    }
    let whole_seconds = hours
        .checked_mul(3_600)?
        .checked_add(minutes.checked_mul(60)?)?
        .checked_add(seconds)?;
    whole_seconds
        .checked_mul(MICROS_PER_SECOND)?
        .checked_add(fraction_to_micros(fraction)?)
}

fn split_seconds(value: &str) -> Option<(u64, &str)> {
    let separator = value
        .char_indices()
        .find_map(|(index, character)| matches!(character, '.' | ',').then_some(index));
    match separator {
        Some(index) => {
            let whole = parse_digits(&value[..index])?;
            let fraction = &value[index + 1..];
            (!fraction.is_empty() && fraction.bytes().all(|byte| byte.is_ascii_digit()))
                .then_some((whole, fraction))
        }
        None => Some((parse_digits(value)?, "")),
    }
}

fn parse_digits(value: &str) -> Option<u64> {
    (!value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()))
        .then(|| value.parse().ok())?
}

fn fraction_to_micros(fraction: &str) -> Option<u64> {
    if fraction.is_empty() {
        return Some(0);
    }
    let mut value = 0_u64;
    let mut digits = 0_u32;
    for byte in fraction.bytes().take(6) {
        value = value.checked_mul(10)?.checked_add(u64::from(byte - b'0'))?;
        digits += 1;
    }
    value.checked_mul(10_u64.pow(6 - digits))
}

fn normalized_lines(document: &str) -> Vec<&str> {
    document
        .lines()
        .map(|line| line.trim_end_matches('\r'))
        .collect()
}

fn skip_to_blank(lines: &[&str], mut index: usize) -> usize {
    while index < lines.len() && !lines[index].trim().is_empty() {
        index += 1;
    }
    index
}

fn push_cue(cues: &mut Vec<SubtitleCue>, cue: SubtitleCue) -> Result<(), SubtitleError> {
    if cue.text.is_empty() {
        return Ok(());
    }
    if cue.text.len() > MAX_CUE_TEXT_BYTES {
        return Err(SubtitleError::CueTextTooLarge {
            bytes: cue.text.len(),
            limit: MAX_CUE_TEXT_BYTES,
        });
    }
    if cues.len() >= MAX_CUES {
        return Err(SubtitleError::TooManyCues { limit: MAX_CUES });
    }
    cues.push(cue);
    Ok(())
}

fn nonempty_owned(value: &str) -> Option<String> {
    (!value.is_empty()).then(|| value.to_owned())
}

fn starts_ascii_word(value: &str, word: &str) -> bool {
    value.get(..word.len()).is_some_and(|prefix| {
        prefix.eq_ignore_ascii_case(word)
            && value[word.len()..]
                .chars()
                .next()
                .is_none_or(char::is_whitespace)
    })
}

fn normalize_markup_text(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '<' {
            let mut tag = String::new();
            let mut closed = false;
            for next in characters.by_ref() {
                if next == '>' {
                    closed = true;
                    break;
                }
                if tag.len() < 128 {
                    tag.push(next);
                }
            }
            if closed {
                let tag_name = tag
                    .trim_start_matches('/')
                    .split_ascii_whitespace()
                    .next()
                    .unwrap_or("");
                if tag_name.eq_ignore_ascii_case("br") || tag_name.eq_ignore_ascii_case("br/") {
                    output.push('\n');
                }
                continue;
            }
            output.push('<');
            output.push_str(&tag);
            break;
        }
        output.push(character);
    }
    normalize_lines_and_entities(&output)
}

fn normalize_ass_text(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let characters: Vec<char> = text.chars().collect();
    let mut index = 0;
    let mut drawing_mode = 0_u32;
    while index < characters.len() {
        if characters[index] == '{'
            && let Some(close_offset) = characters[index + 1..]
                .iter()
                .position(|character| *character == '}')
        {
            let close = index + 1 + close_offset;
            update_ass_drawing_mode(&characters[index + 1..close], &mut drawing_mode);
            index = close + 1;
            continue;
        }
        if characters[index] == '\\' && index + 1 < characters.len() {
            let escaped = characters[index + 1];
            if drawing_mode == 0 {
                match escaped {
                    'N' | 'n' => output.push('\n'),
                    'h' => output.push(' '),
                    '\\' | '{' | '}' => output.push(escaped),
                    _ => {
                        output.push('\\');
                        output.push(escaped);
                    }
                }
            }
            index += 2;
            continue;
        }
        if drawing_mode == 0 {
            output.push(characters[index]);
        }
        index += 1;
    }
    normalize_markup_text(&output)
}

fn update_ass_drawing_mode(tag: &[char], drawing_mode: &mut u32) {
    let mut index = 0;
    while index + 1 < tag.len() {
        if tag[index] == '\\' && matches!(tag[index + 1], 'p' | 'P') {
            index += 2;
            while index < tag.len() && tag[index].is_whitespace() {
                index += 1;
            }
            let start = index;
            while index < tag.len() && tag[index].is_ascii_digit() {
                index += 1;
            }
            if start < index {
                let number: String = tag[start..index].iter().collect();
                if let Ok(value) = number.parse() {
                    *drawing_mode = value;
                }
            }
            continue;
        }
        index += 1;
    }
}

fn normalize_lines_and_entities(text: &str) -> String {
    let decoded = decode_entities(text);
    let mut output = String::with_capacity(decoded.len());
    let mut pending_blank = false;
    for line in decoded.replace('\r', "").lines() {
        let line = line.trim();
        if line.is_empty() {
            if !output.is_empty() {
                pending_blank = true;
            }
            continue;
        }
        if !output.is_empty() {
            output.push('\n');
            if pending_blank {
                output.push('\n');
            }
        }
        pending_blank = false;
        output.push_str(line);
    }
    output
}

fn decode_entities(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut remainder = text;
    while let Some(index) = remainder.find('&') {
        output.push_str(&remainder[..index]);
        remainder = &remainder[index..];
        let Some(end) = remainder.get(1..).and_then(|tail| tail.find(';')) else {
            output.push_str(remainder);
            return output;
        };
        let entity_end = end + 1;
        let entity = &remainder[1..entity_end];
        let decoded = match entity {
            "amp" => Some('&'),
            "lt" => Some('<'),
            "gt" => Some('>'),
            "quot" => Some('"'),
            "apos" => Some('\''),
            "nbsp" => Some(' '),
            "lrm" => Some('\u{200e}'),
            "rlm" => Some('\u{200f}'),
            value if value.starts_with("#x") || value.starts_with("#X") => {
                u32::from_str_radix(&value[2..], 16)
                    .ok()
                    .and_then(valid_entity_character)
            }
            value if value.starts_with('#') => value[1..]
                .parse::<u32>()
                .ok()
                .and_then(valid_entity_character),
            _ => None,
        };
        if let Some(character) = decoded {
            output.push(character);
        } else {
            output.push_str(&remainder[..=entity_end]);
        }
        remainder = &remainder[entity_end + 1..];
    }
    output.push_str(remainder);
    output
}

fn valid_entity_character(value: u32) -> Option<char> {
    let character = char::from_u32(value)?;
    (!character.is_control() || matches!(character, '\n' | '\t')).then_some(character)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_srt_bom_crlf_markup_and_comma_fraction() {
        let source =
            "\u{feff}1\r\n00:00:01,250 --> 00:00:03,500\r\n<i>Hello &amp; goodbye</i>\r\n\r\n";
        let cues = parse_subtitle_document(source, SubtitleFormat::Srt).unwrap();
        assert_eq!(cues.len(), 1);
        assert_eq!(cues[0].identifier.as_deref(), Some("1"));
        assert_eq!((cues[0].start_us, cues[0].end_us), (1_250_000, 3_500_000));
        assert_eq!(cues[0].text, "Hello & goodbye");
    }

    #[test]
    fn skips_malformed_srt_blocks_and_sorts_valid_cues() {
        let source = "broken\nnot timing\ntext\n\n2\n00:00:03,000 --> 00:00:04,000\nLater\n\n1\n00:00:01,000 --> 00:00:02,000\nFirst";
        let cues = parse_subtitle_document(source, SubtitleFormat::Srt).unwrap();
        assert_eq!(
            cues.iter().map(|cue| cue.text.as_str()).collect::<Vec<_>>(),
            ["First", "Later"]
        );
    }

    #[test]
    fn parses_webvtt_metadata_notes_settings_tags_and_entities() {
        let source = "WEBVTT - Bunny\nKind: captions\n\nNOTE generated cue\nignored\n\nintro\n00:01.500 --> 00:03.250 align:start position:10%\n<v Bunny><b>Hello</b><br>world&nbsp;!</v>\n";
        let cues = parse_subtitle_document(source, SubtitleFormat::WebVtt).unwrap();
        assert_eq!(cues.len(), 1);
        assert_eq!(cues[0].identifier.as_deref(), Some("intro"));
        assert_eq!((cues[0].start_us, cues[0].end_us), (1_500_000, 3_250_000));
        assert_eq!(
            cues[0].settings.as_deref(),
            Some("align:start position:10%")
        );
        assert_eq!(cues[0].text, "Hello\nworld !");
    }

    #[test]
    fn parses_ass_dynamic_format_commas_breaks_and_override_tags() {
        let source = "[Script Info]\nScriptType: v4.00+\n[Events]\nFormat: Layer, End, Start, Style, Text\nDialogue: 0,0:00:03.50,0:00:01.25,Default,{\\i1}Hello, Bunny{\\i0}\\NSecond\\hline\n";
        let cues = parse_subtitle_document(source, SubtitleFormat::Ass).unwrap();
        assert_eq!(cues.len(), 1);
        assert_eq!((cues[0].start_us, cues[0].end_us), (1_250_000, 3_500_000));
        assert_eq!(cues[0].settings.as_deref(), Some("Default"));
        assert_eq!(cues[0].text, "Hello, Bunny\nSecond line");
    }

    #[test]
    fn parses_ssa_default_marked_layout() {
        let source = "[Script Info]\nScriptType: v4.00\n[Events]\nDialogue: Marked=0,0:00:01.00,0:00:02.00,Main,Bunny,0,0,0,,Hi\n";
        let cues = parse_subtitle_document(source, SubtitleFormat::Auto).unwrap();
        assert_eq!(cues.len(), 1);
        assert_eq!(cues[0].text, "Hi");
        assert_eq!(cues[0].settings.as_deref(), Some("Main"));
    }

    #[test]
    fn drops_ass_vector_drawing_but_keeps_following_text() {
        let source = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,{\\p1}m 0 0 l 10 10{\\p0}Caption\n";
        let cues = parse_subtitle_document(source, SubtitleFormat::Ass).unwrap();
        assert_eq!(cues[0].text, "Caption");
    }

    #[test]
    fn parses_utf8_bytes_and_rejects_invalid_utf8() {
        let valid = b"1\n00:00:00,000 --> 00:00:01,000\nBunny";
        assert_eq!(
            parse_subtitle_bytes(valid, SubtitleFormat::Auto).unwrap()[0].text,
            "Bunny"
        );
        assert_eq!(
            parse_subtitle_bytes(&[0xff], SubtitleFormat::Srt),
            Err(SubtitleError::InvalidUtf8)
        );
    }

    #[test]
    fn cue_activity_uses_half_open_interval() {
        let cue = SubtitleCue {
            identifier: None,
            start_us: 10,
            end_us: 20,
            text: "x".to_owned(),
            settings: None,
        };
        assert!(!cue.is_active_at(9));
        assert!(cue.is_active_at(10));
        assert!(!cue.is_active_at(20));
        assert_eq!(cue.duration_us(), 10);
    }
}
