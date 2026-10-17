//! JSON parse and stringify as a native built-in. `parse` builds Erlang terms in the
//! representation of `erlang/json_typed.erl`: an object is `{[{Key, Value}]}` with its keys
//! in order, an array is a list, a string is a binary, and a number is an integer when it
//! has no fraction or exponent, else a float. A string without escapes is a sub-binary of
//! the input, so it costs no copy. `stringify` writes the same text back, and prints a
//! number as JavaScript does for the plain decimals of the document (no exponent forms).

use super::{
    Env, Term, binary_term, bytes, enif_get_atom, enif_get_double, enif_get_list_cell,
    enif_get_long, enif_get_tuple, enif_make_atom, enif_make_double, enif_make_list_from_array,
    enif_make_long, enif_make_sub_binary, enif_make_tuple_from_array, enif_term_type,
};
use std::ffi::{c_char, c_int, c_long};

struct Atoms {
    yes: Term,
    no: Term,
    null: Term,
}

struct Parser<'a> {
    env: *mut Env,
    input: &'a [u8],
    source: Term,
    at: usize,
    atoms: Atoms,
}

/// Parses the JSON text of the binary `source`, or returns None for text that is not JSON.
pub unsafe fn parse(env: *mut Env, source: Term, input: &[u8]) -> Option<Term> {
    let atoms = unsafe {
        Atoms {
            yes: enif_make_atom(env, c"true".as_ptr()),
            no: enif_make_atom(env, c"false".as_ptr()),
            null: enif_make_atom(env, c"null".as_ptr()),
        }
    };
    let mut parser = Parser {
        env,
        input,
        source,
        at: 0,
        atoms,
    };
    let value = unsafe { parser.value()? };
    parser.skip_space();
    (parser.at == input.len()).then_some(value)
}

impl Parser<'_> {
    fn skip_space(&mut self) {
        while let Some(b' ' | b'\n' | b'\r' | b'\t') = self.input.get(self.at) {
            self.at += 1;
        }
    }

    fn eat(&mut self, byte: u8) -> Option<()> {
        self.skip_space();
        (self.input.get(self.at) == Some(&byte)).then(|| self.at += 1)
    }

    fn word(&mut self, word: &[u8], term: Term) -> Option<Term> {
        self.input[self.at..].starts_with(word).then(|| {
            self.at += word.len();
            term
        })
    }

    unsafe fn value(&mut self) -> Option<Term> {
        self.skip_space();
        match *self.input.get(self.at)? {
            b'{' => unsafe { self.object() },
            b'[' => unsafe { self.array() },
            b'"' => unsafe { self.string() },
            b't' => self.word(b"true", self.atoms.yes),
            b'f' => self.word(b"false", self.atoms.no),
            b'n' => self.word(b"null", self.atoms.null),
            _ => unsafe { self.number() },
        }
    }

    unsafe fn object(&mut self) -> Option<Term> {
        self.at += 1;
        let mut pairs = Vec::new();
        if self.eat(b'}').is_none() {
            loop {
                self.skip_space();
                let key = unsafe { self.string()? };
                self.eat(b':')?;
                let value = unsafe { self.value()? };
                pairs.push(unsafe {
                    enif_make_tuple_from_array(self.env, [key, value].as_ptr(), 2)
                });
                if self.eat(b',').is_none() {
                    self.eat(b'}')?;
                    break;
                }
            }
        }
        unsafe {
            let list = enif_make_list_from_array(self.env, pairs.as_ptr(), count(pairs.len()));
            Some(enif_make_tuple_from_array(self.env, [list].as_ptr(), 1))
        }
    }

    unsafe fn array(&mut self) -> Option<Term> {
        self.at += 1;
        let mut items = Vec::new();
        if self.eat(b']').is_none() {
            loop {
                items.push(unsafe { self.value()? });
                if self.eat(b',').is_none() {
                    self.eat(b']')?;
                    break;
                }
            }
        }
        Some(unsafe { enif_make_list_from_array(self.env, items.as_ptr(), count(items.len())) })
    }

    unsafe fn string(&mut self) -> Option<Term> {
        if self.input.get(self.at) != Some(&b'"') {
            return None;
        }
        let start = self.at + 1;
        let mut end = start;
        loop {
            match *self.input.get(end)? {
                b'"' => break,
                b'\\' => return unsafe { self.escaped_string(start) },
                _ => end += 1,
            }
        }
        self.at = end + 1;
        Some(unsafe { enif_make_sub_binary(self.env, self.source, start, end - start) })
    }

    unsafe fn escaped_string(&mut self, start: usize) -> Option<Term> {
        let mut bytes = Vec::new();
        let mut at = start;
        loop {
            match *self.input.get(at)? {
                b'"' => break,
                b'\\' => {
                    at += 1;
                    let decoded = match *self.input.get(at)? {
                        b'n' => '\n',
                        b't' => '\t',
                        b'r' => '\r',
                        b'b' => '\u{8}',
                        b'f' => '\u{c}',
                        b'u' => {
                            let hex = std::str::from_utf8(self.input.get(at + 1..at + 5)?).ok()?;
                            at += 4;
                            // shortcut: a surrogate pair decodes to U+FFFD; the document has none.
                            char::from_u32(u32::from_str_radix(hex, 16).ok()?).unwrap_or('\u{fffd}')
                        }
                        other => char::from(other),
                    };
                    let mut buffer = [0; 4];
                    bytes.extend_from_slice(decoded.encode_utf8(&mut buffer).as_bytes());
                    at += 1;
                }
                byte => {
                    bytes.push(byte);
                    at += 1;
                }
            }
        }
        self.at = at + 1;
        Some(unsafe { binary_term(self.env, &bytes) })
    }

    unsafe fn number(&mut self) -> Option<Term> {
        let start = self.at;
        let mut integral = true;
        while let Some(&byte) = self.input.get(self.at) {
            match byte {
                b'0'..=b'9' | b'-' => {}
                b'.' | b'e' | b'E' | b'+' => integral = false,
                _ => break,
            }
            self.at += 1;
        }
        let text = std::str::from_utf8(&self.input[start..self.at]).ok()?;
        if integral && let Ok(value) = text.parse::<c_long>() {
            return Some(unsafe { enif_make_long(self.env, value) });
        }
        Some(unsafe { enif_make_double(self.env, text.parse::<f64>().ok()?) })
    }
}

