//! Node's `BrotliEncoderContext` and `BrotliDecoderContext` (`src/node_zlib.cc`) on the
//! brotli crates, which port Google's C library to safe Rust.
//!
//! A dictionary is a raw shared dictionary, as `BROTLI_SHARED_DICTIONARY_RAW` attaches it
//! in C. The decoder reads it as a compound dictionary. The encoder places it before the
//! data in its window and stops using the static dictionary, so its streams use only
//! distances that a compound dictionary gives the same meaning.

use brotli::enc::StandardAlloc;
use brotli::enc::encode::{
    BrotliEncoderOperation, BrotliEncoderParameter as Param, BrotliEncoderStateStruct,
};
use brotli::enc::interface::{
    InputPair, InputReferenceMut, PredictionModeContextMap, StaticCommand,
};
use brotli_decompressor::{BrotliResult, BrotliState};

use crate::Failure;

/// The encoder of one stream.
pub struct Encoder {
    state: BrotliEncoderStateStruct<StandardAlloc>,
    dictionary: Vec<u8>,
    /// brotli-rs fixes the parameters when the stream starts, so the encoder starts it,
    /// and takes the dictionary, on its first write, after `init` has set them.
    started: bool,
    /// Whether a block has been encoded, which builds the hasher.
    encoded: bool,
    /// The input that the encoder holds and has not encoded yet.
    pending: usize,
    succeeded: bool,
}

impl std::fmt::Debug for Encoder {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("Encoder").finish_non_exhaustive()
    }
}

impl Encoder {
    /// `BrotliEncoderContext::Init`.
    pub fn new(dictionary: Vec<u8>) -> Self {
        Self {
            state: BrotliEncoderStateStruct::new(StandardAlloc::default()),
            dictionary,
            started: false,
            encoded: false,
            pending: 0,
            succeeded: true,
        }
    }

    /// `BrotliEncoderSetParameter` for a key and value of `BROTLI_PARAM_*`.
    pub fn set_parameter(&mut self, key: u32, value: u32) -> Result<(), Failure> {
        let set = match key {
            7 => {
                self.state.params.dist.distance_postfix_bits = value;
                true
            }
            8 => {
                self.state.params.dist.num_direct_distance_codes = value;
                true
            }
            _ => encoder_parameter(key).is_some_and(|param| self.state.set_parameter(param, value)),
        };
        if set {
            return Ok(());
        }
        Err(Failure::new(
            "Setting parameter failed",
            "ERR_BROTLI_PARAM_SET_FAILED",
            -1,
        ))
    }

    /// `BrotliEncoderCompressStream` with the operation `flush`: the bytes read and
    /// written.
    pub fn write(&mut self, flush: u32, input: &[u8], output: &mut [u8]) -> (usize, usize) {
        let operation = match flush {
            1 => BrotliEncoderOperation::BROTLI_OPERATION_FLUSH,
            2 => BrotliEncoderOperation::BROTLI_OPERATION_FINISH,
            3 => BrotliEncoderOperation::BROTLI_OPERATION_EMIT_METADATA,
            _ => BrotliEncoderOperation::BROTLI_OPERATION_PROCESS,
        };
        if !self.started {
            self.started = true;
            if !self.dictionary.is_empty() {
                self.state
                    .set_custom_dictionary(self.dictionary.len(), &self.dictionary);
                self.encoded = true;
            }
            // Starts the stream with the window of the parameters, which the header
            // records.
            let _ = self.compress(
                BrotliEncoderOperation::BROTLI_OPERATION_PROCESS,
                &[],
                &mut [],
            );
        }
        let pending = self.pending + input.len();
        let block = 1usize << self.state.params.lgblock;
        let (read, written) = match self.one_shot_window(operation, pending) {
            Some(window) => {
                let lgwin = std::mem::replace(&mut self.state.params.lgwin, window);
                let progress = self.compress(operation, input, output);
                self.state.params.lgwin = lgwin;
                progress
            }
            None => self.compress(operation, input, output),
        };
        match operation {
            BrotliEncoderOperation::BROTLI_OPERATION_PROCESS if pending < block => {
                self.pending = pending;
            }
            _ => self.encoded = true,
        }
        (read, written)
    }

