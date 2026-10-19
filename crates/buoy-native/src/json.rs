//! `JSON.parse` without a reviver (ECMA-262 25.5.1), straight into the heap records of the
//! engine (sections 17.1 and 17.2 of the contract).
//!
//! The parser reads the code units of an engine string: one byte each, or two bytes each,
//! big-endian, for `{'$u16', Bytes}`. It has no recursion: a stack holds the open objects
//! and arrays, so a time slice can end anywhere and the next call resumes there. An object
//! or an array takes the next heap id when it opens, and gets its record when it closes:
//! `{object, ObjectProto, Props, Keys, #{}, none}` or
//! `{array, ArrayProto, #{}, [], #{}, {Length, Elements}}`. Each call returns the records
//! that it closed, and `buoy_heap:adopt/2` stores them under their ids.
//!
//! `JavaScriptCore`'s `LiteralParser`, which Bun runs, makes the same three choices: it
//! reads 8-bit text without widening it, it makes a string without escapes from its span
//! of the source in one copy, and it caches the keys it has made, so an array of records
//! shares one term for each key. Text that is not JSON gives `error`, and so does a
//! document too large for the native stacks (`MAX_PENDING`). The Erlang parser of
//! `buoy_ref_json` then reads it again: it throws the `SyntaxError` with V8's message, so
//! the messages have one source, or it parses the document under the memory limit of the
//! process.

use std::borrow::Cow;
use std::collections::HashMap;
use std::hash::{BuildHasherDefault, Hasher};
use std::sync::Mutex;

use memchr::memchr2;
use rustler::types::tuple::make_tuple;
use rustler::{Binary, Encoder, Env, NewBinary, NifResult, ResourceArc, Term};

use crate::slice::Slice;

mod atoms {
    rustler::atoms! {
        done, more, error, object, array, none, null,
        object_tag = "$o",
        two_byte = "$u16",
        infinity = "Infinity",
        minus_infinity = "-Infinity",
    }
}

/// The largest array index, 2^32 - 2.
const MAX_INDEX: u64 = 4_294_967_294;

/// The largest integer that the engine keeps as an integer, 2^53 (section 17.1).
const MAX_SAFE: f64 = 9_007_199_254_740_992.0;

/// A parse between two calls.
#[derive(Debug)]
pub struct Parse(Mutex<Parser>);

#[rustler::resource_impl]
impl rustler::Resource for Parse {}

/// `json_parse(Text, Wide, {ObjectProto, ArrayProto}, Next, State)`: parses the code units
/// `Text`, two bytes each when `Wide`, giving the objects the ids from `Next` on. `State`
/// is `start` or the state of a `more` result. The result is
/// `{done, Value, Ids, Records, Next}`, `{more, State, Ids, Records, Next}`, or `error`:
/// `Records` holds the record of each id of `Ids`.
#[rustler::nif]
fn json_parse<'a>(
    env: Env<'a>,
    text: Binary<'a>,
    wide: bool,
    protos: (Term<'a>, Term<'a>),
    next: u64,
    state: Term<'a>,
) -> NifResult<Term<'a>> {
    let mut parser = match state.decode::<ResourceArc<Parse>>() {
        Ok(resource) => {
            let mut held = resource.0.lock().map_err(|_| rustler::Error::BadArg)?;
            std::mem::take(&mut *held)
        }
        Err(_) => Parser::new(next),
    };
    let mut out = Out::new(env, protos);
    let mut slice = Slice::new();
    let bytes = text.as_slice();
    let step = if wide {
        parser.run(&Wide(bytes), &mut out, &mut slice)
    } else {
        parser.run(&Narrow(bytes), &mut out, &mut slice)
    };
    let ids = out.ids.encode(env);
    let records = out.records.encode(env);
    match step {
        Err(Fallback) => Ok(atoms::error().encode(env)),
        Ok(Progress::Done(root)) => {
            let value = if wide {
                value_term(&Wide(bytes), &out, &root)
            } else {
                value_term(&Narrow(bytes), &out, &root)
            };
            Ok((atoms::done(), value, ids, records, parser.next).encode(env))
        }
        Ok(Progress::Paused) => {
            let next = parser.next;
            let resource = ResourceArc::new(Parse(Mutex::new(parser)));
            Ok((atoms::more(), resource, ids, records, next).encode(env))
        }
    }
}

