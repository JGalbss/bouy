//! Embeds the runtime sources, the `*.erl` and `*.app.src` files of `runtime/src` and its
//! subsystem directories and the `*.hrl` files of `runtime/include`, in the binary, under
//! their file names. The build fails when they are missing, because a binary without them
//! cannot run a program.
//!
//! It also compiles the vendored Temporal polyfill into one more runtime source,
//! `buoy_temporal.erl`, with the reference compiler (see `temporal_module`), each Node
//! built-in of `runtime/node/builtins.txt` into a runtime source `buoy_node@<id>.erl` (see
//! `node_modules`), and the NIF libraries of `crates/buoy-native` and `crates/buoy-jit`
//! (see `native_library`).

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::{env, fs};

fn main() {
    let manifest =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"));
    let runtime = manifest.join("../../runtime/src");
    let mut sources = runtime_sources(&runtime);
    assert!(
        !sources.is_empty(),
        "{} holds no runtime sources",
        runtime.display()
    );
    sources.extend(runtime_sources(&manifest.join("../../runtime/include")));
    let out = PathBuf::from(env::var("OUT_DIR").expect("cargo sets OUT_DIR"));
    sources.push(temporal_module(
        &manifest.join("../../runtime/vendor/temporal-polyfill/global.js"),
        &out,
    ));
    sources.extend(node_modules(&manifest.join("../../runtime"), &out));
    sources.push(node_index(&manifest.join("../../runtime"), &sources, &out));
    sources.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
    let mut table = String::from(
        "/// The runtime sources: file name and contents.\npub const SOURCES: &[(&str, &str)] = &[\n",
    );
    for path in &sources {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .expect("a runtime source has a UTF-8 name");
        let absolute = path
            .canonicalize()
            .unwrap_or_else(|error| panic!("{}: {error}", path.display()));
        let _ = writeln!(
            table,
            "    ({name:?}, include_str!({:?})),",
            absolute.display().to_string()
        );
    }
    table.push_str("];\n");
    table.push_str(&native_library(&manifest.join("../.."), &out));
    fs::write(out.join("runtime_sources.rs"), table).expect("OUT_DIR is writable");
}

/// The runtime sources under `directory` and its subdirectories.
fn runtime_sources(directory: &Path) -> Vec<PathBuf> {
    println!("cargo:rerun-if-changed={}", directory.display());
    let entries = fs::read_dir(directory)
        .unwrap_or_else(|error| panic!("{} holds runtime sources: {error}", directory.display()));
    let mut sources = Vec::new();
    for path in entries.filter_map(Result::ok).map(|entry| entry.path()) {
        if path.is_dir() {
            sources.extend(runtime_sources(&path));
        } else if is_runtime_source(&path) {
            sources.push(path);
        }
    }
    sources
}

/// The NIF libraries that the CLI embeds: each crate, by its directory under `crates`,
/// and the Erlang module that loads it. The crates that a library depends on follow.
const NATIVE_LIBRARIES: [(&str, &str, &[&str]); 2] = [
    ("buoy-native", "buoy_native", &[]),
    ("buoy-jit", "buoy_jit", &["buoy-jit-ir"]),
];

