//! Node's `ZstdCompressContext` and `ZstdDecompressContext` (`src/node_zlib.cc`) on
//! libzstd 1.5.7, the release that Node bundles, built without the legacy formats as Node
//! builds it. No Rust encoder has libzstd's levels, flushes, and dictionaries.

use std::ffi::{CStr, c_int, c_void};
use std::ptr::NonNull;

use zstd_sys as z;

use crate::Failure;

/// What a compressor or decompressor needs from its libzstd context.
#[allow(unsafe_code)]
trait Context {
    fn create() -> *mut Self;
    /// # Safety
    /// `context` comes from `create` and is freed once.
    unsafe fn free(context: *mut Self);
}

impl Context for z::ZSTD_CCtx {
    #[allow(unsafe_code)]
    fn create() -> *mut Self {
        // SAFETY: no arguments; a null result is handled by the caller.
        unsafe { z::ZSTD_createCCtx() }
    }
    #[allow(unsafe_code)]
    unsafe fn free(context: *mut Self) {
        // SAFETY: the caller's contract.
        let _ = unsafe { z::ZSTD_freeCCtx(context) };
    }
}

impl Context for z::ZSTD_DCtx {
    #[allow(unsafe_code)]
    fn create() -> *mut Self {
        // SAFETY: no arguments; a null result is handled by the caller.
        unsafe { z::ZSTD_createDCtx() }
    }
    #[allow(unsafe_code)]
    unsafe fn free(context: *mut Self) {
        // SAFETY: the caller's contract.
        let _ = unsafe { z::ZSTD_freeDCtx(context) };
    }
}

/// A libzstd context that the stream owns.
struct Owned<C: Context>(NonNull<C>);

impl<C: Context> Owned<C> {
    fn create() -> Result<Self, Failure> {
        NonNull::new(C::create()).map(Self).ok_or_else(|| {
            Failure::new(
                "Could not initialize zstd instance",
                "ERR_ZLIB_INITIALIZATION_FAILED",
                -1,
            )
        })
    }
}

impl<C: Context> Drop for Owned<C> {
    #[allow(unsafe_code)]
    fn drop(&mut self) {
        // SAFETY: the pointer came from `create`, and only this owner frees it.
        unsafe { C::free(self.0.as_ptr()) };
    }
}

// SAFETY: a libzstd context has no thread affinity; the resource's `Mutex` serializes its
// use.
#[allow(unsafe_code)]
unsafe impl<C: Context> Send for Owned<C> {}

/// The compressor of one stream.
pub struct Compressor {
    context: Owned<z::ZSTD_CCtx>,
    pledged_src_size: u64,
    error: Option<Failure>,
}

impl std::fmt::Debug for Compressor {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("Compressor").finish_non_exhaustive()
    }
}

/// `ZSTD_CONTENTSIZE_UNKNOWN`.
pub const CONTENT_SIZE_UNKNOWN: u64 = u64::MAX;

impl Compressor {
    /// `ZstdCompressContext::Init`.
    #[allow(unsafe_code)]
    pub fn new(pledged_src_size: u64, dictionary: &[u8]) -> Result<Self, Failure> {
        let context = Owned::<z::ZSTD_CCtx>::create()?;
        let cctx = context.0.as_ptr();
        if !dictionary.is_empty() {
            // SAFETY: `cctx` is live, and libzstd copies the dictionary.
            let result = unsafe {
                z::ZSTD_CCtx_loadDictionary(
                    cctx,
                    dictionary.as_ptr().cast::<c_void>(),
                    dictionary.len(),
                )
            };
            if is_error(result) {
                return Err(Failure::new(
                    "Failed to load zstd dictionary",
                    "ERR_ZLIB_DICTIONARY_LOAD_FAILED",
                    -1,
                ));
            }
        }
        // SAFETY: `cctx` is live.
        let result = unsafe { z::ZSTD_CCtx_setPledgedSrcSize(cctx, pledged_src_size) };
        if is_error(result) {
            return Err(Failure::new(
                "Could not set pledged src size",
                "ERR_ZLIB_INITIALIZATION_FAILED",
                -1,
            ));
        }
        Ok(Self {
            context,
            pledged_src_size,
            error: None,
        })
    }

    /// `ZstdCompressContext::SetParameter` for a key of `ZSTD_c_*`.
    #[allow(unsafe_code)]
    pub fn set_parameter(&mut self, key: u32, value: u32) -> Result<(), Failure> {
        let set = compression_parameter(key).is_some_and(|param| {
            // SAFETY: the context is live; libzstd checks the value.
            let result =
                unsafe { z::ZSTD_CCtx_setParameter(self.context.0.as_ptr(), param, signed(value)) };
            !is_error(result)
        });
        if !set {
            return Err(Failure::new(
                "Setting parameter failed",
                "ERR_ZSTD_PARAM_SET_FAILED",
                -1,
            ));
        }
        Ok(())
    }