/// Text for the Erlang parser: text that is not JSON, or a document that keeps more than
/// `MAX_PENDING` values open, whose native copies the heap limit of the process cannot
/// see.
#[derive(Debug)]
struct Fallback;

/// The most keys and values that the open objects and arrays may hold at once, about
/// 400 MB of native memory.
const MAX_PENDING: usize = 16_000_000;

#[derive(Debug)]
enum Progress {
    Done(Value),
    Paused,
}

/// A value whose term is not made yet.
#[derive(Debug)]
enum Value {
    Null,
    True,
    False,
    Int(i64),
    Float(f64),
    Infinity,
    MinusInfinity,
    Text(Text),
    Object(u64),
}

/// A string: the span of the text between two quotes when it has no escape, else its
/// code units.
#[derive(Debug)]
enum Text {
    Span(usize, usize),
    Units(Vec<u16>),
}

/// An open object or array. Its keys and values so far are the ends of the stacks of the
/// parser, from `keys` and `values` on, so a value costs no allocation of its own.
#[derive(Debug, Clone, Copy)]
struct Frame {
    id: u64,
    is_object: bool,
    keys: usize,
    values: usize,
}

/// What the grammar allows at the position.
#[derive(Debug, Default, Clone, Copy)]
enum Expect {
    #[default]
    Value,
    FirstKey,
    Key,
    Colon,
    FirstItem,
    Next,
    End,
}

#[derive(Debug, Default)]
struct Parser {
    at: usize,
    expect: Expect,
    frames: Vec<Frame>,
    keys: Vec<Text>,
    values: Vec<Value>,
    root: Option<Value>,
    next: u64,
}

impl Parser {
    fn new(next: u64) -> Self {
        Self {
            next,
            ..Self::default()
        }
    }

    fn run<'a, U: Units<'a>>(
        &mut self,
        input: &U,
        out: &mut Out<'a>,
        slice: &mut Slice,
    ) -> Result<Progress, Fallback> {
        loop {
            let before = self.at;
            if let Some(root) = self.step(input, out)? {
                return Ok(Progress::Done(root));
            }
            if self.values.len() + self.keys.len() > MAX_PENDING {
                return Err(Fallback);
            }
            if slice.is_over(out.env, self.at - before + 1) {
                return Ok(Progress::Paused);
            }
        }
    }

    /// One token. The root value once the text ends.
    fn step<'a, U: Units<'a>>(
        &mut self,
        input: &U,
        out: &mut Out<'a>,
    ) -> Result<Option<Value>, Fallback> {
        self.skip_space(input);
        let unit = input.at(self.at);
        match (self.expect, unit) {
            (Expect::End, None) => return self.root.take().map(Some).ok_or(Fallback),
            (Expect::Value, Some(unit)) => self.value(input, unit)?,
            (Expect::FirstKey, Some(0x7D)) | (Expect::FirstItem, Some(0x5D)) => {
                self.at += 1;
                self.close(input, out);
            }
            (Expect::FirstKey | Expect::Key, Some(0x22)) => {
                self.at += 1;
                let key = self.string(input)?;
                self.keys.push(key);
                self.expect = Expect::Colon;
            }
            (Expect::Colon, Some(0x3A)) => {
                self.at += 1;
                self.expect = Expect::Value;
            }
            (Expect::FirstItem, Some(_)) => self.expect = Expect::Value,
            (Expect::Next, Some(unit)) => self.after_member(input, out, unit)?,
            (Expect::End | Expect::FirstKey | Expect::Key | Expect::Colon, Some(_)) | (_, None) => {
                return Err(Fallback);
            }
        }
        Ok(None)
    }

    fn value<'a, U: Units<'a>>(&mut self, input: &U, unit: u16) -> Result<(), Fallback> {
        let value = match unit {
            0x7B | 0x5B => {
                self.at += 1;
                let is_object = unit == 0x7B;
                self.frames.push(Frame {
                    id: self.next,
                    is_object,
                    keys: self.keys.len(),
                    values: self.values.len(),
                });
                self.next += 1;
                self.expect = if is_object {
                    Expect::FirstKey
                } else {
                    Expect::FirstItem
                };
                return Ok(());
            }
            0x22 => {
                self.at += 1;
                Value::Text(self.string(input)?)
            }
            0x74 => self.word(input, b"true", Value::True)?,
            0x66 => self.word(input, b"false", Value::False)?,
            0x6E => self.word(input, b"null", Value::Null)?,
            0x2D | 0x30..=0x39 => self.number(input)?,
            _ => return Err(Fallback),
        };
        self.complete(value);
        Ok(())
    }