fn count(length: usize) -> u32 {
    u32::try_from(length).unwrap_or(u32::MAX)
}

/// Writes the JSON text of a term in the representation of `parse`, or returns None for a
/// term outside it.
pub unsafe fn stringify(env: *mut Env, term: Term) -> Option<Term> {
    let mut out = Vec::with_capacity(1 << 20);
    unsafe { write(env, term, &mut out)? };
    Some(unsafe { binary_term(env, &out) })
}

// The values of ErlNifTermType that the representation uses.
const ATOM: c_int = 1;
const BITSTRING: c_int = 2;
const FLOAT: c_int = 3;
const INTEGER: c_int = 5;
const LIST: c_int = 6;
const TUPLE: c_int = 11;

unsafe fn write(env: *mut Env, term: Term, out: &mut Vec<u8>) -> Option<()> {
    unsafe {
        match enif_term_type(env, term) {
            BITSTRING => write_string(env, term, out),
            INTEGER => {
                let mut integer: c_long = 0;
                (enif_get_long(env, term, &raw mut integer) != 0).then_some(())?;
                out.extend_from_slice(itoa::Buffer::new().format(integer).as_bytes());
                Some(())
            }
            FLOAT => {
                let mut float = 0.0;
                (enif_get_double(env, term, &raw mut float) != 0).then_some(())?;
                write_number(float, out);
                Some(())
            }
            LIST => write_array(env, term, out),
            TUPLE => write_object(env, tuple(env, term)?, out),
            ATOM => {
                let mut name = [0 as c_char; 8];
                (enif_get_atom(env, term, name.as_mut_ptr(), 8, 1) > 0).then_some(())?;
                let text = std::ffi::CStr::from_ptr(name.as_ptr()).to_bytes();
                matches!(text, b"true" | b"false" | b"null").then(|| out.extend_from_slice(text))
            }
            _ => None,
        }
    }
}

unsafe fn tuple<'a>(env: *mut Env, term: Term) -> Option<&'a [Term]> {
    let mut arity: c_int = 0;
    let mut elements: *const Term = std::ptr::null();
    unsafe {
        (enif_get_tuple(env, term, &raw mut arity, &raw mut elements) != 0).then_some(())?;
        Some(std::slice::from_raw_parts(
            elements,
            usize::try_from(arity).ok()?,
        ))
    }
}

unsafe fn write_array(env: *mut Env, list: Term, out: &mut Vec<u8>) -> Option<()> {
    out.push(b'[');
    let (mut item, mut rest) = (0, list);
    let mut first = true;
    while unsafe { enif_get_list_cell(env, rest, &raw mut item, &raw mut rest) } != 0 {
        if !first {
            out.push(b',');
        }
        first = false;
        unsafe { write(env, item, out)? };
    }
    out.push(b']');
    Some(())
}

unsafe fn write_object(env: *mut Env, fields: &[Term], out: &mut Vec<u8>) -> Option<()> {
    let [pairs] = fields else { return None };
    out.push(b'{');
    let mut rest = *pairs;
    let mut pair: Term = 0;
    let mut first = true;
    while unsafe { enif_get_list_cell(env, rest, &raw mut pair, &raw mut rest) } != 0 {
        let pair = unsafe { tuple(env, pair)? };
        let [key, value] = pair else { return None };
        if !first {
            out.push(b',');
        }
        first = false;
        unsafe {
            write_string(env, *key, out)?;
            out.push(b':');
            write(env, *value, out)?;
        }
    }
    out.push(b'}');
    Some(())
}

unsafe fn write_string(env: *mut Env, term: Term, out: &mut Vec<u8>) -> Option<()> {
    let text = unsafe { bytes(env, term)? };
    out.push(b'"');
    for &byte in text {
        match byte {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            0..0x20 => out.extend_from_slice(format!("\\u{byte:04x}").as_bytes()),
            _ => out.push(byte),
        }
    }
    out.push(b'"');
    Some(())
}

fn write_number(value: f64, out: &mut Vec<u8>) {
    #[allow(clippy::cast_possible_truncation)]
    if value.fract() == 0.0 && value.abs() < 1e15 {
        out.extend_from_slice(itoa::Buffer::new().format(value as i64).as_bytes());
    } else {
        out.extend_from_slice(ryu::Buffer::new().format_finite(value).as_bytes());
    }
}
