//! The embedded Erlang runtime: written to a cache directory keyed by a content hash and
//! compiled there with `erlc` on first use (section 1 of the contract).

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::{env, fs, process};

include!(concat!(env!("OUT_DIR"), "/runtime_sources.rs"));

/// The directory of compiled runtime `.beam` files, building it when needed.
pub fn ebin() -> Result<PathBuf, String> {
    if let Some(directory) = env::var_os("BOUY_RUNTIME").filter(|value| !value.is_empty()) {
        let directory = PathBuf::from(directory);
        if !directory.join("bouy_main.beam").is_file() {
            return Err(format!(
                "BOUY_RUNTIME={} holds no bouy_main.beam",
                directory.display()
            ));
        }
        return Ok(directory);
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
    cache_root_in(env::var_os("XDG_CACHE_HOME"), env::var_os("HOME"))
}

/// `$XDG_CACHE_HOME/bouy`, or `$HOME/.cache/bouy`. The XDG Base Directory specification
/// ignores a value that is empty or relative.
fn cache_root_in(xdg_cache_home: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    xdg_cache_home
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| home.map(|home| PathBuf::from(home).join(".cache")))
        .map(|cache| cache.join("bouy"))
}

/// Compiles the runtime into a private directory, then renames it into place, so that
/// concurrent first runs never see a half-built runtime. A failure removes the private
/// directory.
fn build(cache: &Path, directory: &Path) -> Result<(), String> {
    let staging = cache.join(format!(
        "{}.tmp-{}",
        directory
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("runtime"),
        process::id()
    ));
    let built = compile(&staging);
    if built.is_err() {
        let _ = fs::remove_dir_all(&staging);
        return built;
    }
    if let Err(error) = fs::rename(&staging, directory) {
        let _ = fs::remove_dir_all(&staging);
        if !directory.join("ebin").is_dir() {
            return Err(format!(
                "cannot move the runtime into {}: {error}",
                directory.display()
            ));
        }
    }
    Ok(())
}

/// Writes the runtime sources to `staging/src` and compiles them into `staging/ebin`.
fn compile(staging: &Path) -> Result<(), String> {
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
    let modules: Vec<&Path> = SOURCES
        .iter()
        .map(|(name, _)| Path::new(*name))
        .filter(|name| name.extension().is_some_and(|extension| extension == "erl"))
        .collect();
    let output = Command::new(erlc())
        .arg("-o")
        .arg(&ebin)
        .arg("-I")
        .arg(&source)
        .args(modules.iter().map(|module| source.join(module)))
        .output()
        .map_err(|error| format!("cannot run erlc: {error}; install Erlang/OTP or set BOUY_ERL"))?;
    // A signal can end erlc with a success status before it writes every file.
    let complete = modules
        .iter()
        .all(|module| ebin.join(module.with_extension("beam")).is_file());
    if !output.status.success() || !complete {
        return Err(format!(
            "erlc could not compile the runtime:\n{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(())
}

/// FNV-1a over the names and contents of the runtime sources and the installed OTP, so
/// that the `.beam` files always match the OTP release that runs them.
fn hash() -> u64 {
    const PRIME: u64 = 0x0100_0000_01b3;
    let otp = installed_otp();
    SOURCES
        .iter()
        .flat_map(|(name, text)| name.bytes().chain([0]).chain(text.bytes()).chain([0]))
        .chain(otp.as_encoded_bytes().iter().copied())
        .fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(PRIME)
        })
}

/// The real path of the `erl` that runs the program. Installations such as Homebrew,
/// asdf, and kerl keep each OTP release in a directory named after its version.
fn installed_otp() -> OsString {
    let erl = PathBuf::from(erl());
    let found = if erl.components().count() > 1 {
        Some(erl)
    } else {
        env::var_os("PATH").and_then(|path| {
            env::split_paths(&path)
                .map(|directory| directory.join(&erl))
                .find(|candidate| candidate.is_file())
        })
    };
    found
        .and_then(|path| path.canonicalize().ok())
        .map_or_else(OsString::new, PathBuf::into_os_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cache_ignores_an_empty_or_relative_xdg_cache_home() {
        let home = || Some(OsString::from("/home/ann"));
        let expected = Some(PathBuf::from("/home/ann/.cache/bouy"));
        assert_eq!(cache_root_in(Some(OsString::new()), home()), expected);
        assert_eq!(
            cache_root_in(Some(OsString::from("relcache")), home()),
            expected
        );
        assert_eq!(
            cache_root_in(Some(OsString::from("/cache")), home()),
            Some(PathBuf::from("/cache/bouy"))
        );
        assert_eq!(cache_root_in(None, None), None);
    }
}