    /// `ZSTD_compressStream2` with the directive `flush`.
    #[allow(unsafe_code)]
    pub fn write(&mut self, flush: u32, input: &[u8], output: &mut [u8]) -> (usize, usize) {
        let directive = match flush {
            1 => z::ZSTD_EndDirective::ZSTD_e_flush,
            2 => z::ZSTD_EndDirective::ZSTD_e_end,
            _ => z::ZSTD_EndDirective::ZSTD_e_continue,
        };
        let mut source = in_buffer(input);
        let mut target = out_buffer(output);
        // SAFETY: the buffers point into `input` and `output`, which outlive the call.
        let result = unsafe {
            z::ZSTD_compressStream2(
                self.context.0.as_ptr(),
                &raw mut target,
                &raw mut source,
                directive,
            )
        };
        self.error = failure_of(result);
        (source.pos, target.pos)
    }

    pub fn failure(&self) -> Option<Failure> {
        self.error.clone()
    }

    /// `ZstdCompressContext::ResetStream`: a new context with the same pledged size. As in
    /// Node, the dictionary and the parameters do not carry over.
    pub fn reset(&mut self) -> Result<(), Failure> {
        *self = Self::new(self.pledged_src_size, &[])?;
        Ok(())
    }
}

/// The decompressor of one stream.
pub struct Decompressor {
    context: Owned<z::ZSTD_DCtx>,
    error: Option<Failure>,
}

impl std::fmt::Debug for Decompressor {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Decompressor")
            .finish_non_exhaustive()
    }
}

impl Decompressor {
    /// `ZstdDecompressContext::Init`.
    #[allow(unsafe_code)]
    pub fn new(dictionary: &[u8]) -> Result<Self, Failure> {
        let context = Owned::<z::ZSTD_DCtx>::create()?;
        if !dictionary.is_empty() {
            // SAFETY: the context is live, and libzstd copies the dictionary.
            let result = unsafe {
                z::ZSTD_DCtx_loadDictionary(
                    context.0.as_ptr(),
                    dictionary.as_ptr().cast::<c_void>(),
                    dictionary.len(),
                )
            };
            if is_error(result) {
                return Err(Failure::new(
                    "Failed to load zstd dictionary",
                    "ERR_ZLIB_DICTIONARY_LOAD_FAILED",
                    -1,
                ));
            }
        }
        Ok(Self {
            context,
            error: None,
        })
    }

    /// `ZstdDecompressContext::SetParameter` for a key of `ZSTD_d_*`.
    #[allow(unsafe_code)]
    pub fn set_parameter(&mut self, key: u32, value: u32) -> Result<(), Failure> {
        let set = key == 100 && {
            // SAFETY: the context is live; libzstd checks the value.
            let result = unsafe {
                z::ZSTD_DCtx_setParameter(
                    self.context.0.as_ptr(),
                    z::ZSTD_dParameter::ZSTD_d_windowLogMax,
                    signed(value),
                )
            };
            !is_error(result)
        };
        if !set {
            return Err(Failure::new(
                "Setting parameter failed",
                "ERR_ZSTD_PARAM_SET_FAILED",
                -1,
            ));
        }
        Ok(())
    }

    /// `ZSTD_decompressStream`.
    #[allow(unsafe_code)]
    pub fn write(&mut self, input: &[u8], output: &mut [u8]) -> (usize, usize) {
        let mut source = in_buffer(input);
        let mut target = out_buffer(output);
        // SAFETY: the buffers point into `input` and `output`, which outlive the call.
        let result = unsafe {
            z::ZSTD_decompressStream(self.context.0.as_ptr(), &raw mut target, &raw mut source)
        };
        self.error = failure_of(result);
        (source.pos, target.pos)
    }

    pub fn failure(&self) -> Option<Failure> {
        self.error.clone()
    }

    /// `ZstdDecompressContext::ResetStream`: a new context, without the dictionary.
    pub fn reset(&mut self) -> Result<(), Failure> {
        *self = Self::new(&[])?;
        Ok(())
    }
}

fn in_buffer(input: &[u8]) -> z::ZSTD_inBuffer {
    z::ZSTD_inBuffer {
        src: input.as_ptr().cast::<c_void>(),
        size: input.len(),
        pos: 0,
    }
}

fn out_buffer(output: &mut [u8]) -> z::ZSTD_outBuffer {
    z::ZSTD_outBuffer {
        dst: output.as_mut_ptr().cast::<c_void>(),
        size: output.len(),
        pos: 0,
    }
}

/// The `int` that libzstd reads from a `uint32_t` of Node's parameter array.
fn signed(value: u32) -> c_int {
    c_int::from_ne_bytes(value.to_ne_bytes())
}

/// `ZSTD_isError`: libzstd returns an error as the negation of its code, below 120.
fn is_error(result: usize) -> bool {
    error_code(result).is_some()
}

fn error_code(result: usize) -> Option<usize> {
    let code = result.wrapping_neg();
    (1..120).contains(&code).then_some(code)
}

