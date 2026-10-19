//! The NIFs of `buoy_native.erl`: one resource for each handle of
//! `internalBinding('zlib')`, and the calls of Node's `CompressionStream` on it.

// rustler decodes each argument of a NIF by value.
#![allow(clippy::needless_pass_by_value)]

use std::sync::{Mutex, MutexGuard};

use rustler::{Binary, Env, Error, NifResult, OwnedBinary, ResourceArc};

use crate::{Failure, brotli, intl, zlib, zstd};

/// The context of one handle of `internalBinding('zlib')`.
#[derive(Debug)]
enum Codec {
    Zlib(zlib::Context),
    BrotliEncoder(Box<brotli::Encoder>),
    BrotliDecoder(Box<brotli::Decoder>),
    ZstdCompressor(zstd::Compressor),
    ZstdDecompressor(zstd::Decompressor),
    Closed,
}

impl Codec {
    /// One write of `CompressionStream::Write`: the bytes read and written.
    fn write(&mut self, flush: u32, input: &[u8], output: &mut [u8]) -> (usize, usize) {
        match self {
            Self::Zlib(context) => context.write(i32::try_from(flush).unwrap_or(0), input, output),
            Self::BrotliEncoder(encoder) => encoder.write(flush, input, output),
            Self::BrotliDecoder(decoder) => decoder.write(flush, input, output),
            Self::ZstdCompressor(compressor) => compressor.write(flush, input, output),
            Self::ZstdDecompressor(decompressor) => decompressor.write(input, output),
            Self::Closed => (0, 0),
        }
    }

    /// `GetErrorInfo` after a write.
    fn failure(&self) -> Option<Failure> {
        match self {
            Self::Zlib(context) => context.failure(),
            Self::BrotliEncoder(encoder) => encoder.failure(),
            Self::BrotliDecoder(decoder) => decoder.failure(),
            Self::ZstdCompressor(compressor) => compressor.failure(),
            Self::ZstdDecompressor(decompressor) => decompressor.failure(),
            Self::Closed => None,
        }
    }

    fn set_parameter(&mut self, key: u32, value: u32) -> Result<(), Failure> {
        match self {
            Self::BrotliEncoder(encoder) => encoder.set_parameter(key, value),
            Self::BrotliDecoder(decoder) => decoder.set_parameter(key, value),
            Self::ZstdCompressor(compressor) => compressor.set_parameter(key, value),
            Self::ZstdDecompressor(decompressor) => decompressor.set_parameter(key, value),
            Self::Zlib(_) | Self::Closed => Ok(()),
        }
    }

    fn reset(&mut self) -> Result<(), Failure> {
        match self {
            Self::Zlib(context) => context.reset(),
            Self::BrotliEncoder(encoder) => {
                encoder.reset();
                Ok(())
            }
            Self::BrotliDecoder(decoder) => {
                decoder.reset();
                Ok(())
            }
            Self::ZstdCompressor(compressor) => compressor.reset(),
            Self::ZstdDecompressor(decompressor) => decompressor.reset(),
            Self::Closed => Ok(()),
        }
    }
}

/// A handle's context. Each call holds the lock, so a context never runs on two
/// schedulers at once.
struct Stream(Mutex<Codec>);

#[rustler::resource_impl]
impl rustler::Resource for Stream {}

impl Stream {
    fn open(codec: Codec) -> ResourceArc<Self> {
        ResourceArc::new(Self(Mutex::new(codec)))
    }

    /// The context, unless a panic in an earlier call left it inconsistent.
    fn codec(&self) -> NifResult<MutexGuard<'_, Codec>> {
        self.0.lock().map_err(|_| Error::RaiseAtom("poisoned"))
    }
}

type Outcome = Option<(String, i32, String)>;

fn outcome(result: Result<(), Failure>) -> Outcome {
    result.err().map(Failure::term)
}

/// A zlib stream in the `node_zlib_mode` `mode`, with the parameters of
/// `ZlibContext::Init`.
#[rustler::nif]
fn zlib_open(
    mode: i32,
    level: i32,
    window_bits: i32,
    mem_level: i32,
    strategy: i32,
    dictionary: Binary,
) -> NifResult<ResourceArc<Stream>> {
    let mode = zlib::Mode::from_node(mode).ok_or(Error::BadArg)?;
    let mut context = zlib::Context::new(mode);
    context.init(
        level,
        window_bits,
        mem_level,
        strategy,
        dictionary.as_slice().to_vec(),
    );
    Ok(Stream::open(Codec::Zlib(context)))
}

