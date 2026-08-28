use std::{ffi::c_void, fmt, ptr};

pub const MAX_ELEMENT_HEADER_LENGTH: usize = 12;
pub const MAX_METADATA_ELEMENT_LENGTH: u64 = 16 * 1024 * 1024;
/// Some real-world Matroska muxers leave raw null padding between children of
/// a Master Element instead of using an EBML Void element. Keep compatibility
/// local to a known parent boundary and cap the scan so corrupt input cannot
/// cause unbounded remote reads.
pub const MAX_IGNORED_NULL_PADDING_BYTES: u64 = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MediaError {
    InvalidData(&'static str),
    Unsupported(&'static str),
    UnexpectedEnd,
    SourceRead,
    ElementTooLarge,
    ArithmeticOverflow,
}

impl fmt::Display for MediaError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidData(message) => write!(formatter, "invalid media data: {message}"),
            Self::Unsupported(message) => write!(formatter, "unsupported media feature: {message}"),
            Self::UnexpectedEnd => formatter.write_str("unexpected end of media source"),
            Self::SourceRead => formatter.write_str("media source read failed"),
            Self::ElementTooLarge => formatter.write_str("media element exceeds safety limit"),
            Self::ArithmeticOverflow => formatter.write_str("media offset overflow"),
        }
    }
}

impl std::error::Error for MediaError {}

pub trait ReadAt {
    fn len(&self) -> u64;
    fn read_at(&mut self, offset: u64, output: &mut [u8]) -> Result<usize, MediaError>;

    fn read_exact_at(&mut self, offset: u64, output: &mut [u8]) -> Result<(), MediaError> {
        let mut completed = 0_usize;
        while completed < output.len() {
            let completed_u64 =
                u64::try_from(completed).map_err(|_| MediaError::ArithmeticOverflow)?;
            let next_offset = offset
                .checked_add(completed_u64)
                .ok_or(MediaError::ArithmeticOverflow)?;
            let read = self.read_at(next_offset, &mut output[completed..])?;
            if read == 0 {
                return Err(MediaError::UnexpectedEnd);
            }
            completed = completed
                .checked_add(read)
                .ok_or(MediaError::ArithmeticOverflow)?;
        }
        Ok(())
    }
}

pub struct SliceSource<'a> {
    bytes: &'a [u8],
}

impl<'a> SliceSource<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes }
    }
}

impl ReadAt for SliceSource<'_> {
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

pub type ReadAtCallback =
    unsafe extern "C" fn(context: *mut c_void, offset: u64, output: *mut u8, length: usize) -> i64;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct SourceCallbacks {
    pub abi_version: u32,
    pub source_length: u64,
    pub read_at: Option<ReadAtCallback>,
}

pub struct CallbackSource {
    callbacks: SourceCallbacks,
    context: *mut c_void,
}

impl CallbackSource {
    pub fn new(callbacks: SourceCallbacks, context: *mut c_void) -> Result<Self, MediaError> {
        if callbacks.abi_version != 1 || callbacks.read_at.is_none() {
            return Err(MediaError::InvalidData("invalid source callback table"));
        }
        Ok(Self { callbacks, context })
    }
}

impl ReadAt for CallbackSource {
    fn len(&self) -> u64 {
        self.callbacks.source_length
    }

    fn read_at(&mut self, offset: u64, output: &mut [u8]) -> Result<usize, MediaError> {
        if output.is_empty() {
            return Ok(0);
        }
        let callback = self.callbacks.read_at.ok_or(MediaError::SourceRead)?;
        // SAFETY: The callback receives the caller-owned context and a writable
        // slice that remains valid for the duration of this synchronous call.
        let result = unsafe { callback(self.context, offset, output.as_mut_ptr(), output.len()) };
        if result < 0 {
            return Err(MediaError::SourceRead);
        }
        let result = usize::try_from(result).map_err(|_| MediaError::SourceRead)?;
        if result > output.len() {
            return Err(MediaError::SourceRead);
        }
        Ok(result)
    }
}

