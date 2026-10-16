//! The embedded Erlang runtime: written to a cache directory keyed by a content hash and
//! compiled there with `erlc` on first use (section 1 of the contract).

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs, process};

include!(concat!(env!("OUT_DIR"), "/runtime_sources.rs"));

/// The directory of compiled runtime `.beam` files, building it when needed.
pub fn ebin() -> Result<PathBuf, String> {
    if let Some(directory) = env::var_os("BOUY_RUNTIME") {
        return Ok(PathBuf::from(directory));
    }
    if SOURCES.is_empty() {
        return Err(
            "this bouy binary was built without the runtime sources in runtime/src".to_owned(),
        );
    }
    let cache = cache_root().ok_or("cannot find a cache directory: set HOME or XDG_CACHE_HOME")?;
    let directory = cache.join(format!("runtime-{:016x}", hash()));
    let ebin = directory.join("ebin");
    if ebin.is_dir() {
        return Ok(ebin);
    }
    build(&cache, &directory)?;
    Ok(ebin)
}

/// The program that starts the VM: `BOUY_ERL`, or `erl` on `PATH`.
pub fn erl() -> OsString {
    env::var_os("BOUY_ERL").unwrap_or_else(|| OsString::from("erl"))
}

fn erlc() -> OsString {
    env::var_os("BOUY_ERL")
        .map(PathBuf::from)
        .and_then(|erl| erl.parent().map(|bin| bin.join("erlc")))
        .filter(|erlc| erlc.is_file())
        .map_or_else(|| OsString::from("erlc"), PathBuf::into_os_string)
}

fn cache_root() -> Option<PathBuf> {
    env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
        .map(|cache| cache.join("bouy"))
}

/// Compiles the runtime into a private directory, then renames it into place, so that
/// concurrent first runs never see a half-built runtime.
fn build(cache: &Path, directory: &Path) -> Result<(), String> {
    let staging = cache.join(format!(
        "{}.tmp-{}",
        directory
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("runtime"),
        process::id()
    ));
    let source = staging.join("src");
    let ebin = staging.join("ebin");
    let failed = |error: std::io::Error| {
        format!("cannot write the runtime to {}: {error}", staging.display())
    };
    fs::create_dir_all(&source).map_err(failed)?;
    fs::create_dir_all(&ebin).map_err(failed)?;
    for (name, text) in SOURCES {
        fs::write(source.join(name), text).map_err(failed)?;
        let path = Path::new(name);
        if path.extension().is_some_and(|extension| extension == "src")
            && let Some(application) = path.file_stem()
        {
            fs::write(ebin.join(application), text).map_err(failed)?;
        }
    }
    let modules = SOURCES
        .iter()
        .filter(|(name, _)| {
            Path::new(name)
                .extension()
                .is_some_and(|extension| extension == "erl")
        })
        .map(|(name, _)| source.join(name));
    let output = Command::new(erlc())
        .arg("-o")
        .arg(&ebin)
        .arg("-I")
        .arg(&source)
        .args(modules)
        .output()
        .map_err(|error| format!("cannot run erlc: {error}; install Erlang/OTP or set BOUY_ERL"))?;
    if !output.status.success() {
        let _ = fs::remove_dir_all(&staging);
        return Err(format!(
            "erlc could not compile the runtime:\n{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    if fs::rename(&staging, directory).is_err() {
        let _ = fs::remove_dir_all(&staging);
        if !directory.join("ebin").is_dir() {
            return Err(format!(
                "cannot move the runtime into {}",
                directory.display()
            ));
        }
    }
    Ok(())
}

/// FNV-1a over the names and contents of the runtime sources.
fn hash() -> u64 {
    const PRIME: u64 = 0x0100_0000_01b3;
    SOURCES
        .iter()
        .flat_map(|(name, text)| name.bytes().chain([0]).chain(text.bytes()).chain([0]))
        .fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(PRIME)
        })
}