    /// A comma or the end of the open object or array.
    fn after_member<'a, U: Units<'a>>(
        &mut self,
        input: &U,
        out: &mut Out<'a>,
        unit: u16,
    ) -> Result<(), Fallback> {
        let is_object = self.frames.last().is_some_and(|frame| frame.is_object);
        match (unit, is_object) {
            (0x2C, true) => self.expect = Expect::Key,
            (0x2C, false) => self.expect = Expect::Value,
            (0x7D, true) | (0x5D, false) => {
                self.at += 1;
                self.close(input, out);
                return Ok(());
            }
            _ => return Err(Fallback),
        }
        self.at += 1;
        Ok(())
    }

    /// Puts a finished value into the open object or array, or makes it the root.
    fn complete(&mut self, value: Value) {
        if self.frames.is_empty() {
            self.root = Some(value);
            self.expect = Expect::End;
        } else {
            self.values.push(value);
            self.expect = Expect::Next;
        }
    }

    /// Ends the open object or array: makes its record and completes its value.
    fn close<'a, U: Units<'a>>(&mut self, input: &U, out: &mut Out<'a>) {
        let Some(frame) = self.frames.pop() else {
            return;
        };
        let values = &self.values[frame.values..];
        if frame.is_object {
            out.object(input, frame.id, &self.keys[frame.keys..], values);
            self.keys.truncate(frame.keys);
        } else {
            out.array(input, frame.id, values);
        }
        self.values.truncate(frame.values);
        self.complete(Value::Object(frame.id));
    }

    fn skip_space<'a, U: Units<'a>>(&mut self, input: &U) {
        while let Some(0x20 | 0x09 | 0x0A | 0x0D) = input.at(self.at) {
            self.at += 1;
        }
    }

    fn word<'a, U: Units<'a>>(
        &mut self,
        input: &U,
        word: &[u8],
        value: Value,
    ) -> Result<Value, Fallback> {
        let matches = word
            .iter()
            .enumerate()
            .all(|(offset, &byte)| input.at(self.at + offset) == Some(u16::from(byte)));
        if !matches {
            return Err(Fallback);
        }
        self.at += word.len();
        Ok(value)
    }

    /// A string after its opening quote, up to and past its closing quote.
    fn string<'a, U: Units<'a>>(&mut self, input: &U) -> Result<Text, Fallback> {
        let start = self.at;
        if let Some(end) = input.plain_string(start) {
            self.at = end + 1;
            return Ok(Text::Span(start, end));
        }
        let mut units = Vec::new();
        let mut at = start;
        loop {
            match input.at(at).ok_or(Fallback)? {
                0x22 => {
                    self.at = at + 1;
                    return Ok(Text::Units(units));
                }
                0x5C => {
                    let (unit, length) = escape(input, at + 1)?;
                    units.push(unit);
                    at += 1 + length;
                }
                unit if unit < 0x20 => return Err(Fallback),
                unit => {
                    units.push(unit);
                    at += 1;
                }
            }
        }
    }

    /// -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?
    fn number<'a, U: Units<'a>>(&mut self, input: &U) -> Result<Value, Fallback> {
        let start = self.at;
        let negative = input.at(start) == Some(0x2D);
        let first = start + usize::from(negative);
        let digits_end = match input.at(first) {
            Some(0x30) => first + 1,
            Some(0x31..=0x39) => digits(input, first),
            _ => return Err(Fallback),
        };
        let mut end = digits_end;
        if input.at(end) == Some(0x2E) {
            end = some_digits(input, end + 1)?;
        }
        if let Some(0x65 | 0x45) = input.at(end) {
            let sign = usize::from(matches!(input.at(end + 1), Some(0x2B | 0x2D)));
            end = some_digits(input, end + 1 + sign)?;
        }
        self.at = end;
        if end == digits_end && digits_end - first <= 15 {
            let magnitude = (first..digits_end)
                .filter_map(|at| input.at(at))
                .fold(0_i64, |acc, unit| acc * 10 + i64::from(unit - 0x30));
            return Ok(match (negative, magnitude) {
                (true, 0) => Value::Float(-0.0),
                (true, magnitude) => Value::Int(-magnitude),
                (false, magnitude) => Value::Int(magnitude),
            });
        }
        let number: f64 = input.ascii(start, end).parse().map_err(|_| Fallback)?;
        Ok(canonical(number))
    }
}