impl Drop for CallbackSource {
    fn drop(&mut self) {
        self.context = ptr::null_mut();
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ElementHeader {
    pub id: u64,
    pub offset: u64,
    pub data_offset: u64,
    pub size: Option<u64>,
}

pub fn vint_length(first: u8, maximum: usize) -> Result<usize, MediaError> {
    if first == 0 {
        return Err(MediaError::InvalidData("zero EBML variable integer"));
    }
    let length = first.leading_zeros() as usize + 1;
    if length > maximum {
        return Err(MediaError::InvalidData("oversized EBML variable integer"));
    }
    Ok(length)
}

pub fn parse_id(bytes: &[u8]) -> Result<(u64, usize), MediaError> {
    let first = *bytes.first().ok_or(MediaError::UnexpectedEnd)?;
    let length = vint_length(first, 4)?;
    if bytes.len() < length {
        return Err(MediaError::UnexpectedEnd);
    }
    let mut value = 0_u64;
    for byte in &bytes[..length] {
        value = (value << 8) | u64::from(*byte);
    }
    Ok((value, length))
}

pub fn parse_size(bytes: &[u8]) -> Result<(Option<u64>, usize), MediaError> {
    let first = *bytes.first().ok_or(MediaError::UnexpectedEnd)?;
    let length = vint_length(first, 8)?;
    if bytes.len() < length {
        return Err(MediaError::UnexpectedEnd);
    }
    let marker = 1_u8 << (8 - length);
    let mut value = u64::from(first & !marker);
    for byte in &bytes[1..length] {
        value = (value << 8) | u64::from(*byte);
    }
    let unknown = value == ((1_u64 << (7 * length)) - 1);
    Ok(((!unknown).then_some(value), length))
}

pub fn parse_vint_value(bytes: &[u8]) -> Result<(u64, usize), MediaError> {
    let first = *bytes.first().ok_or(MediaError::UnexpectedEnd)?;
    let length = vint_length(first, 8)?;
    if bytes.len() < length {
        return Err(MediaError::UnexpectedEnd);
    }
    let marker = 1_u8 << (8 - length);
    let mut value = u64::from(first & !marker);
    for byte in &bytes[1..length] {
        value = (value << 8) | u64::from(*byte);
    }
    Ok((value, length))
}

pub fn parse_signed_vint(bytes: &[u8]) -> Result<(i64, usize), MediaError> {
    let (unsigned, length) = parse_vint_value(bytes)?;
    let bits = 7 * length;
    let bias = (1_i128 << (bits - 1)) - 1;
    let signed = i128::from(unsigned) - bias;
    let signed = i64::try_from(signed).map_err(|_| MediaError::ArithmeticOverflow)?;
    Ok((signed, length))
}

pub fn read_header(source: &mut dyn ReadAt, offset: u64) -> Result<ElementHeader, MediaError> {
    let remaining = source.len().saturating_sub(offset);
    if remaining < 2 {
        return Err(MediaError::UnexpectedEnd);
    }
    let count = usize::try_from(remaining.min(MAX_ELEMENT_HEADER_LENGTH as u64))
        .map_err(|_| MediaError::ArithmeticOverflow)?;
    let mut buffer = [0_u8; MAX_ELEMENT_HEADER_LENGTH];
    source.read_exact_at(offset, &mut buffer[..count])?;
    let (id, id_length) = parse_id(&buffer[..count])?;
    let (size, size_length) = parse_size(&buffer[id_length..count])?;
    let header_length = id_length
        .checked_add(size_length)
        .ok_or(MediaError::ArithmeticOverflow)?;
    let data_offset = offset
        .checked_add(header_length as u64)
        .ok_or(MediaError::ArithmeticOverflow)?;
    Ok(ElementHeader {
        id,
        offset,
        data_offset,
        size,
    })
}

pub fn read_child_header(
    source: &mut dyn ReadAt,
    offset: u64,
    parent_end: u64,
) -> Result<Option<ElementHeader>, MediaError> {
    if offset > parent_end || parent_end > source.len() {
        return Err(MediaError::UnexpectedEnd);
    }

    let mut cursor = offset;
    let mut skipped = 0_u64;
    let mut buffer = [0_u8; 256];
    while cursor < parent_end {
        let remaining = parent_end
            .checked_sub(cursor)
            .ok_or(MediaError::ArithmeticOverflow)?;
        let count = usize::try_from(remaining.min(buffer.len() as u64))
            .map_err(|_| MediaError::ArithmeticOverflow)?;
        source.read_exact_at(cursor, &mut buffer[..count])?;

        if let Some(index) = buffer[..count].iter().position(|byte| *byte != 0) {
            let index = u64::try_from(index).map_err(|_| MediaError::ArithmeticOverflow)?;
            skipped = skipped
                .checked_add(index)
                .ok_or(MediaError::ArithmeticOverflow)?;
            if skipped > MAX_IGNORED_NULL_PADDING_BYTES {
                return Err(MediaError::ElementTooLarge);
            }
            let header_offset = cursor
                .checked_add(index)
                .ok_or(MediaError::ArithmeticOverflow)?;
            let header = read_header(source, header_offset)?;
            if header.data_offset > parent_end {
                return Err(MediaError::UnexpectedEnd);
            }
            return Ok(Some(header));
        }

        let count = u64::try_from(count).map_err(|_| MediaError::ArithmeticOverflow)?;
        skipped = skipped
            .checked_add(count)
            .ok_or(MediaError::ArithmeticOverflow)?;
        if skipped > MAX_IGNORED_NULL_PADDING_BYTES {
            return Err(MediaError::ElementTooLarge);
        }
        cursor = cursor
            .checked_add(count)
            .ok_or(MediaError::ArithmeticOverflow)?;
    }
    Ok(None)
}

pub fn read_bytes(
    source: &mut dyn ReadAt,
    offset: u64,
    size: u64,
    limit: u64,
) -> Result<Vec<u8>, MediaError> {
    if size > limit {
        return Err(MediaError::ElementTooLarge);
    }
    let size = usize::try_from(size).map_err(|_| MediaError::ArithmeticOverflow)?;
    let mut result = vec![0_u8; size];
    source.read_exact_at(offset, &mut result)?;
    Ok(result)
}

pub fn read_uint(source: &mut dyn ReadAt, header: ElementHeader) -> Result<u64, MediaError> {
    let size = header
        .size
        .ok_or(MediaError::InvalidData("unknown integer size"))?;
    if !(1..=8).contains(&size) {
        return Err(MediaError::InvalidData("invalid EBML integer size"));
    }
    let mut bytes = [0_u8; 8];
    let start = 8 - size as usize;
    source.read_exact_at(header.data_offset, &mut bytes[start..])?;
    Ok(u64::from_be_bytes(bytes))
}

pub fn read_float(source: &mut dyn ReadAt, header: ElementHeader) -> Result<f64, MediaError> {
    match header.size {
        Some(4) => {
            let mut bytes = [0_u8; 4];
            source.read_exact_at(header.data_offset, &mut bytes)?;
            Ok(f32::from_bits(u32::from_be_bytes(bytes)) as f64)
        }
        Some(8) => {
            let mut bytes = [0_u8; 8];
            source.read_exact_at(header.data_offset, &mut bytes)?;
            Ok(f64::from_bits(u64::from_be_bytes(bytes)))
        }
        _ => Err(MediaError::InvalidData("invalid EBML float size")),
    }
}

pub fn read_string(source: &mut dyn ReadAt, header: ElementHeader) -> Result<String, MediaError> {
    let size = header
        .size
        .ok_or(MediaError::InvalidData("unknown string size"))?;
    let bytes = read_bytes(
        source,
        header.data_offset,
        size,
        MAX_METADATA_ELEMENT_LENGTH,
    )?;
    let value = String::from_utf8_lossy(&bytes)
        .trim_end_matches('\0')
        .to_owned();
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ids_and_sizes() {
        assert_eq!(parse_id(&[0x1a, 0x45, 0xdf, 0xa3]), Ok((0x1a45dfa3, 4)));
        assert_eq!(parse_size(&[0x84]), Ok((Some(4), 1)));
        assert_eq!(parse_size(&[0x40, 0x7f]), Ok((Some(127), 2)));
        assert_eq!(parse_size(&[0xff]), Ok((None, 1)));
    }

    #[test]
    fn parses_signed_lacing_values() {
        assert_eq!(parse_signed_vint(&[0xbf]), Ok((0, 1)));
        assert_eq!(parse_signed_vint(&[0xc0]), Ok((1, 1)));
        assert_eq!(parse_signed_vint(&[0xbe]), Ok((-1, 1)));
    }

    #[test]
    fn reads_an_element_header_from_a_slice() {
        let bytes = [0x1a, 0x45, 0xdf, 0xa3, 0x84, 1, 2, 3, 4];
        let mut source = SliceSource::new(&bytes);
        let header = read_header(&mut source, 0).unwrap();
        assert_eq!(header.id, 0x1a45dfa3);
        assert_eq!(header.data_offset, 5);
        assert_eq!(header.size, Some(4));
    }

    #[test]
    fn child_header_skips_bounded_null_padding() {
        let bytes = [0, 0, 0, 0xa3, 0x81, 0x7f];
        let mut source = SliceSource::new(&bytes);
        let header = read_child_header(&mut source, 0, bytes.len() as u64)
            .unwrap()
            .unwrap();
        assert_eq!(header.id, 0xa3);
        assert_eq!(header.offset, 3);
        assert_eq!(header.data_offset, 5);
        assert_eq!(header.size, Some(1));
    }

    #[test]
    fn child_header_stops_at_parent_boundary() {
        let bytes = [0, 0, 0, 0xa3, 0x81, 0x7f];
        let mut source = SliceSource::new(&bytes);
        assert_eq!(read_child_header(&mut source, 0, 3), Ok(None));
    }

    #[test]
    fn child_header_rejects_excessive_null_padding() {
        let bytes = vec![0; MAX_IGNORED_NULL_PADDING_BYTES as usize + 1];
        let mut source = SliceSource::new(&bytes);
        assert_eq!(
            read_child_header(&mut source, 0, bytes.len() as u64),
            Err(MediaError::ElementTooLarge)
        );
    }
}
