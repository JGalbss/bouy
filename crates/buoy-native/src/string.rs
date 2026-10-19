//! The methods of `String.prototype` whose loops run over a whole string: the case maps
//! of `toLowerCase` and `toUpperCase` (ECMA-262 22.1.3.28 and 22.1.3.30), and
//! `replaceAll` with a string search and a replacement without `$` patterns (22.1.3.20).
//!
//! Each NIF reads the code units of engine strings (section 17.1 of the contract) as they
//! are: one byte each, or two bytes each, big-endian. It does a bounded piece of the work,
//! from a unit index, and returns the text of that piece with the index where the next
//! call starts, so a long string takes several calls and the process yields between them
//! (`slice`). The Erlang caller joins the pieces. Bun's strings have the same two forms,
//! and its case maps and its replace also take a fast loop over one-byte text.

use std::borrow::Cow;
use std::time::Instant;

use icu_casemap::CaseMapper;
use icu_locale::LanguageIdentifier;
use memchr::memmem;
use rustler::schedule::consume_timeslice;
use rustler::types::tuple::make_tuple;
use rustler::{Binary, Encoder, Env, NewBinary, Term};

mod atoms {
    rustler::atoms! {
        done, more, rest,
        two_byte = "$u16",
    }
}

/// The units of one-byte text that a call maps: about 100 µs of work.
const NARROW_WINDOW: usize = 256 * 1024;

/// The units of two-byte text that a call maps with ICU4X, which is slower per unit.
const WIDE_WINDOW: usize = 16 * 1024;

/// The units of text that a call of `replaceAll` scans.
const REPLACE_WINDOW: usize = 256 * 1024;

/// `string_case(Text, Wide, Upper, From)`: the units of `Text` from `From` on, in lower or
/// upper case, as far as one call goes: `{done, Part}` or `{more, Next, Part}`. `Part` is
/// an engine string.
#[rustler::nif]
fn string_case<'a>(
    env: Env<'a>,
    text: Binary<'a>,
    wide: bool,
    upper: bool,
    from: usize,
) -> Term<'a> {
    let started = Instant::now();
    let bytes = text.as_slice();
    let (part, next) = if wide {
        let end = case_boundary(bytes, from, WIDE_WINDOW);
        let units = units_of(&bytes[from.min(end) * 2..end * 2]);
        (Units::Wide(change_case(&units, upper)), end)
    } else {
        let end = (from + NARROW_WINDOW).min(bytes.len());
        (narrow_case(&bytes[from.min(end)..end], upper), end)
    };
    spend(env, started);
    let length = if wide { bytes.len() / 2 } else { bytes.len() };
    let part = part.term(env);
    if next >= length {
        make_tuple(env, &[atoms::done().encode(env), part])
    } else {
        make_tuple(env, &[atoms::more().encode(env), next.encode(env), part])
    }
}

