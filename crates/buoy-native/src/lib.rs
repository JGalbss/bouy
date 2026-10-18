//! The NIF library of the runtime, which `buoy_native.erl` loads into the VM.
//!
//! It holds the codecs behind `internalBinding('zlib')` (docs/design/node-builtins.md):
//! each stream is a resource that owns one zlib, brotli, or zstd context, and each module
//! ports the matching context class of Node's `src/node_zlib.cc`. A write runs on a dirty
//! CPU scheduler, as Node runs it on the libuv thread pool, so a slow compression never
//! blocks a scheduler of the actors. Allocations go through `enif_alloc`, so
//! `BUOY_MAX_MEMORY` counts them, apart from libzstd's own.

// The NIF glue, which the tests leave out, is the caller of most of the codecs.
#![cfg_attr(test, allow(dead_code))]

mod brotli;
// The NIF glue links against the VM's `enif_*` symbols, which a test binary lacks.
#[cfg(not(test))]
mod nif;
mod zlib;
mod zstd;

/// Node's `CompressionError`: the message, the code, and the errno that the `onerror`
/// callback of a handle receives.
#[derive(Clone, Debug)]
pub struct Failure {
    pub message: String,
    pub code: String,
    pub errno: i32,
}

impl Failure {
    #[must_use]
    pub fn new(message: &str, code: &str, errno: i32) -> Self {
        Self {
            message: message.to_owned(),
            code: code.to_owned(),
            errno,
        }
    }

    /// The term `{Message, Errno, Code}`.
    #[must_use]
    pub fn term(self) -> (String, i32, String) {
        (self.message, self.errno, self.code)
    }
}
