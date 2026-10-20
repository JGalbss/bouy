//! Strings in the heap of a run: [`STRING_TAG`], the length in UTF-16 code units, and the
//! units, two bytes each, padded to a whole word. A string never changes, so a literal
//! points into the memory of the code, and an operation makes a new string.

#![allow(unsafe_code)]

use crate::codegen::{STRING_TAG, string};
use crate::run::{Frame, allocate};

/// The kinds of the parts of [`buoy_text`].
pub const TEXT_NUM: i64 = 0;
pub const TEXT_BOOL: i64 = 1;
pub const TEXT_STR: i64 = 2;

/// The words of a string of `units`.
#[must_use]
pub fn string_words(units: &[u16]) -> Box<[u64]> {
    let mut words = vec![0u64; 2 + units.len().div_ceil(4)];
    words[0] = STRING_TAG as u64;
    words[1] = units.len() as u64;
    // SAFETY: the words after the first two have room for every unit.
    let room = unsafe {
        std::slice::from_raw_parts_mut(words.as_mut_ptr().add(2).cast::<u16>(), units.len())
    };
    room.copy_from_slice(units);
    words.into_boxed_slice()
}

/// The address of a new string of `units` in the heap of `frame`, made outside the
/// machine code. `None` when the heap is full.
pub fn allocate_string(frame: &mut Frame, units: &[u16]) -> Option<u64> {
    let words = string_words(units);
    let address = frame.allocate_words(words.len())?;
    // SAFETY: the heap gave `words.len()` words at `address`.
    unsafe { std::ptr::copy_nonoverlapping(words.as_ptr(), address, words.len()) };
    Some(address as u64)
}

/// The code units of the string at `address`.
///
/// # Safety
///
/// `address` must be the address of a string.
#[must_use]
pub unsafe fn units(address: u64) -> Vec<u16> {
    // SAFETY: as the caller promises.
    unsafe { slice(address) }.to_vec()
}

/// # Safety
///
/// `address` must be the address of a string, which outlives the slice.
unsafe fn slice<'a>(address: u64) -> &'a [u16] {
    let header = address as *const u64;
    // SAFETY: as the caller promises: the length word, then the units.
    unsafe {
        let length = usize::try_from(header.byte_add(string::LENGTH as usize).read()).unwrap_or(0);
        let units = header.byte_add(string::UNITS).cast::<u16>();
        std::slice::from_raw_parts(units, length)
    }
}

/// One part of a string that [`buoy_text`] makes: units of a string, or ASCII text.
enum Piece<'a> {
    Units(&'a [u16]),
    Ascii(Ascii),
}

impl Piece<'_> {
    fn len(&self) -> usize {
        match self {
            Self::Units(units) => units.len(),
            Self::Ascii(ascii) => ascii.len,
        }
    }

    /// Writes the units of the piece at `out`.
    ///
    /// # Safety
    ///
    /// `out` must have room for `self.len()` units.
    unsafe fn write(&self, out: *mut u16) {
        match self {
            // SAFETY: as the caller promises.
            Self::Units(units) => unsafe {
                std::ptr::copy_nonoverlapping(units.as_ptr(), out, units.len());
            },
            Self::Ascii(ascii) => {
                for (index, byte) in ascii.bytes[..ascii.len].iter().enumerate() {
                    // SAFETY: as the caller promises.
                    unsafe { out.add(index).write(u16::from(*byte)) };
                }
            }
        }
    }
}

/// The part of [`buoy_text`] of the kind and the value.
///
/// # Safety
///
/// A part of the string kind must hold 0, 1, or the address of a string.
unsafe fn piece<'a>(kind: u64, value: u64) -> Piece<'a> {
    match i64::try_from(kind).unwrap_or(TEXT_STR) {
        TEXT_NUM => Piece::Ascii(number_to_string(f64::from_bits(value))),
        TEXT_BOOL if value & 0xff != 0 => Piece::Ascii(Ascii::from("true")),
        TEXT_BOOL => Piece::Ascii(Ascii::from("false")),
        _ => match value {
            0 => Piece::Ascii(Ascii::from("null")),
            1 => Piece::Ascii(Ascii::from("undefined")),
            // SAFETY: as the caller promises.
            _ => Piece::Units(unsafe { slice(value) }),
        },
    }
}

/// A new string of the parts at `parts`: `count` pairs of a kind and a value. It writes the
/// string straight into the heap and allocates nothing else, because a bail ends the
/// coroutine without running destructors.
pub extern "C" fn buoy_text(frame: *mut Frame, parts: *const u64, count: u64) -> u64 {
    let count = usize::try_from(count).unwrap_or(0);
    // SAFETY: the machine code stores `count` pairs of words at `parts`, and each part of a
    // string type holds a reference to a string.
    let piece_at = |index: usize| unsafe {
        piece(parts.add(2 * index).read(), parts.add(2 * index + 1).read())
    };
    let length: usize = (0..count).map(|index| piece_at(index).len()).sum();
    let words = 2 + length.div_ceil(4);
    // SAFETY: the machine code passes the frame of its run; the heap gives `words` words,
    // and the pieces fill the `length` units after the two words of the header.
    unsafe {
        let address = allocate(frame, (words * 8) as u64) as *mut u64;
        address.add(words - 1).write(0);
        address.write(STRING_TAG as u64);
        address.add(1).write(length as u64);
        let mut out = address.byte_add(string::UNITS).cast::<u16>();
        for index in 0..count {
            let piece = piece_at(index);
            piece.write(out);
            out = out.add(piece.len());
        }
        address as u64
    }
}