/// `string_replace_all(Text, Wide, Search, SearchWide, Replacement, ReplacementWide, From)`:
/// the units of `Text` from `From` on, with each occurrence of the nonempty `Search`
/// replaced by `Replacement`, as far as one call goes: `{done, Part}` or
/// `{more, Next, Part}`. An occurrence that starts in this call ends in it too, and the
/// next call searches from its end, so the occurrences are those of one scan from the
/// left, as `replaceAll` finds them. `{rest, Next, Part}` says that no occurrence starts
/// at `Next` or later, so the rest of the text stays as it is.
#[rustler::nif]
#[allow(clippy::too_many_arguments)]
fn string_replace_all<'a>(
    env: Env<'a>,
    text: Binary<'a>,
    wide: bool,
    search: Binary<'a>,
    search_wide: bool,
    replacement: Binary<'a>,
    replacement_wide: bool,
    from: usize,
) -> Term<'a> {
    let started = Instant::now();
    let width = if wide { 2 } else { 1 };
    let haystack = text.as_slice();
    let length = haystack.len() / width;
    let from = from.min(length);
    // The search in the form of the text. A wide search never occurs in one-byte text,
    // because a canonical two-byte string holds a unit above 0xFF.
    let needle: Cow<[u8]> = match (wide, search_wide) {
        (false, true) => Cow::Borrowed(&[]),
        (true, false) => Cow::Owned(widen(search.as_slice())),
        _ => Cow::Borrowed(search.as_slice()),
    };
    let limit = from.saturating_add(REPLACE_WINDOW).min(length);
    let mut out = if wide || replacement_wide {
        Out::Wide(Vec::with_capacity(limit - from))
    } else {
        Out::Narrow(Vec::with_capacity(limit - from))
    };
    let insert = Text::new(replacement.as_slice(), replacement_wide);
    let source = Text::new(haystack, wide);
    let mut at = from;
    let mut copied = from;
    let mut exhausted = needle.is_empty();
    if !needle.is_empty() {
        let finder = memmem::Finder::new(needle.as_ref());
        while at < limit {
            let Some(found) = finder.find(&haystack[at * width..]) else {
                exhausted = true;
                break;
            };
            let byte = at * width + found;
            // In two-byte text, an occurrence starts at a unit, so at an even byte.
            if !byte.is_multiple_of(width) {
                at = byte / width + 1;
                continue;
            }
            let start = byte / width;
            if start >= limit {
                break;
            }
            out.push(&source, copied, start);
            out.push(&insert, 0, insert.len());
            at = start + needle.len() / width;
            copied = at;
        }
    }
    if exhausted {
        spend(env, started);
        let part = out.finish().term(env);
        return make_tuple(env, &[atoms::rest().encode(env), copied.encode(env), part]);
    }
    let end = at.max(limit).min(length);
    out.push(&source, copied, end);
    spend(env, started);
    let part = out.finish().term(env);
    if end >= length {
        make_tuple(env, &[atoms::done().encode(env), part])
    } else {
        make_tuple(env, &[atoms::more().encode(env), end.encode(env), part])
    }
}

/// The code units of an engine string, as its bytes hold them.
struct Text<'t> {
    bytes: &'t [u8],
    wide: bool,
}

impl<'t> Text<'t> {
    fn new(bytes: &'t [u8], wide: bool) -> Self {
        Self { bytes, wide }
    }

    fn len(&self) -> usize {
        if self.wide {
            self.bytes.len() / 2
        } else {
            self.bytes.len()
        }
    }
}

/// The text of a replace as it grows: one byte for each unit while the text and the
/// replacement are both one-byte.
enum Out {
    Narrow(Vec<u8>),
    Wide(Vec<u16>),
}

impl Out {
    /// Appends the units `from..to` of `text`.
    fn push(&mut self, text: &Text, from: usize, to: usize) {
        match (self, text.wide) {
            (Self::Narrow(bytes), false) => bytes.extend_from_slice(&text.bytes[from..to]),
            (Self::Wide(units), false) => {
                units.extend(text.bytes[from..to].iter().map(|byte| u16::from(*byte)));
            }
            (Self::Wide(units), true) => units.extend(units_of(&text.bytes[from * 2..to * 2])),
            // A two-byte text or replacement makes the output two-byte from the start.
            (Self::Narrow(_), true) => {}
        }
    }

    fn finish(self) -> Units {
        match self {
            Self::Narrow(bytes) => Units::Narrow(bytes),
            Self::Wide(units) => Units::Wide(units),
        }
    }
}

/// Reports the time of a call to the scheduler, one percent of a slice for each
/// microsecond (see `slice`).
fn spend(env: Env, started: Instant) {
    let percent = started.elapsed().as_micros().clamp(1, 100);
    let _ = consume_timeslice(env, i32::try_from(percent).unwrap_or(100));
}

/// The text of a piece, before it becomes a term.
enum Units {
    /// One byte for each unit.
    Narrow(Vec<u8>),
    Wide(Vec<u16>),
}

impl Units {
    /// The engine string: a binary when every unit is at most 0xFF, else
    /// `{'$u16', Bytes}`.
    fn term<'a>(&self, env: Env<'a>) -> Term<'a> {
        match self {
            Self::Narrow(bytes) => binary(env, bytes),
            Self::Wide(units) => {
                if units.iter().all(|unit| *unit <= 0xFF) {
                    #[allow(clippy::cast_possible_truncation)]
                    let bytes: Vec<u8> = units.iter().map(|unit| *unit as u8).collect();
                    return binary(env, &bytes);
                }
                let bytes: Vec<u8> = units.iter().flat_map(|unit| unit.to_be_bytes()).collect();
                make_tuple(env, &[atoms::two_byte().encode(env), binary(env, &bytes)])
            }
        }
    }
}