/// A brotli encoder or decoder with an optional raw dictionary.
#[rustler::nif]
fn brotli_open(encode: bool, dictionary: Binary) -> ResourceArc<Stream> {
    Stream::open(if encode {
        Codec::BrotliEncoder(Box::new(brotli::Encoder::new(
            dictionary.as_slice().to_vec(),
        )))
    } else {
        Codec::BrotliDecoder(Box::new(brotli::Decoder::new(dictionary.as_slice())))
    })
}

/// A zstd compressor with the pledged source size, -1 for none, or a decompressor.
#[rustler::nif]
fn zstd_open(
    compress: bool,
    pledged_src_size: i64,
    dictionary: Binary,
) -> Result<ResourceArc<Stream>, (String, i32, String)> {
    let codec = if compress {
        let pledged = u64::try_from(pledged_src_size).unwrap_or(zstd::CONTENT_SIZE_UNKNOWN);
        zstd::Compressor::new(pledged, dictionary.as_slice()).map(Codec::ZstdCompressor)
    } else {
        zstd::Decompressor::new(dictionary.as_slice()).map(Codec::ZstdDecompressor)
    };
    codec.map(Stream::open).map_err(Failure::term)
}

/// `SetParams` of brotli or `SetParameter` of zstd: `nil`, or the failure.
#[rustler::nif]
fn stream_set_parameter(stream: ResourceArc<Stream>, key: u32, value: u32) -> NifResult<Outcome> {
    Ok(outcome(stream.codec()?.set_parameter(key, value)))
}

/// One write: `{Output, AvailIn, AvailOut, nil | {Message, Errno, Code}}`, where Output
/// holds the bytes written into `out_len` bytes of room.
#[rustler::nif(schedule = "DirtyCpu")]
fn stream_write<'a>(
    env: Env<'a>,
    stream: ResourceArc<Stream>,
    flush: u32,
    input: Binary<'a>,
    out_len: u32,
) -> NifResult<(Binary<'a>, u32, u32, Outcome)> {
    let room = usize::try_from(out_len).map_err(|_| Error::BadArg)?;
    let mut output = OwnedBinary::new(room);
    // The codecs only write the output, but a slice of uninitialized bytes is undefined.
    output.as_mut_slice().fill(0);
    let mut codec = stream.codec()?;
    let (read, written) = codec.write(flush, input.as_slice(), output.as_mut_slice());
    let failure = codec.failure().map(Failure::term);
    drop(codec);
    if written < room && !output.realloc(written) {
        return Err(Error::RaiseAtom("enomem"));
    }
    let left = |total: usize, used: usize| u32::try_from(total - used).unwrap_or(u32::MAX);
    Ok((
        output.release(env),
        left(input.len(), read),
        left(room, written),
        failure,
    ))
}

/// `ZlibContext::SetParams`: `nil`, or the failure.
#[rustler::nif]
fn stream_params(stream: ResourceArc<Stream>, level: i32, strategy: i32) -> NifResult<Outcome> {
    let mut codec = stream.codec()?;
    Ok(match &mut *codec {
        Codec::Zlib(context) => outcome(context.params(level, strategy)),
        _ => None,
    })
}

/// `ResetStream`: `nil`, or the failure.
#[rustler::nif]
fn stream_reset(stream: ResourceArc<Stream>) -> NifResult<Outcome> {
    Ok(outcome(stream.codec()?.reset()))
}

/// Frees the context; the handle stays, closed.
#[rustler::nif]
fn stream_close(stream: ResourceArc<Stream>) -> NifResult<bool> {
    *stream.codec()? = Codec::Closed;
    Ok(true)
}

/// `Intl`: the canonical form of a locale tag, or `nil` for an invalid tag.
#[rustler::nif]
fn intl_canonicalize(tag: &str) -> Option<String> {
    intl::canonicalize(tag)
}

/// `Intl.Locale.prototype.maximize` of a canonical tag.
#[rustler::nif]
fn intl_maximize(tag: &str) -> Option<String> {
    intl::maximize(tag)
}

/// `Intl.Locale.prototype.minimize` of a canonical tag.
#[rustler::nif]
fn intl_minimize(tag: &str) -> Option<String> {
    intl::minimize(tag)
}

/// Whether the locale writes right to left (`Intl.Locale.prototype.getTextInfo`), or `nil`
/// when its script has no direction.
#[rustler::nif]
fn intl_is_right_to_left(tag: &str) -> Option<bool> {
    intl::is_right_to_left(tag)
}