/// Whether two references to strings are equal: the same units, or the same `null` or
/// `undefined`.
pub extern "C" fn buoy_str_eq(a: u64, b: u64) -> i8 {
    if a == b {
        return 1;
    }
    if a <= 1 || b <= 1 {
        return 0;
    }
    // SAFETY: the machine code passes two references to strings.
    i8::from(unsafe { slice(a) == slice(b) })
}

/// `ToBoolean` of a reference to a string: a string that is not empty.
pub extern "C" fn buoy_str_truthy(address: u64) -> i8 {
    if address <= 1 {
        return 0;
    }
    // SAFETY: the machine code passes a reference to a string.
    i8::from(!unsafe { slice(address) }.is_empty())
}

/// ASCII text of at most 32 bytes, on the stack.
#[derive(Clone, Copy)]
pub struct Ascii {
    bytes: [u8; 32],
    len: usize,
}

impl Ascii {
    const fn new() -> Self {
        Self {
            bytes: [0; 32],
            len: 0,
        }
    }

    fn push(&mut self, byte: u8) {
        if let Some(slot) = self.bytes.get_mut(self.len) {
            *slot = byte;
            self.len += 1;
        }
    }

    fn push_all(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.push(*byte);
        }
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        std::str::from_utf8(&self.bytes[..self.len]).unwrap_or_default()
    }
}

impl From<&str> for Ascii {
    fn from(text: &str) -> Self {
        let mut ascii = Self::new();
        ascii.push_all(text.as_bytes());
        ascii
    }
}

impl std::fmt::Write for Ascii {
    fn write_str(&mut self, text: &str) -> std::fmt::Result {
        self.push_all(text.as_bytes());
        Ok(())
    }
}

/// `Number::toString(x, 10)` (ECMA-262 §6.1.6.1.20): the shortest digits that read back to
/// the same double, in the notation that the exponent selects. An integer below 2^53
/// prints its digits directly, as the int32 path of `numberToString` in `JavaScriptCore`
/// does. Nothing here allocates.
#[must_use]
pub fn number_to_string(value: f64) -> Ascii {
    if value.is_nan() {
        return Ascii::from("NaN");
    }
    if value == 0.0 {
        return Ascii::from("0");
    }
    if value.is_infinite() {
        return Ascii::from(if value > 0.0 { "Infinity" } else { "-Infinity" });
    }
    let mut out = Ascii::new();
    if value < 0.0 {
        out.push(b'-');
    }
    let magnitude = value.abs();
    if magnitude < 9_007_199_254_740_992.0 && magnitude.fract() == 0.0 {
        // The integers below 2^53 are exact, so their shortest digits are their digits, and
        // the conversion is exact.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let integer = magnitude as u64;
        let _ = std::fmt::Write::write_fmt(&mut out, format_args!("{integer}"));
        return out;
    }
    // Rust prints the shortest digits that round-trip: `d.ddde±x`.
    let mut scientific = Ascii::new();
    let _ = std::fmt::Write::write_fmt(&mut scientific, format_args!("{magnitude:e}"));
    let (mantissa, exponent) = scientific
        .as_str()
        .split_once('e')
        .unwrap_or((scientific.as_str(), "0"));
    let mut digits = Ascii::new();
    for byte in mantissa.bytes().filter(u8::is_ascii_digit) {
        digits.push(byte);
    }
    let digits = digits.as_str();
    let k = i64::try_from(digits.len()).unwrap_or(1);
    let n = exponent.parse::<i64>().unwrap_or(0) + 1;
    let zeros = |out: &mut Ascii, count: i64| {
        for _ in 0..count {
            out.push(b'0');
        }
    };
    if k <= n && n <= 21 {
        out.push_all(digits.as_bytes());
        zeros(&mut out, n - k);
    } else if 0 < n && n <= 21 {
        let (whole, fraction) = digits.split_at(usize::try_from(n).unwrap_or(0));
        out.push_all(whole.as_bytes());
        out.push(b'.');
        out.push_all(fraction.as_bytes());
    } else if -6 < n && n <= 0 {
        out.push_all(b"0.");
        zeros(&mut out, -n);
        out.push_all(digits.as_bytes());
    } else {
        let power = n - 1;
        let (first, rest) = digits.split_at(1);
        out.push_all(first.as_bytes());
        if !rest.is_empty() {
            out.push(b'.');
            out.push_all(rest.as_bytes());
        }
        out.push(b'e');
        out.push(if power < 0 { b'-' } else { b'+' });
        let _ = std::fmt::Write::write_fmt(&mut out, format_args!("{}", power.abs()));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::number_to_string;

    #[test]
    fn numbers_print_as_javascript_prints_them() {
        let cases = [
            (0.0, "0"),
            (-0.0, "0"),
            (1.0, "1"),
            (-12.5, "-12.5"),
            (0.1, "0.1"),
            (1e21, "1e+21"),
            (123_456_789_012_345_680_000.0, "123456789012345680000"),
            (1.5e-7, "1.5e-7"),
            (0.000_001, "0.000001"),
            (1e-7, "1e-7"),
            (-42.0, "-42"),
            (9_007_199_254_740_991.0, "9007199254740991"),
            (2.0_f64.powi(53), "9007199254740992"),
            (1e20, "100000000000000000000"),
            (f64::MAX, "1.7976931348623157e+308"),
            (5e-324, "5e-324"),
            (f64::NAN, "NaN"),
            (f64::NEG_INFINITY, "-Infinity"),
        ];
        for (value, text) in cases {
            assert_eq!(number_to_string(value).as_str(), text, "{value:e}");
        }
    }
}
