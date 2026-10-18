//! The library of the native tier (section 17.10 of the contract). `cargo build` leaves
//! it next to the `buoy` binary, or in `deps/` there when it is built as a dependency of
//! the CLI. `erlang:load_nif/2` wants a file that ends in `.so` on every system, so the
//! CLI keeps a copy of that name in the cache, keyed by the size and the time of the
//! library, and gives the VM its path without the extension in `BUOY_JIT`.

use std::env;
use std::env::consts::{DLL_PREFIX, DLL_SUFFIX};
use std::fs;
use std::path::PathBuf;
use std::time::UNIX_EPOCH;

/// The path for `BUOY_JIT`, or `None` when no library is found and every call stays
/// in the Erlang tier. `BUOY_JIT_LIB` names the library to use instead.
pub fn library() -> Option<PathBuf> {
    let built = located()?;
    let metadata = fs::metadata(&built).ok()?;
    let time = metadata
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_nanos();
    let directory =
        crate::runtime::cache_root()?.join(format!("jit-{:x}-{time:x}", metadata.len()));
    let target = directory.join("buoy_jit.so");
    if !target.is_file() {
        fs::create_dir_all(&directory).ok()?;
        let staged = directory.join(format!("buoy_jit.so.{}", std::process::id()));
        fs::copy(&built, &staged).ok()?;
        fs::rename(&staged, &target).ok()?;
    }
    Some(directory.join("buoy_jit"))
}

fn located() -> Option<PathBuf> {
    if let Some(path) = env::var_os("BUOY_JIT_LIB").filter(|path| !path.is_empty()) {
        return Some(PathBuf::from(path));
    }
    let binary = env::current_exe().ok()?.canonicalize().ok()?;
    let directory = binary.parent()?;
    let name = format!("{DLL_PREFIX}buoy_jit{DLL_SUFFIX}");
    [directory.join(&name), directory.join("deps").join(&name)]
        .into_iter()
        .find(|path| path.is_file())
}