    /// The window of the hasher when the first block that the encoder encodes holds all
    /// the input. C brotli then sizes the hasher of quality 10 and 11 for the input,
    /// where brotli-rs sizes it for the window: 32 MiB at the default window. A window
    /// that holds the input gives the same matches, so the encoder builds the hasher with
    /// the smaller window, and the header keeps the window of the parameters.
    fn one_shot_window(&self, operation: BrotliEncoderOperation, pending: usize) -> Option<i32> {
        let BrotliEncoderOperation::BROTLI_OPERATION_FINISH = operation else {
            return None;
        };
        if self.encoded || self.state.params.quality < 10 {
            return None;
        }
        (10..self.state.params.lgwin).find(|bits| (1usize << bits) - 16 >= pending)
    }

    fn compress(
        &mut self,
        operation: BrotliEncoderOperation,
        input: &[u8],
        output: &mut [u8],
    ) -> (usize, usize) {
        let (mut available_in, mut read) = (input.len(), 0);
        let (mut available_out, mut written) = (output.len(), 0);
        let mut ignore_metablocks = |_: &mut PredictionModeContextMap<InputReferenceMut>,
                                     _: &mut [StaticCommand],
                                     _: InputPair,
                                     _: &mut StandardAlloc| ();
        self.succeeded = self.state.compress_stream(
            operation,
            &mut available_in,
            input,
            &mut read,
            &mut available_out,
            output,
            &mut written,
            &mut None,
            &mut ignore_metablocks,
        );
        (read, written)
    }

    /// `BrotliEncoderContext::GetErrorInfo`.
    pub fn failure(&self) -> Option<Failure> {
        (!self.succeeded)
            .then(|| Failure::new("Compression failed", "ERR_BROTLI_COMPRESSION_FAILED", -1))
    }

    /// `BrotliEncoderContext::ResetStream`: as in Node, a new encoder without the
    /// dictionary or the parameters.
    pub fn reset(&mut self) {
        *self = Self::new(Vec::new());
    }
}

/// The parameter of a key of `BROTLI_PARAM_*` that brotli-rs sets itself.
fn encoder_parameter(key: u32) -> Option<Param> {
    Some(match key {
        0 => Param::BROTLI_PARAM_MODE,
        1 => Param::BROTLI_PARAM_QUALITY,
        2 => Param::BROTLI_PARAM_LGWIN,
        3 => Param::BROTLI_PARAM_LGBLOCK,
        4 => Param::BROTLI_PARAM_DISABLE_LITERAL_CONTEXT_MODELING,
        5 => Param::BROTLI_PARAM_SIZE_HINT,
        6 => Param::BROTLI_PARAM_LARGE_WINDOW,
        _ => return None,
    })
}

type DecoderState = BrotliState<StandardAlloc, StandardAlloc, StandardAlloc>;

/// The decoder of one stream.
pub struct Decoder {
    state: DecoderState,
    result: BrotliResult,
    flush: u32,
}

impl std::fmt::Debug for Decoder {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("Decoder").finish_non_exhaustive()
    }
}

impl Decoder {
    /// `BrotliDecoderContext::Init`.
    pub fn new(dictionary: &[u8]) -> Self {
        let alloc = StandardAlloc::default;
        let mut state = if dictionary.is_empty() {
            DecoderState::new(alloc(), alloc(), alloc())
        } else {
            DecoderState::new_with_custom_dictionary(
                alloc(),
                alloc(),
                alloc(),
                dictionary.to_vec().into(),
            )
        };
        // C brotli reads large-window streams only when asked to.
        state.large_window = false;
        Self {
            state,
            result: BrotliResult::NeedsMoreInput,
            flush: 0,
        }
    }

    /// `BrotliDecoderSetParameter` for a key and value of `BROTLI_DECODER_PARAM_*`.
    pub fn set_parameter(&mut self, key: u32, value: u32) -> Result<(), Failure> {
        match key {
            // shortcut: brotli-decompressor 6.0 always grows its ring buffer, which C
            // brotli does by default; the switch to allocate it whole changes no output.
            0 => Ok(()),
            1 => {
                self.state.large_window = value != 0;
                Ok(())
            }
            _ => Err(Failure::new(
                "Setting parameter failed",
                "ERR_BROTLI_PARAM_SET_FAILED",
                -1,
            )),
        }
    }

    /// `BrotliDecoderDecompressStream`: the bytes read and written.
    pub fn write(&mut self, flush: u32, input: &[u8], output: &mut [u8]) -> (usize, usize) {
        self.flush = flush;
        let (mut available_in, mut read) = (input.len(), 0);
        let (mut available_out, mut written) = (output.len(), 0);
        self.result = brotli_decompressor::BrotliDecompressStream(
            &mut available_in,
            &mut read,
            input,
            &mut available_out,
            &mut written,
            output,
            &mut 0,
            &mut self.state,
        );
        (read, written)
    }

