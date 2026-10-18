//! Embeds the runtime sources, `runtime/src/*.erl`, `*.hrl`, and `*.app.src`, in the binary.
//! The build fails when they are missing, because a binary without them cannot run a program.
//!
//! It also compiles the vendored Temporal polyfill into one more runtime source,
//! `buoy_temporal.erl`, with the reference compiler (see `temporal_module`), and each Node
//! built-in of `runtime/node/builtins.txt` into a runtime source `buoy_node@<id>.erl` (see
//! `node_modules`).

use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::{env, fs};

fn main() {
    let manifest =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"));
    let runtime = manifest.join("../../runtime/src");
    println!("cargo:rerun-if-changed={}", runtime.display());
    let mut sources: Vec<PathBuf> = fs::read_dir(&runtime)
        .unwrap_or_else(|error| panic!("{} holds the runtime sources: {error}", runtime.display()))
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| is_runtime_source(path))
        .collect();
    assert!(
        !sources.is_empty(),
        "{} holds no runtime sources",
        runtime.display()
    );
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
    fs::write(out.join("runtime_sources.rs"), table).expect("OUT_DIR is writable");
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
/// with the namespace in its place.
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
    let source = format!("{}Temporal;\n", &edited[..tail]);
    let erlang = buoy_compiler::compile_eval(
        &source,
        "buoy_temporal",
        false,
        false,
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
    let source = format!("(function ({}) {{ {code}\n}})", node_parameters(id));
    let name = node_module_name(id);
    let erlang = buoy_compiler::compile_eval(
        &source,
        &name,
        false,
        true,
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