fn binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    Binary::from(binary).to_term(env)
}

/// The units of big-endian two-byte text.
fn units_of(bytes: &[u8]) -> Vec<u16> {
    bytes
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| u16::from_be_bytes(*pair))
        .collect()
}

/// One-byte text as big-endian two-byte text.
fn widen(bytes: &[u8]) -> Vec<u8> {
    bytes.iter().flat_map(|byte| [0, *byte]).collect()
}

/// One-byte (Latin-1) text in lower or upper case. Every Latin-1 letter maps to one
/// Latin-1 letter, except in upper case: ß becomes SS, and µ and ÿ map outside Latin-1.
fn narrow_case(bytes: &[u8], upper: bool) -> Units {
    if !upper {
        return Units::Narrow(
            bytes
                .iter()
                .map(|&byte| match byte {
                    b'A'..=b'Z' | 0xC0..=0xD6 | 0xD8..=0xDE => byte + 0x20,
                    _ => byte,
                })
                .collect(),
        );
    }
    if !bytes.iter().any(|&byte| byte == 0xB5 || byte == 0xFF) {
        let mut out = Vec::with_capacity(bytes.len());
        for &byte in bytes {
            match byte {
                b'a'..=b'z' | 0xE0..=0xF6 | 0xF8..=0xFE => out.push(byte - 0x20),
                0xDF => out.extend_from_slice(b"SS"),
                _ => out.push(byte),
            }
        }
        return Units::Narrow(out);
    }
    let mut out = Vec::with_capacity(bytes.len());
    for &byte in bytes {
        match byte {
            b'a'..=b'z' | 0xE0..=0xF6 | 0xF8..=0xFE => out.push(u16::from(byte - 0x20)),
            0xDF => out.extend_from_slice(&[0x53, 0x53]),
            0xB5 => out.push(0x039C),
            0xFF => out.push(0x0178),
            _ => out.push(u16::from(byte)),
        }
    }
    Units::Wide(out)
}

/// The end of the piece of big-endian two-byte text that a call maps: past
/// `from + window`, at a unit that is neither cased nor case-ignorable, so the context of
/// a final sigma never crosses it, nor does a surrogate pair. The whole rest when no such
/// unit follows.
fn case_boundary(bytes: &[u8], from: usize, window: usize) -> usize {
    let length = bytes.len() / 2;
    let start = from.saturating_add(window);
    if start >= length {
        return length;
    }
    bytes[start * 2..]
        .as_chunks::<2>()
        .0
        .iter()
        .position(|pair| is_separator(u16::from_be_bytes(*pair)))
        .map_or(length, |offset| start + offset)
}

/// An ASCII unit that is neither a letter nor case-ignorable (Unicode's
/// `Case_Ignorable` holds `'`, `.`, `:`, `^`, and `` ` `` of ASCII).
fn is_separator(unit: u16) -> bool {
    unit < 0x80 && !matches!(unit, 0x41..=0x5A | 0x61..=0x7A | 0x27 | 0x2E | 0x3A | 0x5E | 0x60)
}

/// Two-byte text in lower or upper case, with the full case mappings of the root locale,
/// as `toLowerCase` and `toUpperCase` take them. A lone surrogate has no case and stays.
fn change_case(units: &[u16], upper: bool) -> Vec<u16> {
    let mapper = CaseMapper::new();
    let language = LanguageIdentifier::UNKNOWN;
    let mut out = Vec::with_capacity(units.len());
    let mut run = String::new();
    let flush = |run: &mut String, out: &mut Vec<u16>| {
        if run.is_empty() {
            return;
        }
        let changed = if upper {
            mapper.uppercase_to_string(run, &language)
        } else {
            mapper.lowercase_to_string(run, &language)
        };
        out.extend(changed.encode_utf16());
        run.clear();
    };
    for decoded in char::decode_utf16(units.iter().copied()) {
        match decoded {
            Ok(c) => run.push(c),
            Err(lone) => {
                flush(&mut run, &mut out);
                out.push(lone.unpaired_surrogate());
            }
        }
    }
    flush(&mut run, &mut out);
    out
}