/// Builds the crates of `NATIVE_LIBRARIES` for the target in release mode, with a cargo of
/// its own in `target/native`, and returns the code that embeds each library as
/// `<module>.so` in `NATIVE` and the hash of them all as `NATIVE_HASH`. Cargo cannot hand
/// one crate's cdylib to another crate's build.
fn native_library(workspace: &Path, out: &Path) -> String {
    for (crate_name, _, dependencies) in NATIVE_LIBRARIES {
        for name in dependencies.iter().chain([&crate_name]) {
            let crate_dir = workspace.join("crates").join(name);
            println!("cargo:rerun-if-changed={}", crate_dir.display());
        }
    }
    println!(
        "cargo:rerun-if-changed={}",
        workspace.join("Cargo.lock").display()
    );
    let target = env::var("TARGET").expect("cargo sets TARGET");
    // OUT_DIR is <target dir>/<profile>/build/<package>-<hash>/out.
    let target_dir = out
        .ancestors()
        .nth(4)
        .expect("OUT_DIR lies in the target directory")
        .join("native");
    let mut cargo = std::process::Command::new(env::var_os("CARGO").expect("cargo sets CARGO"));
    // The outer build has resolved the workspace, so the lock file is complete.
    cargo.args(["build", "--release", "--target", &target, "--locked"]);
    for (crate_name, _, _) in NATIVE_LIBRARIES {
        cargo.args(["--package", crate_name]);
    }
    let status = cargo
        .arg("--manifest-path")
        .arg(workspace.join("Cargo.toml"))
        .arg("--target-dir")
        .arg(&target_dir)
        // A clippy run of the workspace must not lint the inner build.
        .env_remove("RUSTC_WORKSPACE_WRAPPER")
        .env_remove("CLIPPY_ARGS")
        .status()
        .expect("cargo runs");
    assert!(status.success(), "cargo could not build the NIF libraries");
    let suffix = if target.contains("apple") {
        "dylib"
    } else {
        "so"
    };
    let mut table = String::from(
        "/// The NIF libraries: the file name in `ebin`, where the module of the same name loads\n\
         /// it, and the contents.\npub const NATIVE: &[(&str, &[u8])] = &[\n",
    );
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for (_, module, _) in NATIVE_LIBRARIES {
        let built = target_dir
            .join(&target)
            .join("release")
            .join(format!("lib{module}.{suffix}"));
        let library = out.join(format!("{module}.so"));
        let bytes = fs::read(&built).unwrap_or_else(|error| panic!("{}: {error}", built.display()));
        fs::write(&library, &bytes).expect("OUT_DIR is writable");
        hash = bytes.iter().fold(hash, |hash, byte| {
            (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3)
        });
        let _ = writeln!(
            table,
            "    (\"{module}.so\", include_bytes!({:?})),",
            library.display().to_string()
        );
    }
    let digits = format!("{hash:016x}");
    let _ = write!(
        table,
        "];\n/// The FNV-1a hash of the libraries of `NATIVE`.\n\
         pub const NATIVE_HASH: u64 = 0x{}_{}_{}_{};\n",
        &digits[..4],
        &digits[4..8],
        &digits[8..12],
        &digits[12..]
    );
    table
}

/// `*.erl`, `*.hrl`, and `*.app.src`.
fn is_runtime_source(path: &Path) -> bool {
    match path.extension().and_then(|extension| extension.to_str()) {
        Some("erl" | "hrl") => true,
        Some("src") => path
            .file_stem()
            .map(Path::new)
            .and_then(Path::extension)
            .is_some_and(|extension| extension == "app"),
        _ => false,
    }
}

/// The edits that turn the polyfill's script, temporal-polyfill 1.0.6 `global.js` (MIT,
/// fullcalendar/temporal-polyfill), into strict eval code that reads the realm's
/// `Intl.DateTimeFormat` shim and a nanosecond clock from its `this`, and whose completion
/// value is the `Temporal` namespace instead of writes to globals. The code drops the
/// script's function wrapper, so each top-level function compiles to an Erlang function:
/// erlc lints one function in time that grows with the square of its nested variables.
/// Each `from` must occur exactly once.
const TEMPORAL_EDITS: &[(&str, &str)] = &[
    (
        "!function() {\n  \"use strict\";\n",
        "\"use strict\";\nconst { Intl, nowNanoseconds, exactDivide } = this;\n",
    ),
    // The namespace is a lazy global, so reading it here would load the polyfill again.
    (
        "const NativeTemporal = globalThis.Temporal;",
        "const NativeTemporal = void 0;",
    ),
    (
        "return BigInt(Date.now()) * bigNanoInMilli;",
        "return nowNanoseconds();",
    ),
    // Duration.prototype.total converts the exact quotient to a Number (TotalTimeDuration
    // and NudgeToCalendarUnit); the polyfill divided in floating point.
    (
        "return days * (nanoInUtcDay / divisorNano) + (Math.trunc(timeNano / divisorNano) + timeNano % divisorNano / divisorNano);",
        "return exactDivide(bigNano, BigInt(divisorNano));",
    ),
    (
        "return interpolateRelativeUnitWindow(unitWindow, Number(endEpochNano - unitWindow.I) / Number(unitWindow.O - unitWindow.I));",
        "return exactDivide(BigInt(unitWindow.ve) * (unitWindow.O - unitWindow.I) + (endEpochNano - unitWindow.I) * BigInt(unitWindow.qe - unitWindow.ve), unitWindow.O - unitWindow.I);",
    ),
];

