//! The embedded Erlang runtime: written to a cache directory keyed by a content hash and
//! compiled there with `erlc` on first use (section 1 of the contract). Each compiled module
//! also goes into `objects/`, keyed by the hash of its source, so a runtime that changes a
//! few modules compiles only those. Each run holds a shared lock on its runtime directory,
//! and the build of a new runtime evicts the runtimes that no run holds or used lately.

use std::ffi::OsString;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};
use std::{env, fs, process};

include!(concat!(env!("OUT_DIR"), "/runtime_sources.rs"));

/// The compiled runtime that a program runs on.
#[derive(Debug)]
pub struct Runtime {
    /// The directory of compiled runtime `.beam` files.
    pub ebin: PathBuf,
    /// The OTP release of `erl`, which the cache records when it builds the runtime.
    release: Option<Release>,
    /// The boot script that the VM starts with (`write_boot`), without its `.boot` suffix.
    pub boot: String,
    /// The lock file of the runtime directory, held shared while the runtime is in use, so
    /// that `evict` keeps the directory. `None` for `BUOY_RUNTIME`.
    lock: Option<File>,
}

/// The OTP release that `erl` starts: its root directory and its erts version, and the
/// real path of the `erl` in use.
#[derive(Debug)]
struct Release {
    root: String,
    erts: String,
    erl: OsString,
}

impl Runtime {
    /// The command that starts the VM with the emulator flags `emulator`, such as `Bd`,
    /// followed by the init flags that the caller adds. The `erl` script searches for its
    /// root directory with a chain of shell commands on each start, so the command passes
    /// the recorded root in `ERL_ROOTDIR`. When `erl` is the script of that release,
    /// `<root>/bin/erl`, the command starts the emulator, `beam.smp`, with the arguments
    /// and the environment that `erlexec` would give it, which saves one `exec` of each
    /// start. That path ignores `ERL_FLAGS`, `ERL_AFLAGS`, and `ERL_ZFLAGS`, so a set one
    /// takes the `erlexec` path. The VM inherits the shared lock of the runtime, so that no
    /// other run evicts the runtime before the VM exits, also when it replaces this process.
    pub fn vm(&self, emulator: &[&str]) -> Command {
        #[cfg(unix)]
        if let Some(lock) = &self.lock {
            use nix::fcntl::{FcntlArg, FdFlag, fcntl};
            let _ = fcntl(lock, FcntlArg::F_SETFD(FdFlag::empty()));
        }
        let plus = || emulator.iter().map(|flag| format!("+{flag}"));
        let Some(Release {
            root,
            erts,
            erl: real,
        }) = &self.release
        else {
            let mut vm = Command::new(erl());
            vm.args(plus());
            return vm;
        };
        let root_path = Path::new(root);
        let bin = root_path.join(format!("erts-{erts}")).join("bin");
        let script = Path::new(real) == root_path.join("bin").join("erl");
        let flags_set = ["ERL_FLAGS", "ERL_AFLAGS", "ERL_ZFLAGS"]
            .iter()
            .any(|name| env::var_os(name).is_some_and(|value| !value.is_empty()));
        if script
            && !flags_set
            && bin.join("beam.smp").is_file()
            && let Some(home) = env::var_os("HOME")
        {
            let mut vm = Command::new(bin.join("beam.smp"));
            vm.env("ROOTDIR", root)
                .env("BINDIR", &bin)
                .env("EMU", "beam")
                .env("PROGNAME", "erl")
                .args(emulator.iter().map(|flag| format!("-{flag}")))
                .args(["--", "-root"])
                .arg(root)
                .arg("-bindir")
                .arg(&bin)
                .args(["-progname", "erl", "--", "-home"])
                .arg(home)
                .arg("--");
            return vm;
        }
        if script && bin.join("erlexec").is_file() {
            let mut vm = Command::new(bin.join("erlexec"));
            vm.env("ROOTDIR", root)
                .env("BINDIR", &bin)
                .env("EMU", "beam")
                .env("PROGNAME", "erl")
                .args(plus());
            return vm;
        }
        let mut vm = Command::new(erl());
        if env::var_os("ERL_ROOTDIR").is_none() {
            vm.env("ERL_ROOTDIR", root);
        }
        vm.args(plus());
        vm
    }
}