    /// `BrotliDecoderContext::GetErrorInfo`.
    pub fn failure(&self) -> Option<Failure> {
        if let BrotliResult::ResultFailure = self.result {
            // `BrotliDecoderErrorString` names a code without its `BROTLI_DECODER` prefix.
            let code = self.state.error_code;
            let name = format!("{code:?}");
            let name = name.strip_prefix("BROTLI_DECODER").unwrap_or(&name);
            return Some(Failure::new(
                "Decompression failed",
                &format!("ERR_{name}"),
                code as i32,
            ));
        }
        if self.flush == 2 && matches!(self.result, BrotliResult::NeedsMoreInput) {
            // Node matches zlib, as brotli has no code of its own for this.
            return Some(Failure::new("unexpected end of file", "Z_BUF_ERROR", -5));
        }
        None
    }

    /// `BrotliDecoderContext::ResetStream`: as in Node, a new decoder without the
    /// dictionary or the parameters.
    pub fn reset(&mut self) {
        *self = Self::new(&[]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(dictionary: &[u8], data: &[u8]) -> Vec<u8> {
        let mut encoder = Encoder::new(dictionary.to_vec());
        let mut compressed = vec![0; data.len() + 1024];
        let (read, written) = encoder.write(2, data, &mut compressed);
        assert_eq!(read, data.len());
        assert!(encoder.failure().is_none());
        let mut decoder = Decoder::new(dictionary);
        let mut plain = vec![0; data.len() + 16];
        let (_, out) = decoder.write(2, &compressed[..written], &mut plain);
        assert!(decoder.failure().is_none());
        plain.truncate(out);
        plain
    }

    #[test]
    fn a_stream_round_trips_with_and_without_a_dictionary() {
        let data =
            b"Lorem ipsum dolor sit amet, consectetur adipiscing elit. Lorem ipsum.".repeat(20);
        assert_eq!(round_trip(&[], &data), data);
        assert_eq!(round_trip(b"Lorem ipsum dolor sit amet", &data), data);
    }

    /// The bytes of brotli-rs for `data`, written in one call or before the call that
    /// finishes, with the hasher of the whole window.
    fn reference(quality: u32, data: &[u8], split: bool) -> Vec<u8> {
        let mut encoder = Encoder::new(Vec::new());
        encoder.set_parameter(1, quality).expect("a quality");
        let mut out = vec![0; data.len() + 1024];
        let finish = BrotliEncoderOperation::BROTLI_OPERATION_FINISH;
        let (_, written) = if split {
            let (_, first) = encoder.compress(
                BrotliEncoderOperation::BROTLI_OPERATION_PROCESS,
                data,
                &mut out,
            );
            let (_, rest) = encoder.compress(finish, &[], &mut out[first..]);
            (0, first + rest)
        } else {
            encoder.compress(finish, data, &mut out)
        };
        out.truncate(written);
        out
    }

    #[test]
    fn a_small_hasher_for_all_the_input_gives_the_same_bytes() {
        let text: Vec<u8> = (0..300_000u32)
            .map(|i| {
                b"the quick brown fox jumps over the lazy dog "[(i * 7 % 44) as usize]
                    ^ (i % 3) as u8
            })
            .collect();
        for quality in [10, 11] {
            for size in [0, 1, 100, 5_000, 300_000] {
                for split in [false, true] {
                    let data = &text[..size];
                    let mut encoder = Encoder::new(Vec::new());
                    encoder.set_parameter(1, quality).expect("a quality");
                    let mut out = vec![0; size + 1024];
                    let written = if split {
                        let (_, first) = encoder.write(0, data, &mut out);
                        first + encoder.write(2, &[], &mut out[first..]).1
                    } else {
                        encoder.write(2, data, &mut out).1
                    };
                    assert_eq!(
                        out[..written],
                        reference(quality, data, split),
                        "quality {quality}, {size} bytes"
                    );
                }
            }
        }
    }

    #[test]
    fn a_bad_stream_fails_with_the_code_of_c_brotli() {
        let mut decoder = Decoder::new(&[]);
        let mut out = [0; 64];
        let _ = decoder.write(2, b"\xff\xff\xff\xff", &mut out);
        let failure = decoder.failure().expect("the stream is invalid");
        assert_eq!(failure.message, "Decompression failed");
        assert!(
            failure.code.starts_with("ERR__ERROR_FORMAT_"),
            "{}",
            failure.code
        );
    }
}