/// The tail of the script, which installs the globals and closes the wrapper. The code ends
/// with the namespace in its place, after it hands the slot readers to its host object.
const TEMPORAL_TAIL: &str = "  const DateTimeFormat = createDateTimeFormatClass(";

/// Compiles the polyfill at `vendored` into `out/buoy_temporal.erl`, whose `'__eval__'/3`
/// runs the code of `TEMPORAL_EDITS`. `buoy_ref_temporal` calls it the first time a realm
/// reads `Temporal`.
fn temporal_module(vendored: &Path, out: &Path) -> PathBuf {
    println!("cargo:rerun-if-changed={}", vendored.display());
    let script = fs::read_to_string(vendored)
        .unwrap_or_else(|error| panic!("{} holds the polyfill: {error}", vendored.display()));
    let edited = TEMPORAL_EDITS.iter().fold(script, |text, (from, to)| {
        assert_eq!(
            text.matches(from).count(),
            1,
            "the polyfill must hold {from:?} once"
        );
        text.replacen(from, to, 1)
    });
    let tail = edited
        .find(TEMPORAL_TAIL)
        .expect("the polyfill ends by installing its globals");
    // The host object also receives the readers of the internal slots, which Intl's
    // DurationFormat and DateTimeFormat use to read Temporal objects without their getters.
    let source = format!(
        "{}this.slotsOf = getTemporalBrandingAndSlots;\nthis.toDurationSlots = toDurationSlots;\nTemporal;\n",
        &edited[..tail]
    );
    let erlang = buoy_compiler::compile_eval(
        &source,
        "buoy_temporal",
        false,
        None,
        &[],
        &[],
        // The polyfill is part of the runtime: like a native Temporal, it must not observe
        // a program that replaces `Math.sign` or the array iterator.
        &buoy_compiler::EvalContext {
            internal: true,
            ..buoy_compiler::EvalContext::default()
        },
    )
    .unwrap_or_else(|diagnostics| {
        panic!(
            "the reference compiler rejects the polyfill: {}",
            diagnostics
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join("\n")
        )
    });
    let path = out.join("buoy_temporal.erl");
    fs::write(&path, erlang).expect("OUT_DIR is writable");
    path
}

/// Compiles each id of `runtime/node/builtins.txt` into `out/buoy_node@<id>.erl`, whose
/// `'__eval__'/3` returns the function that Node wraps around the code of a built-in
/// module (`BuiltinLoader::LookupAndCompile` in Node's `src/node_builtins.cc`). The code is
/// `runtime/node/<id>.js` when Buoy has its own version of the id, else the file of
/// Node's `lib/` in `runtime/vendor/node/lib`. `buoy_node` calls the function.
fn node_modules(runtime: &Path, out: &Path) -> Vec<PathBuf> {
    let list = runtime.join("node/builtins.txt");
    println!("cargo:rerun-if-changed={}", list.display());
    println!("cargo:rerun-if-changed={}", runtime.join("node/").display());
    let text = fs::read_to_string(&list)
        .unwrap_or_else(|error| panic!("{} lists the Node built-ins: {error}", list.display()));
    let ids: Vec<&str> = text
        .lines()
        .map(|line| line.split('#').next().unwrap_or("").trim())
        .filter(|line| !line.is_empty())
        .collect();
    let mut names = std::collections::HashMap::new();
    for id in &ids {
        if let Some(other) = names.insert(node_module_name(id), *id) {
            panic!("the built-ins {other} and {id} map to one Erlang module");
        }
    }
    let workers = std::thread::available_parallelism().map_or(4, usize::from);
    let next = std::sync::atomic::AtomicUsize::new(0);
    let compiled = std::sync::Mutex::new(Vec::new());
    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                while let Some(id) =
                    ids.get(next.fetch_add(1, std::sync::atomic::Ordering::Relaxed))
                {
                    let path = node_module(runtime, id, out);
                    compiled.lock().expect("no worker panics").push(path);
                }
            });
        }
    });
    compiled.into_inner().expect("no worker panics")
}