/// The failure that Node reports for a result of libzstd: the message of libzstd, the
/// name of the code, and the code.
#[allow(unsafe_code)]
fn failure_of(result: usize) -> Option<Failure> {
    let code = error_code(result)?;
    // SAFETY: libzstd returns a static, NUL-terminated message for any result.
    let message = unsafe { CStr::from_ptr(z::ZSTD_getErrorName(result)) }
        .to_string_lossy()
        .into_owned();
    let errno = i32::try_from(code).unwrap_or(1);
    Some(Failure::new(&message, error_name(code), errno))
}

/// `ZstdStrerror`.
fn error_name(code: usize) -> &'static str {
    match code {
        0 => "ZSTD_error_no_error",
        10 => "ZSTD_error_prefix_unknown",
        12 => "ZSTD_error_version_unsupported",
        14 => "ZSTD_error_frameParameter_unsupported",
        16 => "ZSTD_error_frameParameter_windowTooLarge",
        20 => "ZSTD_error_corruption_detected",
        22 => "ZSTD_error_checksum_wrong",
        24 => "ZSTD_error_literals_headerWrong",
        30 => "ZSTD_error_dictionary_corrupted",
        32 => "ZSTD_error_dictionary_wrong",
        34 => "ZSTD_error_dictionaryCreation_failed",
        40 => "ZSTD_error_parameter_unsupported",
        41 => "ZSTD_error_parameter_combination_unsupported",
        42 => "ZSTD_error_parameter_outOfBound",
        44 => "ZSTD_error_tableLog_tooLarge",
        46 => "ZSTD_error_maxSymbolValue_tooLarge",
        48 => "ZSTD_error_maxSymbolValue_tooSmall",
        50 => "ZSTD_error_stabilityCondition_notRespected",
        60 => "ZSTD_error_stage_wrong",
        62 => "ZSTD_error_init_missing",
        64 => "ZSTD_error_memory_allocation",
        66 => "ZSTD_error_workSpace_tooSmall",
        70 => "ZSTD_error_dstSize_tooSmall",
        72 => "ZSTD_error_srcSize_wrong",
        74 => "ZSTD_error_dstBuffer_null",
        80 => "ZSTD_error_noForwardProgress_destFull",
        82 => "ZSTD_error_noForwardProgress_inputEmpty",
        _ => "ZSTD_error_GENERIC",
    }
}

/// The stable parameters of `ZSTD_cParameter` in zstd.h. libzstd rejects any other key.
fn compression_parameter(key: u32) -> Option<z::ZSTD_cParameter> {
    use z::ZSTD_cParameter as P;
    Some(match key {
        100 => P::ZSTD_c_compressionLevel,
        101 => P::ZSTD_c_windowLog,
        102 => P::ZSTD_c_hashLog,
        103 => P::ZSTD_c_chainLog,
        104 => P::ZSTD_c_searchLog,
        105 => P::ZSTD_c_minMatch,
        106 => P::ZSTD_c_targetLength,
        107 => P::ZSTD_c_strategy,
        130 => P::ZSTD_c_targetCBlockSize,
        160 => P::ZSTD_c_enableLongDistanceMatching,
        161 => P::ZSTD_c_ldmHashLog,
        162 => P::ZSTD_c_ldmMinMatch,
        163 => P::ZSTD_c_ldmBucketSizeLog,
        164 => P::ZSTD_c_ldmHashRateLog,
        200 => P::ZSTD_c_contentSizeFlag,
        201 => P::ZSTD_c_checksumFlag,
        202 => P::ZSTD_c_dictIDFlag,
        400 => P::ZSTD_c_nbWorkers,
        401 => P::ZSTD_c_jobSize,
        402 => P::ZSTD_c_overlapLog,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_wrong_pledged_size_fails_with_the_code_of_node() {
        let mut compressor = Compressor::new(13, &[]).expect("a context");
        let mut out = [0; 256];
        // libzstd takes the size of the input in place of the pledged one when one call
        // gives it all with ZSTD_e_end, so the stream ends in a later call.
        let _ = compressor.write(0, &[b'x'; 42], &mut out);
        let _ = compressor.write(2, &[], &mut out);
        let failure = compressor.failure().expect("the size is wrong");
        assert_eq!(failure.code, "ZSTD_error_srcSize_wrong");
        assert_eq!(failure.errno, 72);
    }

    #[test]
    fn a_frame_round_trips_with_a_dictionary() {
        let dictionary = b"Lorem ipsum dolor sit amet, consectetur adipiscing elit.".to_vec();
        let data = b"Lorem ipsum dolor sit amet. Lorem ipsum dolor sit amet.".repeat(4);
        let mut compressor = Compressor::new(CONTENT_SIZE_UNKNOWN, &dictionary).expect("a context");
        let mut packed = [0; 512];
        let (_, size) = compressor.write(2, &data, &mut packed);
        assert!(compressor.failure().is_none());
        let mut decompressor = Decompressor::new(&dictionary).expect("a context");
        let mut plain = [0; 512];
        let (_, length) = decompressor.write(&packed[..size], &mut plain);
        assert!(decompressor.failure().is_none());
        assert_eq!(&plain[..length], data.as_slice());
    }
}
