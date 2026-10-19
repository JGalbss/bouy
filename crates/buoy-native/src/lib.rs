//! The NIF library of the runtime, which `buoy_native.erl` loads into the VM.
//!
//! It holds the native built-ins of section 17.10 of `docs/design/beam-runtime.md`,
//! `JSON.parse` (`json`) and the `RegExp` matcher (`regexp`), which run on the scheduler of
//! their process in time slices (`slice`), so BEAM preemption holds while they run.
//!
//! It also holds the CLDR data and algorithms of `Intl` (`intl`, docs/design/intl.md).
//! `fs` holds the file system calls of `internalBinding('fs')` that ERTS lacks, and `inotify`
//! the watches of `internalBinding('fs_event_wrap')` on Linux. The rest holds
//! the codecs behind `internalBinding('zlib')` (docs/design/node-builtins.md):
//! each stream is a resource that owns one zlib, brotli, or zstd context, and each module
//! ports the matching context class of Node's `src/node_zlib.cc`. A write runs on a dirty
//! CPU scheduler, as Node runs it on the libuv thread pool, so a slow compression never
//! blocks a scheduler of the actors. Allocations, libzstd's too, go through `enif_alloc`,
//! so `BUOY_MAX_MEMORY` counts them. It also runs, on a dirty CPU scheduler, the parts of
//! `internalBinding('crypto')` that OTP's crypto lacks: Argon2, the Keccak sponge, and the
//! `ROMix` of scrypt.

// The NIF glue, which the tests leave out, is the caller of most of the codecs.
#![cfg_attr(test, allow(dead_code))]

pub mod argon2;
mod brotli;
pub mod intl;
mod keccak;
// The NIF glue links against the VM's `enif_*` symbols, which a test binary lacks.
#[cfg(not(test))]
mod fs;
#[cfg(all(target_os = "linux", not(test)))]
mod inotify;
#[cfg(not(test))]
mod json;
#[cfg(not(test))]
mod nif;
#[cfg(not(test))]
mod regexp;
#[cfg(not(test))]
mod slice;
mod scrypt;
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