/// The number value of a double in the form of section 17.1: an integer for an integral
/// value up to 2^53, an atom for an infinity, else a float.
fn canonical(number: f64) -> Value {
    if number.is_infinite() {
        return if number > 0.0 {
            Value::Infinity
        } else {
            Value::MinusInfinity
        };
    }
    if number.fract() == 0.0
        && number.abs() <= MAX_SAFE
        && !(number == 0.0 && number.is_sign_negative())
    {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "an integral double up to 2^53 is exactly an i64"
        )]
        return Value::Int(number as i64);
    }
    Value::Float(number)
}

/// The end of a run of digits from `at`.
fn digits<'a, U: Units<'a>>(input: &U, mut at: usize) -> usize {
    while let Some(0x30..=0x39) = input.at(at) {
        at += 1;
    }
    at
}

/// The end of a run of at least one digit from `at`.
fn some_digits<'a, U: Units<'a>>(input: &U, at: usize) -> Result<usize, Fallback> {
    let end = digits(input, at);
    if end == at { Err(Fallback) } else { Ok(end) }
}

/// The code unit of the escape after a backslash at `at`, and the units it takes.
fn escape<'a, U: Units<'a>>(input: &U, at: usize) -> Result<(u16, usize), Fallback> {
    let unit = match input.at(at).ok_or(Fallback)? {
        0x22 => 0x22,
        0x5C => 0x5C,
        0x2F => 0x2F,
        0x62 => 0x08,
        0x66 => 0x0C,
        0x6E => 0x0A,
        0x72 => 0x0D,
        0x74 => 0x09,
        0x75 => {
            let unit = (1..=4).try_fold(0_u16, |acc, offset| {
                let digit = input
                    .at(at + offset)
                    .and_then(|unit| char::from_u32(u32::from(unit)))?;
                let value = u16::try_from(digit.to_digit(16)?).ok()?;
                Some(acc * 16 + value)
            });
            return unit.map(|unit| (unit, 5)).ok_or(Fallback);
        }
        _ => return Err(Fallback),
    };
    Ok((unit, 1))
}

/// The code units of the text.
trait Units<'a> {
    fn at(&self, index: usize) -> Option<u16>;
    /// The index of the closing quote of a string from `from` that has no escape and no
    /// control character.
    fn plain_string(&self, from: usize) -> Option<usize>;
    /// The bytes of the units from `start` to `end`, a key of the key cache.
    fn bytes(&self, start: usize, end: usize) -> &'a [u8];
    /// The units from `start` to `end`, which are ASCII, as text.
    fn ascii(&self, start: usize, end: usize) -> Cow<'a, str>;
    /// The string of the units from `start` to `end`.
    fn string(&self, env: Env<'a>, start: usize, end: usize) -> Term<'a>;
}

/// One byte for each code unit.
struct Narrow<'a>(&'a [u8]);

/// Two bytes for each code unit, big-endian.
struct Wide<'a>(&'a [u8]);

impl<'a> Units<'a> for Narrow<'a> {
    fn at(&self, index: usize) -> Option<u16> {
        self.0.get(index).copied().map(u16::from)
    }

    fn plain_string(&self, from: usize) -> Option<usize> {
        let rest = self.0.get(from..)?;
        let end = memchr2(b'"', b'\\', rest)?;
        (rest[end] == b'"' && !rest[..end].iter().any(|&byte| byte < 0x20)).then_some(from + end)
    }

    fn bytes(&self, start: usize, end: usize) -> &'a [u8] {
        &self.0[start..end]
    }

    fn ascii(&self, start: usize, end: usize) -> Cow<'a, str> {
        String::from_utf8_lossy(&self.0[start..end])
    }

    fn string(&self, env: Env<'a>, start: usize, end: usize) -> Term<'a> {
        NewBinary::from_slice(env, &self.0[start..end]).into()
    }
}

