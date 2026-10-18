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

/// The units of `ToString` of a reference to a string: the string, or `null` or
/// `undefined`.
///
/// # Safety
///
/// `address` must be 0, 1, or the address of a string.
unsafe fn reference_units(address: u64, out: &mut Vec<u16>) {
    match address {
        0 => out.extend("null".encode_utf16()),
        1 => out.extend("undefined".encode_utf16()),
        // SAFETY: as the caller promises.
        _ => out.extend_from_slice(unsafe { slice(address) }),
    }
}

/// A new string of the parts at `parts`: `count` pairs of a kind and a value.
pub extern "C" fn buoy_text(frame: *mut Frame, parts: *const u64, count: u64) -> u64 {
    let mut out = Vec::new();
    let count = usize::try_from(count).unwrap_or(0);
    for index in 0..count {
        // SAFETY: the machine code stores `count` pairs of words at `parts`.
        let (kind, value) =
            unsafe { (parts.add(2 * index).read(), parts.add(2 * index + 1).read()) };
        match i64::try_from(kind).unwrap_or(TEXT_STR) {
            TEXT_NUM => out.extend(number_to_string(f64::from_bits(value)).encode_utf16()),
            TEXT_BOOL if value & 0xff != 0 => out.extend("true".encode_utf16()),
            TEXT_BOOL => out.extend("false".encode_utf16()),
            // SAFETY: a part of a string type holds a reference to a string.
            _ => unsafe { reference_units(value, &mut out) },
        }
    }
    let words = string_words(&out);
    // SAFETY: the machine code passes the frame of its run.
    unsafe {
        let address = allocate(frame, (words.len() * 8) as u64) as *mut u64;
        std::ptr::copy_nonoverlapping(words.as_ptr(), address, words.len());
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

/// `Number::toString(x, 10)` (ECMA-262 §6.1.6.1.20): the shortest digits that read back to
/// the same double, in the notation that the exponent selects.
#[must_use]
pub fn number_to_string(value: f64) -> String {
    if value.is_nan() {
        return "NaN".to_owned();
    }
    if value == 0.0 {
        return "0".to_owned();
    }
    if value.is_infinite() {
        return if value > 0.0 { "Infinity" } else { "-Infinity" }.to_owned();
    }
    let sign = if value < 0.0 { "-" } else { "" };
    // Rust prints the shortest digits that round-trip: `d.ddde±x`.
    let scientific = format!("{:e}", value.abs());
    let (mantissa, exponent) = scientific.split_once('e').unwrap_or((&scientific, "0"));
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let k = i64::try_from(digits.len()).unwrap_or(1);
    let n = exponent.parse::<i64>().unwrap_or(0) + 1;
    let body = if k <= n && n <= 21 {
        format!(
            "{digits}{}",
            "0".repeat(usize::try_from(n - k).unwrap_or(0))
        )
    } else if 0 < n && n <= 21 {
        let (whole, fraction) = digits.split_at(usize::try_from(n).unwrap_or(0));
        format!("{whole}.{fraction}")
    } else if -6 < n && n <= 0 {
        format!("0.{}{digits}", "0".repeat(usize::try_from(-n).unwrap_or(0)))
    } else {
        let power = n - 1;
        let sign = if power < 0 { '-' } else { '+' };
        let (first, rest) = digits.split_at(1);
        let dot = if rest.is_empty() { "" } else { "." };
        format!("{first}{dot}{rest}e{sign}{}", power.abs())
    };
    format!("{sign}{body}")
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
            (2.0_f64.powi(53), "9007199254740992"),
            (f64::MAX, "1.7976931348623157e+308"),
            (5e-324, "5e-324"),
            (f64::NAN, "NaN"),
            (f64::NEG_INFINITY, "-Infinity"),
        ];
        for (value, text) in cases {
            assert_eq!(number_to_string(value), text, "{value:e}");
        }
    }
}