/// The compiled runtime, building it when needed.
pub fn locate() -> Result<Runtime, String> {
    if let Some(directory) = env::var_os("BUOY_RUNTIME").filter(|value| !value.is_empty()) {
        let directory = PathBuf::from(directory);
        if !directory.join("buoy_main.beam").is_file() {
            return Err(format!(
                "BUOY_RUNTIME={} holds no buoy_main.beam",
                directory.display()
            ));
        }
        return Ok(Runtime {
            ebin: directory,
            release: None,
            boot: "no_dot_erlang".to_owned(),
            lock: None,
        });
    }
    let cache = cache_root().ok_or("cannot find a cache directory: set HOME or XDG_CACHE_HOME")?;
    let real = installed_otp();
    let directory = cache.join(format!("runtime-{:016x}", hash(&real)));
    let ebin = directory.join("ebin");
    let mut lock = hold(&directory);
    if !ebin.is_dir() {
        build(&cache, &directory)?;
        evict(&cache);
        lock = hold(&directory);
    }
    let release = fs::read_to_string(directory.join(RELEASE))
        .ok()
        .and_then(|text| {
            let (root, erts) = text.split_once('\n')?;
            Some(Release {
                root: root.to_owned(),
                erts: erts.to_owned(),
                erl: real,
            })
        });
    // A runtime that an older CLI built has no boot script of its own.
    let boot = Some(directory.join(BOOT))
        .filter(|boot| boot.with_extension("boot").is_file())
        .and_then(|boot| boot.to_str().map(str::to_owned))
        .unwrap_or_else(|| "no_dot_erlang".to_owned());
    Ok(Runtime {
        ebin,
        release,
        boot,
        lock,
    })
}

/// The file in a runtime directory that each run holds a shared lock on, and whose
/// modification time is the start of the last run.
const LOCK: &str = "lock";

/// How long `evict` keeps a runtime that no run holds after its last run, so that two
/// builds of the CLI that run in turn do not rebuild each other's runtime.
const UNUSED: Duration = Duration::from_mins(10);

/// How long `evict` keeps an object that no build used, a build that never finished, and a
/// runtime that a CLI without locks built, which records no run.
const ABANDONED: Duration = Duration::from_hours(24);

/// Holds the lock file of `directory` shared and records the start of a run in its
/// modification time. `None` when the directory is gone or read-only. An eviction can set
/// the directory aside while this process waits for the lock, and another run can build the
/// runtime again meanwhile, so a lock on a file that left its path takes a second attempt.
fn hold(directory: &Path) -> Option<File> {
    (0..2).find_map(|_| hold_once(directory))
}

fn hold_once(directory: &Path) -> Option<File> {
    let path = directory.join(LOCK);
    let lock = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .ok()?;
    lock.lock_shared().ok()?;
    if !is_same_file(&lock, &path) {
        return None;
    }
    let _ = lock.set_modified(SystemTime::now());
    Some(lock)
}

#[cfg(unix)]
fn is_same_file(file: &File, path: &Path) -> bool {
    use std::os::unix::fs::MetadataExt;
    match (file.metadata(), fs::metadata(path)) {
        (Ok(open), Ok(named)) => open.dev() == named.dev() && open.ino() == named.ino(),
        _ => false,
    }
}

#[cfg(not(unix))]
fn is_same_file(_: &File, path: &Path) -> bool {
    path.is_file()
}