impl<'a> Units<'a> for Wide<'a> {
    fn at(&self, index: usize) -> Option<u16> {
        let pair = self.0.get(2 * index..2 * index + 2)?;
        Some(u16::from_be_bytes([pair[0], pair[1]]))
    }

    fn plain_string(&self, from: usize) -> Option<usize> {
        let mut at = from;
        loop {
            match self.at(at)? {
                0x22 => return Some(at),
                0x5C => return None,
                unit if unit < 0x20 => return None,
                _ => at += 1,
            }
        }
    }

    fn bytes(&self, start: usize, end: usize) -> &'a [u8] {
        &self.0[2 * start..2 * end]
    }

    fn ascii(&self, start: usize, end: usize) -> Cow<'a, str> {
        (start..end)
            .filter_map(|at| self.at(at))
            .filter_map(|unit| char::from_u32(u32::from(unit)))
            .collect::<String>()
            .into()
    }

    fn string(&self, env: Env<'a>, start: usize, end: usize) -> Term<'a> {
        let bytes = self.bytes(start, end);
        let (pairs, _) = bytes.as_chunks::<2>();
        if pairs.iter().all(|pair| pair[0] == 0) {
            let narrow = pairs.iter().map(|pair| pair[1]);
            return NewBinary::from_iter(env, narrow).into();
        }
        two_byte(env, NewBinary::from_slice(env, bytes).into())
    }
}

/// The string of code units that an escape made.
fn units_string<'a>(env: Env<'a>, units: &[u16]) -> Term<'a> {
    if units.iter().all(|&unit| unit <= 0xFF) {
        let narrow = units.iter().map(|&unit| unit.to_be_bytes()[1]);
        return NewBinary::from_iter(env, narrow).into();
    }
    let mut bytes = NewBinary::new(env, 2 * units.len());
    for (pair, unit) in bytes
        .as_mut_slice()
        .as_chunks_mut::<2>()
        .0
        .iter_mut()
        .zip(units)
    {
        pair.copy_from_slice(&unit.to_be_bytes());
    }
    two_byte(env, bytes.into())
}

fn two_byte<'a>(env: Env<'a>, bytes: Term<'a>) -> Term<'a> {
    make_tuple(env, &[atoms::two_byte().encode(env), bytes])
}

/// The terms that one call makes.
struct Out<'a> {
    env: Env<'a>,
    object_proto: Term<'a>,
    array_proto: Term<'a>,
    /// The ids of the objects and arrays that the call closed, and their records.
    ids: Vec<u64>,
    records: Vec<Term<'a>>,
    /// Each key that the call has made from a span, by its bytes, and whether it is an
    /// array index.
    keys: HashMap<&'a [u8], (Term<'a>, bool), BuildHasherDefault<Fnv>>,
    /// Buffers that each record reuses.
    key_terms: Vec<Term<'a>>,
    value_terms: Vec<Term<'a>>,
    is_index: Vec<bool>,
}

impl<'a> Out<'a> {
    fn new(env: Env<'a>, (object_proto, array_proto): (Term<'a>, Term<'a>)) -> Self {
        Self {
            env,
            object_proto,
            array_proto,
            ids: Vec::new(),
            records: Vec::new(),
            keys: HashMap::default(),
            key_terms: Vec::new(),
            value_terms: Vec::new(),
            is_index: Vec::new(),
        }
    }