/// The Erlang module of the built-in `id`: `/` becomes `@` and `-` becomes `_`.
fn node_module_name(id: &str) -> String {
    format!("buoy_node@{}", id.replace('/', "@").replace('-', "_"))
}

/// The parameters of the function around the code of `id`, as Node's
/// `BuiltinLoader::LookupAndCompileInternal` names them.
fn node_parameters(id: &str) -> &'static str {
    if id.starts_with("internal/per_context/") {
        "exports, primordials, privateSymbols, perIsolateSymbols"
    } else if id == "internal/bootstrap/realm" {
        "process, getLinkedBinding, getInternalBinding, primordials"
    } else if id.starts_with("internal/bootstrap/") || id.starts_with("internal/main/") {
        "process, require, internalBinding, primordials"
    } else {
        "exports, require, module, process, internalBinding, primordials"
    }
}

fn node_module(runtime: &Path, id: &str, out: &Path) -> PathBuf {
    let own = runtime.join(format!("node/{id}.js"));
    let path = if own.is_file() {
        own
    } else if let Some(dep) = id.strip_prefix("internal/deps/") {
        // Node's build maps internal/deps/<path> to deps/<path>.js.
        runtime.join("vendor/node/deps").join(format!("{dep}.js"))
    } else {
        runtime.join("vendor/node/lib").join(format!("{id}.js"))
    };
    println!("cargo:rerun-if-changed={}", path.display());
    let code = fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("{} holds the built-in {id}: {error}", path.display()));
    // The code starts on the line of the wrapper, so its line numbers stay.
    let parameters = format!("(function ({})", node_parameters(id));
    let source = format!("{parameters} {{ {code}\n}})");
    let name = node_module_name(id);
    let erlang = buoy_compiler::compile_eval(
        &source,
        &name,
        false,
        Some(parameters.len()),
        &[],
        &[],
        &buoy_compiler::EvalContext::default(),
    )
    .unwrap_or_else(|diagnostics| {
        panic!(
            "the reference compiler rejects the built-in {id}: {}",
            diagnostics
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join("\n")
        )
    });
    let target = out.join(format!("{name}.erl"));
    fs::write(&target, erlang).expect("OUT_DIR is writable");
    target
}

/// Writes `out/buoy_node_builtins.erl`: `ids/0`, the ids of `runtime/node/builtins.txt`,
/// and `bindings/0`, the names of the bindings that a runtime source
/// `buoy_binding_<name>.erl` implements.
fn node_index(runtime: &Path, sources: &[PathBuf], out: &Path) -> PathBuf {
    let text = fs::read_to_string(runtime.join("node/builtins.txt"))
        .expect("runtime/node/builtins.txt lists the Node built-ins");
    let quote = |text: &str| format!("<<\"{text}\">>");
    let ids: Vec<String> = text
        .lines()
        .map(|line| line.split('#').next().unwrap_or("").trim())
        .filter(|line| !line.is_empty())
        .map(quote)
        .collect();
    let mut bindings: Vec<String> = sources
        .iter()
        .filter_map(|path| {
            path.file_name()?
                .to_str()?
                .strip_prefix("buoy_binding_")?
                .strip_suffix(".erl")
        })
        .map(quote)
        .collect();
    bindings.sort();
    let erlang = format!(
        "%% Generated by crates/buoy-cli/build.rs from runtime/node/builtins.txt.\n\
         -module(buoy_node_builtins).\n-export([ids/0, bindings/0]).\n\
         -spec ids() -> [binary()].\nids() -> [{}].\n\
         -spec bindings() -> [binary()].\nbindings() -> [{}].\n",
        ids.join(", "),
        bindings.join(", ")
    );
    let path = out.join("buoy_node_builtins.erl");
    fs::write(&path, erlang).expect("OUT_DIR is writable");
    path
}