/// Removes from `cache` each runtime that no run holds and that no run started in the last
/// `UNUSED`, and each object, build directory, and runtime without a lock file that has
/// gone unused for `ABANDONED`. A run that holds the lock of a runtime keeps it, so no VM
/// loses a module that it has yet to load.
fn evict(cache: &Path) {
    let entries = fs::read_dir(cache).into_iter().flatten().flatten();
    for entry in entries {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if !name.starts_with("runtime-") {
            continue;
        }
        if name.contains(".evict-") {
            let _ = fs::remove_dir_all(&path);
            continue;
        }
        if name.contains(".tmp-") {
            if is_older(&path, ABANDONED) {
                let _ = fs::remove_dir_all(&path);
            }
            continue;
        }
        let Ok(lock) = File::open(path.join(LOCK)) else {
            if is_older(&path.join("ebin"), ABANDONED) {
                remove(&path, None);
            }
            continue;
        };
        if lock.try_lock().is_ok() && is_older(&path.join(LOCK), UNUSED) {
            remove(&path, Some(lock));
        }
    }
    let objects = fs::read_dir(cache.join("objects"))
        .into_iter()
        .flatten()
        .flatten();
    for object in objects {
        if is_older(&object.path(), ABANDONED) {
            let _ = fs::remove_file(object.path());
        }
    }
}

/// Renames `directory` aside, so that no run finds it half removed, releases its lock, so
/// that a run waiting for it builds the runtime again, and removes the directory.
fn remove(directory: &Path, lock: Option<File>) {
    let aside = directory.with_extension(format!("evict-{}", process::id()));
    let renamed = fs::rename(directory, &aside).is_ok();
    drop(lock);
    if renamed {
        let _ = fs::remove_dir_all(&aside);
    }
}

fn is_older(path: &Path, age: Duration) -> bool {
    fs::metadata(path)
        .and_then(|metadata| metadata.modified())
        .is_ok_and(|modified| modified.elapsed().is_ok_and(|elapsed| elapsed > age))
}

/// The boot script in a runtime directory, without its `.boot` suffix.
const BOOT: &str = "buoy";

/// The file in a runtime directory that holds the root directory of the OTP release and
/// its erts version, one on each line.
const RELEASE: &str = "release";

/// The program that starts the VM: `BUOY_ERL`, or `erl` on `PATH`.
pub fn erl() -> OsString {
    env::var_os("BUOY_ERL").unwrap_or_else(|| OsString::from("erl"))
}

fn erlc() -> OsString {
    env::var_os("BUOY_ERL")
        .map(PathBuf::from)
        .and_then(|erl| erl.parent().map(|bin| bin.join("erlc")))
        .filter(|erlc| erlc.is_file())
        .map_or_else(|| OsString::from("erlc"), PathBuf::into_os_string)
}

fn cache_root() -> Option<PathBuf> {
    // `home_dir` reads HOME, then the passwd entry of the user, as libuv's
    // uv_os_homedir does, so a child that runs with no HOME still finds the cache.
    cache_root_in(
        env::var_os("XDG_CACHE_HOME"),
        env::home_dir().map(PathBuf::into_os_string),
    )
}