    /// `{object, Proto, Props, Keys, #{}, none}`. A repeated key keeps its first position
    /// and its last value, as `CreateDataProperty` does.
    fn object<U: Units<'a>>(&mut self, input: &U, id: u64, keys: &[Text], values: &[Value]) {
        let env = self.env;
        let mut key_terms = std::mem::take(&mut self.key_terms);
        let mut value_terms = std::mem::take(&mut self.value_terms);
        let mut is_index = std::mem::take(&mut self.is_index);
        for (key, value) in keys.iter().zip(values) {
            let (term, index) = self.key(input, key);
            key_terms.push(term);
            is_index.push(index);
            value_terms.push(value_term(input, self, value));
        }
        let (props, order) = match Term::map_from_term_arrays(env, &key_terms, &value_terms) {
            Ok(props) => {
                let order = key_terms
                    .iter()
                    .zip(&is_index)
                    .filter(|(_, index)| !**index)
                    .fold(Term::list_new_empty(env), |order, (key, _)| {
                        order.list_prepend(*key)
                    });
                (props, order)
            }
            Err(_) => repeated_keys(env, &key_terms, &is_index, &value_terms),
        };
        let record = make_tuple(
            env,
            &[
                atoms::object().encode(env),
                self.object_proto,
                props,
                order,
                Term::map_new(env),
                atoms::none().encode(env),
            ],
        );
        key_terms.clear();
        value_terms.clear();
        is_index.clear();
        self.key_terms = key_terms;
        self.value_terms = value_terms;
        self.is_index = is_index;
        self.ids.push(id);
        self.records.push(record);
    }

    /// `{array, Proto, #{}, [], #{}, {Length, Elements}}`.
    fn array<U: Units<'a>>(&mut self, input: &U, id: u64, items: &[Value]) {
        let env = self.env;
        let mut key_terms = std::mem::take(&mut self.key_terms);
        let mut value_terms = std::mem::take(&mut self.value_terms);
        key_terms.extend((0..items.len()).map(|index| index.encode(env)));
        value_terms.extend(items.iter().map(|item| value_term(input, self, item)));
        let elements = Term::map_from_term_arrays(env, &key_terms, &value_terms)
            .unwrap_or_else(|_| Term::map_new(env));
        let record = make_tuple(
            env,
            &[
                atoms::array().encode(env),
                self.array_proto,
                Term::map_new(env),
                Term::list_new_empty(env),
                Term::map_new(env),
                (items.len(), elements).encode(env),
            ],
        );
        key_terms.clear();
        value_terms.clear();
        self.key_terms = key_terms;
        self.value_terms = value_terms;
        self.ids.push(id);
        self.records.push(record);
    }

    /// The property key of a string: an array index as an integer, else the string.
    fn key<U: Units<'a>>(&mut self, input: &U, key: &Text) -> (Term<'a>, bool) {
        match key {
            Text::Span(start, end) => {
                let bytes = input.bytes(*start, *end);
                if let Some(cached) = self.keys.get(bytes) {
                    return *cached;
                }
                let units: Vec<u16> = (*start..*end).filter_map(|at| input.at(at)).collect();
                let made = array_index(&units).map_or_else(
                    || (input.string(self.env, *start, *end), false),
                    |index| (index.encode(self.env), true),
                );
                self.keys.insert(bytes, made);
                made
            }
            Text::Units(units) => array_index(units).map_or_else(
                || (units_string(self.env, units), false),
                |index| (index.encode(self.env), true),
            ),
        }
    }
}

/// FNV-1a, a fast hash for the short keys of the key cache.
#[derive(Debug)]
struct Fnv(u64);

impl Default for Fnv {
    fn default() -> Self {
        Self(0xcbf2_9ce4_8422_2325)
    }
}

impl Hasher for Fnv {
    fn finish(&self) -> u64 {
        self.0
    }

    fn write(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 = (self.0 ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3);
        }
    }
}

/// Props and Keys of an object whose text repeats a key.
fn repeated_keys<'a>(
    env: Env<'a>,
    keys: &[Term<'a>],
    indexes: &[bool],
    values: &[Term<'a>],
) -> (Term<'a>, Term<'a>) {
    let mut props = Term::map_new(env);
    let mut order = Term::list_new_empty(env);
    for ((key, is_index), value) in keys.iter().zip(indexes).zip(values) {
        if !is_index && props.map_get(*key).is_err() {
            order = order.list_prepend(*key);
        }
        props = props.map_put(*key, *value).unwrap_or(props);
    }
    (props, order)
}

/// The array index that a key names: a canonical decimal integer up to 2^32 - 2.
fn array_index(units: &[u16]) -> Option<u64> {
    let canonical = matches!(units, [0x30] | [0x31..=0x39, ..]) && units.len() <= 10;
    if !canonical {
        return None;
    }
    let index = units.iter().try_fold(0_u64, |acc, &unit| {
        (0x30..=0x39)
            .contains(&unit)
            .then(|| acc * 10 + u64::from(unit - 0x30))
    })?;
    (index <= MAX_INDEX).then_some(index)
}

fn value_term<'a, U: Units<'a>>(input: &U, out: &Out<'a>, value: &Value) -> Term<'a> {
    let env = out.env;
    match value {
        Value::Null => atoms::null().encode(env),
        Value::True => true.encode(env),
        Value::False => false.encode(env),
        Value::Int(number) => number.encode(env),
        Value::Float(number) => number.encode(env),
        Value::Infinity => atoms::infinity().encode(env),
        Value::MinusInfinity => atoms::minus_infinity().encode(env),
        Value::Text(Text::Span(start, end)) => input.string(env, *start, *end),
        Value::Text(Text::Units(units)) => units_string(env, units),
        Value::Object(id) => make_tuple(env, &[atoms::object_tag().encode(env), id.encode(env)]),
    }
}