/// An `Intl.Collator`: ICU4X's collator with the resolved options of the object.
struct IntlCollator(icu_collator::CollatorBorrowed<'static>);

#[rustler::resource_impl]
impl rustler::Resource for IntlCollator {}

/// The collator of a locale tag with the keywords co, kf, and kn, and a sensitivity of
/// ECMA-402, or `nil` when ICU4X cannot make one.
#[rustler::nif]
fn intl_collator_new(
    tag: &str,
    sensitivity: rustler::Atom,
    ignore_punctuation: bool,
) -> Option<ResourceArc<IntlCollator>> {
    let sensitivity = match () {
        () if sensitivity == atoms::base() => intl::collator::Sensitivity::Base,
        () if sensitivity == atoms::accent() => intl::collator::Sensitivity::Accent,
        () if sensitivity == atoms::case() => intl::collator::Sensitivity::Case,
        () => intl::collator::Sensitivity::Variant,
    };
    intl::collator::new(tag, sensitivity, ignore_punctuation)
        .map(|collator| ResourceArc::new(IntlCollator(collator)))
}

/// `CompareStrings` of two strings of big-endian UTF-16 code units: -1, 0, or 1.
#[rustler::nif]
fn intl_collator_compare(collator: ResourceArc<IntlCollator>, left: Binary, right: Binary) -> i32 {
    let units = |bytes: &[u8]| -> Vec<u16> {
        bytes
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u16::from_be_bytes(*pair))
            .collect()
    };
    match intl::collator::compare(&collator.0, &units(&left), &units(&right)) {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    }
}

/// The collation types of a locale tag (`Intl.Locale.prototype.getCollations`).
#[rustler::nif]
fn intl_collation_types(tag: &str) -> Vec<&'static str> {
    intl::collator::types(tag)
}

/// `toLocaleLowerCase` or `toLocaleUpperCase` of a big-endian UTF-16 binary in the
/// language `tag`.
#[rustler::nif]
fn intl_change_case<'a>(env: Env<'a>, tag: &str, text: Binary, upper: bool) -> Binary<'a> {
    let units: Vec<u16> = text
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| u16::from_be_bytes(*pair))
        .collect();
    let changed = intl::casemap::change_case(tag, &units, upper);
    let mut binary = OwnedBinary::new(changed.len() * 2);
    for (slot, unit) in binary
        .as_mut_slice()
        .as_chunks_mut::<2>()
        .0
        .iter_mut()
        .zip(changed)
    {
        *slot = unit.to_be_bytes();
    }
    binary.release(env)
}

/// The date in a calendar of a day after 1970-01-01: `{Year, Cyclic, OrdinalMonth,
/// MonthNumber, Leap, Day}`, or `nil`.
#[rustler::nif]
fn intl_calendar_date(calendar: &str, epoch_days: i64) -> Option<(i32, u8, u8, u8, bool, u8)> {
    intl::calendar::date(calendar, epoch_days).map(|date| {
        (
            date.year,
            date.cyclic,
            date.ordinal_month,
            date.month_number,
            date.leap,
            date.day,
        )
    })
}

/// The locale data of `scripts/intl-icu.escript`, in the external term format, which
/// `buoy_intl_cldr` decodes once per VM.
#[rustler::nif]
fn intl_cldr(env: Env<'_>) -> Binary<'_> {
    let data = intl::CLDR;
    let mut binary = OwnedBinary::new(data.len());
    binary.as_mut_slice().copy_from_slice(data);
    binary.release(env)
}

/// The boundaries of a big-endian UTF-16 binary for `Intl.Segmenter`: `grapheme`, `word`,
/// or `sentence` in the locale `tag`, as `{Index, IsWordLike}` from 0 to its length.
#[rustler::nif(schedule = "DirtyCpu")]
fn intl_segment(granularity: rustler::Atom, tag: &str, text: Binary) -> Vec<(usize, bool)> {
    use intl::segmenter::Granularity;
    let granularity = match () {
        () if granularity == atoms::word() => Granularity::Word,
        () if granularity == atoms::sentence() => Granularity::Sentence,
        () => Granularity::Grapheme,
    };
    let units: Vec<u16> = text
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| u16::from_be_bytes(*pair))
        .collect();
    intl::segmenter::boundaries(granularity, tag, &units)
}

/// The exponent by which compact notation scales a number of the magnitude in the locale
/// `tag`, short or long (`ComputeExponentForMagnitude` of ECMA-402).
#[rustler::nif]
fn intl_compact_exponent(tag: &str, long: bool, magnitude: i16) -> u8 {
    intl::number::compact_exponent(tag, long, magnitude)
}

mod atoms {
    rustler::atoms! { base, accent, case, word, sentence }
}

#[allow(unsafe_code)]
mod entry {
    // The entry point that erlang:load_nif calls is a `#[no_mangle]` function.
    rustler::init!("buoy_native", load = load);

    fn load(_env: rustler::Env, _info: rustler::Term) -> bool {
        crate::fs::ignore_file_size_signal();
        true
    }
}