/// `$XDG_CACHE_HOME/buoy`, or `$HOME/.cache/buoy`. The XDG Base Directory specification
/// ignores a value that is empty or relative.
fn cache_root_in(xdg_cache_home: Option<OsString>, home: Option<OsString>) -> Option<PathBuf> {
    xdg_cache_home
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .or_else(|| home.map(|home| PathBuf::from(home).join(".cache")))
        .map(|cache| cache.join("buoy"))
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
    let built = compile(&staging, &cache.join("objects"));
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

/// Writes the runtime sources to `staging/src` and compiles them into `staging/ebin`. A
/// module whose `.beam` is in `objects` under the hash of its source, the headers, and the
/// OTP release is copied from there; the others compile in parallel `erlc` processes and
/// join `objects`.
fn compile(staging: &Path, objects: &Path) -> Result<(), String> {
    let source = staging.join("src");
    let ebin = staging.join("ebin");
    let failed = |error: std::io::Error| {
        format!("cannot write the runtime to {}: {error}", staging.display())
    };
    fs::create_dir_all(&source).map_err(failed)?;
    fs::create_dir_all(&ebin).map_err(failed)?;
    fs::write(ebin.join("buoy_native.so"), NATIVE).map_err(failed)?;
    for (name, text) in SOURCES {
        fs::write(source.join(name), text).map_err(failed)?;
        let path = Path::new(name);
        if path.extension().is_some_and(|extension| extension == "src")
            && let Some(application) = path.file_stem()
        {
            fs::write(ebin.join(application), text).map_err(failed)?;
        }
    }
    let headers = fnv(SOURCES
        .iter()
        .filter(|(name, _)| has_extension(name, "hrl"))
        .flat_map(|(name, text)| name.bytes().chain(text.bytes()))
        .chain(installed_otp().as_encoded_bytes().iter().copied()));
    let modules: Vec<(&Path, PathBuf)> = SOURCES
        .iter()
        .filter(|(name, _)| has_extension(name, "erl"))
        .map(|(name, text)| {
            let key = fnv(headers.to_le_bytes().into_iter().chain(text.bytes()));
            let module = Path::new(*name);
            let stem = module.file_stem().unwrap_or_default().to_string_lossy();
            (module, objects.join(format!("{stem}-{key:016x}.beam")))
        })
        .collect();
    let missing: Vec<&Path> = modules
        .iter()
        .filter(|(module, object)| !reuse(object, &ebin.join(module.with_extension("beam"))))
        .map(|(module, _)| *module)
        .collect();
    let workers = std::thread::available_parallelism().map_or(4, usize::from);
    let chunks: Vec<&[&Path]> = missing
        .chunks(missing.len().div_ceil(workers).max(1))
        .collect();
    let outputs = std::thread::scope(|scope| {
        let running: Vec<_> = chunks
            .iter()
            .map(|chunk| {
                scope.spawn(|| {
                    Command::new(erlc())
                        .arg("-o")
                        .arg(&ebin)
                        .arg("-I")
                        .arg(&source)
                        .args(chunk.iter().map(|module| source.join(module)))
                        .output()
                })
            })
            .collect();
        running
            .into_iter()
            .map(|worker| worker.join().expect("an erlc worker does not panic"))
            .collect::<Vec<_>>()
    });
    let mut report = String::new();
    for output in outputs {
        let output = output.map_err(|error| {
            format!("cannot run erlc: {error}; install Erlang/OTP or set BUOY_ERL")
        })?;
        if !output.status.success() {
            report.push_str(&String::from_utf8_lossy(&output.stdout));
            report.push_str(&String::from_utf8_lossy(&output.stderr));
        }
    }
    // A signal can end erlc with a success status before it writes every file.
    let complete = modules
        .iter()
        .all(|(module, _)| ebin.join(module.with_extension("beam")).is_file());
    if !report.is_empty() || !complete {
        return Err(format!("erlc could not compile the runtime:\n{report}"));
    }
    if fs::create_dir_all(objects).is_ok() {
        for (module, object) in &modules {
            if missing.contains(module) {
                let staged = object.with_extension(format!("beam.{}", process::id()));
                if fs::copy(ebin.join(module.with_extension("beam")), &staged).is_ok() {
                    let _ = fs::rename(&staged, object);
                }
            }
        }
    }
    record_release(staging);
    write_boot(&staging.join(BOOT).with_extension("boot"));
    Ok(())
}

/// Writes the `no_dot_erlang` boot script of the OTP release to `path`, with SIGTERM set to
/// its default action once the kernel's modules load, before the kernel starts. ERTS hands
/// SIGTERM to `erl_signal_server` from its start: it drops the signal while that server
/// does not exist, and the kernel's handler calls `init:stop()`, which waits until the code
/// of `-eval` returns. So a SIGTERM before `buoy_main` reset the action went unheard until
/// the program ended. A native runtime such as Bun keeps the default action from `exec`
/// on. A runtime without the file boots with `no_dot_erlang`.
fn write_boot(path: &Path) {
    let script = r#"{ok, Bin} = file:read_file(filename:join([code:root_dir(), "bin", "no_dot_erlang.boot"])),
        {script, Id, Steps} = binary_to_term(Bin),
        Loaded = {kernel_load_completed},
        {Before, [Loaded | After]} = lists:splitwith(fun(Step) -> Step =/= Loaded end, Steps),
        Signal = {apply, {os, set_signal, [sigterm, default]}},
        ok = file:write_file(os:getenv("BUOY_BOOT"), term_to_binary({script, Id, Before ++ [Loaded, Signal | After]})),
        halt()."#;
    let _ = Command::new(erl())
        .args([
            "-noshell",
            "-noinput",
            "-boot",
            "no_dot_erlang",
            "-eval",
            script,
        ])
        .env("BUOY_BOOT", path)
        .env("ERL_CRASH_DUMP_SECONDS", "0")
        .output();
}

/// Copies a compiled object to `target`, and records the use in its modification time, so
/// that `evict` keeps it.
fn reuse(object: &Path, target: &Path) -> bool {
    let copied = fs::copy(object, target).is_ok();
    if copied && let Ok(file) = File::options().write(true).open(object) {
        let _ = file.set_modified(SystemTime::now());
    }
    copied
}

fn has_extension(name: &str, extension: &str) -> bool {
    Path::new(name)
        .extension()
        .is_some_and(|found| found == extension)
}

/// FNV-1a over `bytes`.
fn fnv(bytes: impl Iterator<Item = u8>) -> u64 {
    const PRIME: u64 = 0x0100_0000_01b3;
    bytes.fold(0xcbf2_9ce4_8422_2325, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(PRIME)
    })
}

/// Writes the root directory and the erts version of the OTP release that `erl` starts to
/// `staging/release`. A runtime without the file still runs: `erl` then finds its root
/// itself.
fn record_release(staging: &Path) {
    let probe = r#"io:format("~ts~n~ts", [code:root_dir(), erlang:system_info(version)]), halt()."#;
    let Ok(output) = Command::new(erl())
        .args([
            "-noshell",
            "-noinput",
            "-boot",
            "no_dot_erlang",
            "-eval",
            probe,
        ])
        .output()
    else {
        return;
    };
    let release = String::from_utf8_lossy(&output.stdout);
    let complete = release
        .split_once('\n')
        .is_some_and(|(root, erts)| Path::new(root).join("bin").is_dir() && !erts.is_empty());
    if output.status.success() && complete {
        let _ = fs::write(staging.join(RELEASE), release.as_bytes());
    }
}

/// FNV-1a over the names and contents of the runtime sources, the NIF library, and the
/// installed OTP, so that the `.beam` files always match the OTP release that runs them.
fn hash(otp: &OsString) -> u64 {
    fnv(SOURCES
        .iter()
        .flat_map(|(name, text)| name.bytes().chain([0]).chain(text.bytes()).chain([0]))
        .chain(NATIVE_HASH.to_le_bytes())
        .chain(otp.as_encoded_bytes().iter().copied()))
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

    /// SIGTERM ends a VM that boots with the script of `write_boot` at once, even while the
    /// code of `-eval` runs, where the kernel's handler waits for that code to return.
    #[test]
    fn sigterm_ends_a_vm_that_boots_with_the_runtime_script() {
        let directory = env::temp_dir().join(format!("buoy-boot-{}", process::id()));
        fs::create_dir_all(&directory).expect("the directory");
        let boot = directory.join(BOOT);
        write_boot(&boot.with_extension("boot"));
        let mut vm = Command::new(erl())
            .arg("-boot")
            .arg(&boot)
            .args([
                "-noshell",
                "-eval",
                "io:format(\"ready~n\"), timer:sleep(10000), halt(1).",
            ])
            .stdout(process::Stdio::piped())
            .spawn()
            .expect("erl starts");
        let mut ready = [0; 6];
        std::io::Read::read_exact(vm.stdout.as_mut().expect("piped"), &mut ready)
            .expect("the VM runs the code of -eval");
        let started = std::time::Instant::now();
        let _ = Command::new("kill")
            .args(["-TERM", &vm.id().to_string()])
            .status();
        let status = vm.wait().expect("the VM exits");
        let _ = fs::remove_dir_all(&directory);
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "the VM ran {:?} after SIGTERM",
            started.elapsed()
        );
        assert_eq!(
            std::os::unix::process::ExitStatusExt::signal(&status),
            Some(15)
        );
    }

    /// Eviction keeps a runtime while a run, or a VM that inherited the lock of a run, holds
    /// it, and while a run used it lately. It removes the other runtimes, and the objects and
    /// unfinished builds that nobody used for a day.
    #[test]
    fn eviction_keeps_each_runtime_that_a_run_holds_or_used_lately() {
        let cache = env::temp_dir().join(format!("buoy-evict-{}", process::id()));
        let _ = fs::remove_dir_all(&cache);
        let runtime = |name: &str| {
            let directory = cache.join(name);
            fs::create_dir_all(directory.join("ebin")).expect("the runtime");
            directory
        };
        let long_ago = SystemTime::now() - ABANDONED * 2;
        let age = |path: &Path| {
            File::open(path)
                .and_then(|file| file.set_modified(long_ago))
                .expect("the old time");
        };

        let held = runtime("runtime-held");
        let held_lock = hold(&held);
        age(&held.join(LOCK));
        let inherited = runtime("runtime-inherited");
        let vm = Runtime {
            ebin: inherited.join("ebin"),
            release: None,
            boot: String::new(),
            lock: hold(&inherited),
        };
        let _ = vm.vm(&[]);
        let mut child = Command::new("sleep")
            .arg("30")
            .spawn()
            .expect("sleep starts");
        drop(vm);
        age(&inherited.join(LOCK));
        let recent = runtime("runtime-recent");
        drop(hold(&recent));
        let unused = runtime("runtime-unused");
        drop(hold(&unused));
        age(&unused.join(LOCK));
        let lockless = runtime("runtime-lockless");
        age(&lockless.join("ebin"));
        let staging = runtime("runtime-unused.tmp-1");
        age(&staging);
        fs::create_dir_all(cache.join("objects")).expect("the objects");
        let (old_object, new_object) = (cache.join("objects/a.beam"), cache.join("objects/b.beam"));
        fs::write(&old_object, "").expect("an object");
        fs::write(&new_object, "").expect("an object");
        age(&old_object);

        evict(&cache);
        let _ = child.kill();
        let _ = child.wait();
        let kept: Vec<bool> = [&held, &inherited, &recent, &new_object]
            .iter()
            .map(|path| path.exists())
            .collect();
        let removed: Vec<bool> = [&unused, &lockless, &staging, &old_object]
            .iter()
            .map(|path| path.exists())
            .collect();
        drop(held_lock);
        let _ = fs::remove_dir_all(&cache);
        assert_eq!(kept, [true; 4], "held, inherited, recent, new object");
        assert_eq!(removed, [false; 4], "unused, lockless, staging, old object");
    }

    #[test]
    fn the_cache_ignores_an_empty_or_relative_xdg_cache_home() {
        let home = || Some(OsString::from("/home/ann"));
        let expected = Some(PathBuf::from("/home/ann/.cache/buoy"));
        assert_eq!(cache_root_in(Some(OsString::new()), home()), expected);
        assert_eq!(
            cache_root_in(Some(OsString::from("relcache")), home()),
            expected
        );
        assert_eq!(
            cache_root_in(Some(OsString::from("/cache")), home()),
            Some(PathBuf::from("/cache/buoy"))
        );
        assert_eq!(cache_root_in(None, None), None);
    }
}
